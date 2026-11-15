// Hand wave (Wekinator #3 DTW) + wave_osc tracking checks. Display/validity as wave_reader.pde.
//
// Port 12000 addresses handled here:
//   /wave/outputs ... (Wekinator #3) -> wave DETECTION. Every message is a detection; the
//                                       values are shown/logged exactly as received.
//                                       No threshold, no edge detection.
//   /wave/status i    (python)       -> 0 no hand, 1 tracking, 2 calibrating,
//                                       3 reset (extractor history restarted -> settle timer restarts)
//   /wave/features f..(python)       -> the exact floats Wekinator receives (logging only)
//   /wave/angle f     (python)       -> smoothed tilt phi in degrees (display only)
//
// A wave detection is an internal trigger only - never a serial command by itself.
// Checks, in order (every detection logged ACCEPTED or IGNORED + reason):
//   1. tracking    : heartbeat fresh AND hand tracked continuously for WAVE_SETTLE_MS (at arrival)
//   2. interaction : interactionBlock() in interaction.pde
// ACCEPTED -> exprBegin(): the expression assessment in interaction.pde decides
// wavesmiling / wavenotsmiling / cancel.

// ---- wave config ----
final String WAVE_OUTPUT_ADDR   = "/wave/outputs";
final String WAVE_STATUS_ADDR   = "/wave/status";
final String WAVE_FEATURES_ADDR = "/wave/features";
final String WAVE_ANGLE_ADDR    = "/wave/angle";
final int    WAVE_HEARTBEAT_MS  = 500;    // no /wave/status this long = python not running
final int    WAVE_SETTLE_MS     = 1000;   // hand must be tracked this long (>= one wave) to call a result VALID
final boolean WAVE_PRINT_RAW    = true;   // print every /wave/outputs message
// ---------------------

final String[] WAVE_STATUS_NAMES = {"no hand", "tracking", "calibrating", "reset (reacquired / hand changed / gap)"};
final int WAVE_TRACKING = 1;

final Object waveLock = new Object();

// all guarded by waveLock (written on the OSC thread, read in draw)
int waveStatus = -1;
int waveStatusTime = -100000;
int waveTrackingSince = -1;
float wavePhiDeg = 0;
int waveAngleTime = -100000;
String waveFeatures = "";
String waveLastRaw = "(none yet)";
String waveLastValues = "";      // just the arguments of the last /wave/outputs
int waveLastRawTime = -100000;
String waveLastProblem = null;   // validity of the last /wave/outputs at arrival (null = VALID)
final ArrayList<String> waveQReject = new ArrayList<String>();   // one entry per detection; null = valid

// draw thread only
String waveLastResult = "";

String waveStatusName(int s) {
  return (s >= 0 && s < WAVE_STATUS_NAMES.length) ? WAVE_STATUS_NAMES[s] : "unknown " + s;
}

// Why a result arriving now can't be trusted, or null. Lock held.
String waveTrackingProblem(int now) {
  if (now - waveStatusTime > WAVE_HEARTBEAT_MS) return "no heartbeat from python";
  if (waveStatus != WAVE_TRACKING) return waveStatusName(waveStatus);
  int clean = now - waveTrackingSince;
  if (clean < WAVE_SETTLE_MS) return "hand tracked for only " + clean + " ms";
  return null;
}

// Returns true if the message belonged to the wave pipeline. Runs on the OSC thread.
boolean waveOscEvent(OscMessage msg) {
  String a = msg.addrPattern();
  int now = millis();
  synchronized (waveLock) {
    if (a.equals(WAVE_STATUS_ADDR)) {
      int s = msg.get(0).intValue();
      if (s == WAVE_TRACKING && waveStatus != WAVE_TRACKING) waveTrackingSince = now;
      if (s != WAVE_TRACKING) waveTrackingSince = -1;
      if (s != waveStatus) println("WAVE TRACKING " + waveStatusName(s));
      waveStatus = s;
      waveStatusTime = now;
      return true;
    }
    if (a.equals(WAVE_ANGLE_ADDR)) {
      wavePhiDeg = msg.get(0).floatValue();
      waveAngleTime = now;
      return true;
    }
    if (a.equals(WAVE_FEATURES_ADDR)) {
      String f = "";
      for (int i = 0; i < msg.arguments().length; i++) f += (i > 0 ? "  " : "") + nf(msg.get(i).floatValue(), 0, 2);
      waveFeatures = f;
      return true;
    }
    if (a.equals(WAVE_OUTPUT_ADDR)) {
      String vals = "";
      for (int i = 0; i < msg.arguments().length; i++) vals += (i > 0 ? "  " : "") + msg.arguments()[i];
      waveLastValues = vals;
      waveLastRaw = a + " " + msg.typetag() + " " + vals;
      waveLastRawTime = now;
      waveLastProblem = waveTrackingProblem(now);
      String validity = waveLastProblem == null ? "VALID" : "INVALID: " + waveLastProblem;
      if (WAVE_PRINT_RAW) println(waveLastRaw + "   [" + validity + "]");
      println("DETECTION wave (Wekinator #3 " + a + ")");
      waveQReject.add(waveLastProblem);
      return true;
    }
  }
  return false;
}

// Draw thread: accept or ignore each wave detection. Never queues for later.
void waveUpdate() {
  ArrayList<String> rs;
  synchronized (waveLock) {
    rs = new ArrayList<String>(waveQReject);
    waveQReject.clear();
  }
  for (String r : rs) {
    String block = interactionBlock(millis());
    if (r != null) {
      waveLastResult = "IGNORED wave: tracking " + r;
    } else if (block != null) {
      waveLastResult = "IGNORED wave: " + block;
    } else {
      waveLastResult = "ACCEPTED wave -> expression assessment";
      println(waveLastResult);
      exprBegin(millis());
      continue;
    }
    println(waveLastResult);
  }
}

// Draws the wave panel at the current origin, w pixels wide.
void drawWavePanel(int w) {
  int now = millis();
  int cx = w / 2;
  String problemNow, raw, vals, feats, lastProblem;
  int rawTime, angleTime;
  float phi;
  synchronized (waveLock) {
    problemNow = waveTrackingProblem(now);
    raw = waveLastRaw;
    vals = waveLastValues;
    rawTime = waveLastRawTime;
    lastProblem = waveLastProblem;
    angleTime = waveAngleTime;
    phi = wavePhiDeg;
    feats = waveFeatures;
  }
  boolean wekSeen = rawTime > 0;
  boolean wekFresh = wekSeen && now - rawTime <= WAVE_HEARTBEAT_MS;

  // big: Wekinator's output, exactly as received
  if (!wekSeen) {
    textSize(22);
    fill(255);
    text("waiting for wave Wekinator...", cx, 45);
  } else {
    textSize(vals.length() > 14 ? 22 : 36);
    fill(!wekFresh ? color(120) : lastProblem == null ? color(0, 220, 0) : color(230, 160, 60));
    text(vals.length() > 0 ? vals : "(no values)", cx, 45);
    textSize(12);
    fill(150);
    text("wave Wekinator output" + (wekFresh ? "" : "  (stale)"), cx, 75);
  }

  // live tilt indicator: a line at angle phi from vertical (image-right = clockwise)
  boolean angleFresh = now - angleTime <= WAVE_HEARTBEAT_MS;
  int pivotY = 165, len = 60;
  stroke(70);
  line(cx, pivotY, cx, pivotY - len);
  if (angleFresh) {
    float a = radians(phi);
    stroke(0, 200, 255);
    strokeWeight(4);
    line(cx, pivotY, cx + len * sin(a), pivotY - len * cos(a));
    strokeWeight(1);
  }
  noStroke();
  textSize(13);
  fill(255);
  text(angleFresh ? "phi " + nf(phi, 0, 1) + " deg   z: " + feats : "phi --  (no hand)", cx, pivotY + 18);

  // validity + decision
  fill(problemNow == null ? color(0, 220, 0) : color(230, 80, 60));
  text(problemNow == null ? "wave tracking OK" : "tracking: " + problemNow, cx, PANEL_H - 100);
  fill(waveLastResult.startsWith("ACCEPTED") ? color(0, 220, 0)
       : waveLastResult.startsWith("IGNORED") ? color(230, 160, 60) : color(255));
  text(waveLastResult.length() > 0 ? waveLastResult : "verdict: no waves yet", cx, PANEL_H - 80);
  fill(255);
  String age = wekSeen ? " (" + (now - rawTime) + " ms ago)" : "";
  text("wekinator: " + raw + age, cx, PANEL_H - 50);
}
