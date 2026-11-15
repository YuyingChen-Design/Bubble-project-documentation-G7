// Shared interaction state + wave expression assessment.
//
// Exactly four robot actions, one serial character each (no newline):
//   nod            -> N    (head /output_1)
//   shake          -> S    (head /output_2)
//   wavesmiling    -> W    (valid wave + stable "smiling" classification)
//   wavenotsmiling -> F    (valid wave + stable "straight-faced" classification)
// W and F are not in the current firmware yet: with ROBOT_ENABLED the Arduino will
// answer "DEBUG: unknown command", send no BUSY, and the ACK timeout faults safely.
// A wave is an internal trigger only. Smiling / straight-faced alone never act.
//
// Shared interaction state (interactionState()):
//   READY      a new gesture may be accepted
//   ASSESSING  a wave was accepted; collecting smile predictions
//   BUSY       robot executing (or not ready yet) - only when ROBOT_ENABLED
//   FAULT      robot fault                        - only when ROBOT_ENABLED
// While ASSESSING or BUSY every detection (nod, shake, wave) is ignored and logged,
// never queued. On DONE everything is reset and detections are ignored for
// POST_ACTION_SETTLE_MS (Wekinator windows still hold movement from the busy period).
//
// Expression assessment (started by an accepted wave):
//   Collect the smile predictions that ARRIVE AFTER the wave, for EXPR_WINDOW_MS.
//   Cancel (no action) as soon as any of these happens:
//     - a prediction arrives with smile tracking invalid (or an unknown class)
//     - more than EXPR_MAX_GAP_MS without a prediction (stale / tracking lost)
//     - a robot fault
//   At the end of the window:
//     - fewer than EXPR_MIN_SAMPLES predictions          -> cancel
//     - largest class share below EXPR_AGREEMENT          -> cancel (unstable)
//     - otherwise SMILE_CLASS -> wavesmiling, NEUTRAL_CLASS -> wavenotsmiling
//   Missing or uncertain information is never treated as "not smiling".
//   Then robot readiness is re-checked, the robot is marked busy, exactly one
//   command is sent (ROBOT_ENABLED), or the decision is logged as not sent.

// ---- assessment / interaction config ----
final int   EXPR_WINDOW_MS        = 600;   // collect predictions for this long after the wave
final int   EXPR_MIN_SAMPLES      = 5;     // at least this many predictions in the window
final float EXPR_AGREEMENT        = 0.8;   // at least this share must be the same class
final int   EXPR_MAX_GAP_MS       = 300;   // freshness: max time without a prediction
final int   POST_ACTION_SETTLE_MS = 1000;  // after DONE, ignore detections this long
// -----------------------------------------

// ---- command table ----
final String CMD_NOD              = "N";
final String CMD_SHAKE            = "S";
final String CMD_WAVE_SMILING     = "W";
final String CMD_WAVE_NOT_SMILING = "F";
// -----------------------

final int IA_READY = 0, IA_ASSESSING = 1, IA_BUSY = 2, IA_FAULT = 3;
final String[] IA_NAMES = {"READY", "ASSESSING EXPRESSION", "ROBOT BUSY", "FAULT"};

// one smile prediction, recorded by smile.pde
class ExprSample {
  int t; int cls; String problem;      // problem = tracking problem at arrival, null = valid
  ExprSample(int t, int cls, String problem) { this.t = t; this.cls = cls; this.problem = problem; }
}

// draw thread only
boolean exprPending = false;
int exprStartT = 0;
int settleUntil = 0;
String exprLastResult = "";
String decisionLast = "";            // last action decided (and whether it was sent)
int decisionAt = -100000;

int interactionState() {
  if (ROBOT_ENABLED && robot == FAULT) return IA_FAULT;
  if (ROBOT_ENABLED && robot != READY) return IA_BUSY;   // AWAIT_ACK, BUSY, or no READY yet
  if (exprPending) return IA_ASSESSING;
  return IA_READY;
}

// Why a new detection can't be accepted right now, or null.
String interactionBlock(int now) {
  if (exprPending) return "assessing expression";
  if (ROBOT_ENABLED) {
    if (robot == FAULT) return "robot fault (" + faultReason + ")";
    if (robot == NOT_READY) return "robot not ready (no READY yet)";
    if (robot == AWAIT_ACK || robot == BUSY) return "robot busy with " + pendingCmd;
  }
  if (now < settleUntil) return "post-action settle (" + (settleUntil - now) + " ms left)";
  return null;
}

// Robot finished an animation: reset everything and start the settle period.
void onRobotDone() {
  exprCancel("robot done");          // nothing should be pending; reset anyway
  settleUntil = millis() + POST_ACTION_SETTLE_MS;
  println("INTERACTION reset after DONE, ignoring detections for " + POST_ACTION_SETTLE_MS + " ms");
}

void exprBegin(int now) {
  exprPending = true;
  exprStartT = now;
  exprLastResult = "assessing...";
  println("EXPR START window " + EXPR_WINDOW_MS + " ms (need >= " + EXPR_MIN_SAMPLES
          + " predictions, >= " + round(EXPR_AGREEMENT * 100) + "% agreement, gaps <= " + EXPR_MAX_GAP_MS + " ms)");
}

void exprCancel(String reason) {
  if (!exprPending) return;
  exprPending = false;
  exprLastResult = "CANCELLED: " + reason;
  println("EXPR CANCELLED: " + reason + " - no command");
}

boolean exprSampleUsable(ExprSample s) {
  return s.problem == null && (s.cls == SMILE_CLASS || s.cls == NEUTRAL_CLASS);
}

String exprSampleReason(ExprSample s) {
  if (s.problem != null) return "smile " + s.problem;
  if (s.cls == Integer.MIN_VALUE) return "prediction has no value";
  return "class " + s.cls + " is not " + NEUTRAL_CLASS + " or " + SMILE_CLASS;
}

// Draw thread, every frame.
void exprUpdate() {
  if (!exprPending) return;
  int now = millis();
  int end = exprStartT + EXPR_WINDOW_MS;

  ArrayList<ExprSample> win = new ArrayList<ExprSample>();
  synchronized (smileLock) {
    for (ExprSample s : smileSamples) if (s.t >= exprStartT && s.t <= end) win.add(s);
  }

  // freshness + validity of everything received so far
  int prev = exprStartT;
  for (ExprSample s : win) {
    if (!exprSampleUsable(s)) { exprCancel("prediction invalid (" + exprSampleReason(s) + ")"); return; }
    if (s.t - prev > EXPR_MAX_GAP_MS) { exprCancel("predictions stale (" + (s.t - prev) + " ms gap)"); return; }
    prev = s.t;
  }
  int horizon = min(now, end);
  if (horizon - prev > EXPR_MAX_GAP_MS) {
    exprCancel("predictions stale (none for " + (horizon - prev) + " ms)");
    return;
  }
  if (now < end) return;                          // window still open

  // window closed: count and agree
  int n = win.size(), nSmile = 0, nNeutral = 0;
  for (ExprSample s : win) { if (s.cls == SMILE_CLASS) nSmile++; else nNeutral++; }
  if (n < EXPR_MIN_SAMPLES) { exprCancel("only " + n + " predictions (need " + EXPR_MIN_SAMPLES + ")"); return; }
  boolean smiling = nSmile >= nNeutral;
  int top = smiling ? nSmile : nNeutral;
  float share = top / (float) n;
  String counts = nSmile + " smiling / " + nNeutral + " straight-faced";
  if (share < EXPR_AGREEMENT) {
    exprCancel("unstable (" + counts + ", " + round(share * 100) + "% < " + round(EXPR_AGREEMENT * 100) + "%)");
    return;
  }

  String action = smiling ? "wavesmiling" : "wavenotsmiling";
  String code = smiling ? CMD_WAVE_SMILING : CMD_WAVE_NOT_SMILING;
  exprPending = false;
  exprLastResult = "RESULT " + action + " (" + counts + ", " + round(share * 100) + "%)";
  println("EXPR " + exprLastResult);

  // recheck readiness, then exactly one command
  decisionAt = now;
  if (!ROBOT_ENABLED) {
    decisionLast = action + " -> " + code + " (robot disabled, not sent)";
    println("DECISION " + decisionLast);
  } else if (robot != READY) {
    decisionLast = action + " CANCELLED: robot " + ROBOT_NAMES[robot] + " at decision time";
    println("DECISION " + decisionLast);
  } else {
    decisionLast = action + " -> " + code + " sent";
    println("DECISION " + action + " -> " + code);
    sendCommand(code, action);
  }
}

// Top bar: shared state, assessment progress, robot readiness, last decision.
void drawInteractionBar(int w, int h) {
  int now = millis();
  int st = interactionState();
  fill(30);
  rect(0, 0, w, h);
  textAlign(LEFT, CENTER);

  color c = st == IA_READY ? color(0, 220, 0) : st == IA_FAULT ? color(230, 60, 60)
          : st == IA_ASSESSING ? color(0, 180, 255) : color(230, 180, 60);
  fill(c);
  textSize(20);
  String s = "INTERACTION: " + IA_NAMES[st];
  if (st == IA_ASSESSING) s += "  " + min(now - exprStartT, EXPR_WINDOW_MS) + "/" + EXPR_WINDOW_MS + " ms";
  if (st == IA_READY && now < settleUntil) s += "  (settling " + (settleUntil - now) + " ms)";
  text(s, 12, h / 3);

  textSize(13);
  fill(200);
  String robotText = !ROBOT_ENABLED ? "robot: disabled (ROBOT_ENABLED = false)"
                   : "robot: " + ROBOT_NAMES[robot] + (pendingCmd.length() > 0 ? " " + pendingCmd : "");
  text(robotText, 12, 2 * h / 3);
  text("expression: " + (exprLastResult.length() > 0 ? exprLastResult : "-"), w / 3, 2 * h / 3);
  fill(now - decisionAt < 3000 ? color(255) : color(150));
  text("decision: " + (decisionLast.length() > 0 ? decisionLast : "-"), 2 * w / 3, 2 * h / 3);
  textAlign(CENTER, CENTER);
}
