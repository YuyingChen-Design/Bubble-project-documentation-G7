// Head-pose gestures + Arduino robot (serial READY/BUSY/DONE state machine).
//
// Port 12000 addresses handled here:
//   /output_1       (Wekinator #1)  -> nod detection   (message itself is the detection, no threshold)
//   /output_2       (Wekinator #1)  -> shake detection (message itself is the detection, no threshold)
//   /head/status i  (python)        -> 0 calibrating, 1 tracking, 2 holding, 3 lost, 4 recovering
//   /head/pose ff   (python)        -> pitch yaw, same values Wekinator gets (logging only)
//
// Arduino protocol (serial, SERIAL_BAUD):
//   sent     : one char, no newline - see the command table in interaction.pde
//              (N nod, S shake, W wavesmiling, F wavenotsmiling)
//   received : "READY", "BUSY", "DONE" (newline-terminated; "DEBUG:..." lines ignored)
//
// Robot state machine (all transitions happen on the draw thread):
//   NOT_READY --READY--> READY --gesture accepted--> AWAIT_ACK --BUSY--> BUSY --DONE--> READY
//   AWAIT_ACK --DONE--> READY (BUSY was missed; logged)
//   AWAIT_ACK > ACK_TIMEOUT_MS, BUSY > DONE_TIMEOUT_MS, disconnect,
//   write error, unexpected BUSY, or READY during a command (= Arduino reset)  --> FAULT
//   FAULT --'r' key--> READY if the Arduino last reported READY/DONE, else NOT_READY.
//   Nothing is ever retried or replayed automatically.
//
// Nod/shake checks, in order (every detection logged as ACCEPTED or IGNORED + reason):
//   1. tracking    : heartbeat fresh AND status TRACKING for TRACKING_SETTLE_MS (at arrival)
//   2. interaction : interactionBlock() in interaction.pde - not while assessing an
//                    expression, robot not ready/busy/fault, or post-action settle.
//   Gestures are never queued for later.

// Robot on/off: ROBOT_ENABLED is set in combined_reader.pde.

// ---- serial to Arduino ----
// Close the Arduino Serial Monitor first: only one program can open the port.
final String SERIAL_PORT = "COM9";   // "" = use the last port in the list
final int SERIAL_BAUD = 115200;      // must match Serial.begin() on the Arduino

// ---- tuning ----
final int ACK_TIMEOUT_MS     = 1000;   // command sent -> BUSY must arrive within this
final int DONE_TIMEOUT_MS    = 10000;  // BUSY -> DONE must arrive within this (longest animation + margin)
final int PORT_CHECK_MS      = 1000;   // how often to check the port still exists
final int DISPLAY_MS         = 2000;   // how long the accepted gesture stays on screen (display only)
final int HEARTBEAT_MS       = 500;    // no /head/status for this long = python not running
final int TRACKING_SETTLE_MS = 1000;   // tracking must be clean this long before a gesture counts
final boolean PRINT_POSE     = true;   // print every "pitch yaw" sample (20 lines/s)
final boolean PRINT_DEBUG    = true;   // echo Arduino "DEBUG:" lines (never affect state)
final String HEAD_NOD_ADDR   = "/output_1";   // Wekinator #1 discrete nod message
final String HEAD_SHAKE_ADDR = "/output_2";   // Wekinator #1 discrete shake message
// ----------------

final String[] STATUS_NAMES = {"calibrating", "tracking", "face lost (holding)", "face lost", "recovering"};
final int TRACKING = 1;

// robot states
final int NOT_READY = 0, READY = 1, AWAIT_ACK = 2, BUSY = 3, FAULT = 4;
final String[] ROBOT_NAMES = {"NOT READY", "READY", "WAITING FOR BUSY", "BUSY", "FAULT"};

final Object lock = new Object();

// OSC thread -> draw thread queue (guarded by lock)
final ArrayList<String> qGesture = new ArrayList<String>();
final ArrayList<String> qReject = new ArrayList<String>();   // null = tracking valid at arrival

// serial thread -> draw thread queue (guarded by lock)
final ArrayList<String> qSerial = new ArrayList<String>();

// tracking status (guarded by lock)
int headStatus = -1;
int headStatusTime = -100000;
int trackingSince = -1;
String lastMsg = "(none yet)";
int lastMsgTime = -100000;

// robot / serial state (draw thread only)
Serial arduino;                 // null when not connected
String portName = "";
int robot = NOT_READY;
int stateSince = 0;             // millis() of last robot state change
String pendingCmd = "";         // command awaiting BUSY/DONE
String faultReason = "";
String lastArduinoStatus = "";  // last READY/BUSY/DONE seen, for recovery
int lastPortCheck = 0;

// display (draw thread only)
String shown = "";
int shownAt = -100000;
String lastResult = "";

// ================= serial =================

void openSerial() {
  if (!ROBOT_ENABLED) {
    println("ROBOT DISABLED (ROBOT_ENABLED = false): serial not opened, no commands will be sent");
    return;
  }
  String[] ports = Serial.list();
  println("Serial ports: " + join(ports, ", "));
  portName = SERIAL_PORT;
  if (portName.length() == 0) {
    if (ports.length == 0) { fault("no serial ports found"); return; }
    portName = ports[ports.length - 1];
  }
  try {
    arduino = new Serial(this, portName, SERIAL_BAUD);
    arduino.bufferUntil('\n');
    lastArduinoStatus = "";
    setRobot(NOT_READY);
    println("SERIAL: opened " + portName + " @ " + SERIAL_BAUD + ", waiting for READY");
  } catch (Exception e) {
    arduino = null;
    fault("could not open " + portName + " (" + e.getMessage() + ") - is the Serial Monitor open?");
  }
}

void closeSerial() {
  if (arduino != null) {
    try { arduino.stop(); } catch (Exception e) { }
    arduino = null;
  }
}

// Serial thread: only collect complete, trimmed lines.
void serialEvent(Serial p) {
  String line = p.readStringUntil('\n');
  if (line == null) return;
  line = trim(line);
  if (line.length() == 0) return;
  synchronized (lock) { qSerial.add(line); }
}

void setRobot(int s) {
  if (s != robot) println("ROBOT " + ROBOT_NAMES[robot] + " -> " + ROBOT_NAMES[s]);
  robot = s;
  stateSince = millis();
}

void fault(String reason) {
  faultReason = reason;
  pendingCmd = "";
  println("FAULT: " + reason + "  (press 'r' in this window to recover)");
  setRobot(FAULT);
  exprCancel("robot fault");          // a pending wave assessment never actuates after a fault
}

// Draw thread: apply Arduino status lines to the state machine.
void handleSerialLine(String line) {
  if (line.startsWith("DEBUG:")) {
    if (PRINT_DEBUG) println("ARDUINO " + line);
    return;
  }
  println("STATUS RECEIVED " + line + " (robot " + ROBOT_NAMES[robot] + ")");
  if (!line.equals("READY") && !line.equals("BUSY") && !line.equals("DONE")) {
    println("SERIAL: unknown line ignored: " + line);
    return;
  }
  lastArduinoStatus = line;

  switch (robot) {
    case NOT_READY:
      if (line.equals("READY")) setRobot(READY);
      else println("SERIAL: " + line + " while not ready, ignored");
      break;
    case READY:
      if (line.equals("BUSY")) fault("Arduino reported BUSY with no command outstanding");
      // READY again or a stray DONE: harmless, stay READY
      break;
    case AWAIT_ACK:
      if (line.equals("BUSY")) {
        println("COMMAND " + pendingCmd + " acknowledged");
        setRobot(BUSY);
      } else if (line.equals("DONE")) {
        println("COMMAND " + pendingCmd + " done (BUSY was not seen)");
        pendingCmd = "";
        setRobot(READY);
        onRobotDone();
      } else {
        fault("READY while waiting for BUSY on " + pendingCmd + " - Arduino reset? command cancelled");
      }
      break;
    case BUSY:
      if (line.equals("DONE")) {
        println("COMMAND " + pendingCmd + " done");
        pendingCmd = "";
        setRobot(READY);
        onRobotDone();
      } else if (line.equals("READY")) {
        fault("READY while executing " + pendingCmd + " - Arduino reset? command cancelled");
      }
      break;
    case FAULT:
      println("SERIAL: " + line + " during fault, not acted on");
      break;
  }
}

// Draw thread: timeouts and disconnect detection.
void checkRobotHealth(int now) {
  if (robot == AWAIT_ACK && now - stateSince > ACK_TIMEOUT_MS)
    fault("no BUSY within " + ACK_TIMEOUT_MS + " ms for " + pendingCmd);
  else if (robot == BUSY && now - stateSince > DONE_TIMEOUT_MS)
    fault("no DONE within " + DONE_TIMEOUT_MS + " ms for " + pendingCmd);

  if (arduino != null && now - lastPortCheck > PORT_CHECK_MS) {
    lastPortCheck = now;
    boolean present = false;
    for (String p : Serial.list()) if (p.equals(portName)) present = true;
    if (!present) {
      closeSerial();
      fault("serial port " + portName + " disconnected");
    }
  }
}

// Deliberate recovery, from the 'r' key only.
void recover() {
  if (!ROBOT_ENABLED) { println("RECOVER: robot disabled, nothing to do"); return; }
  if (robot != FAULT) { println("RECOVER: not in fault, nothing to do"); return; }
  println("RECOVER requested (last Arduino status: " + (lastArduinoStatus.length() > 0 ? lastArduinoStatus : "none") + ")");
  faultReason = "";
  if (arduino == null) {          // disconnected: reopen, which waits for READY
    openSerial();
    return;
  }
  // Only trust the Arduino as ready if the last thing it said was READY or DONE.
  if (lastArduinoStatus.equals("READY") || lastArduinoStatus.equals("DONE")) setRobot(READY);
  else setRobot(NOT_READY);
}

// The only place a command is sent. Marks busy BEFORE writing. Exactly one char.
void sendCommand(String code, String action) {
  pendingCmd = code;
  setRobot(AWAIT_ACK);            // gate closed before anything leaves
  try {
    arduino.write(code);
    println("COMMAND SENT " + code + " (" + action + ")");
  } catch (Exception e) {
    fault("write failed for " + code + " (" + e.getMessage() + ")");
  }
}

// ================= OSC / gestures =================

// Why a gesture arriving now must be ignored, or null if tracking is valid. Lock held.
String trackingProblem(int now) {
  if (now - headStatusTime > HEARTBEAT_MS) return "tracking unavailable (no heartbeat from python)";
  if (headStatus != TRACKING) return "tracking unavailable (" + statusName(headStatus) + ")";
  int clean = now - trackingSince;
  if (clean < TRACKING_SETTLE_MS) return "tracking unstable (clean for only " + clean + " ms)";
  return null;
}

String statusName(int s) {
  return (s >= 0 && s < STATUS_NAMES.length) ? STATUS_NAMES[s] : "unknown " + s;
}

// OSC thread. Returns true if the message belonged to the head pipeline.
// Logs, records status, queues detections; never touches the robot.
boolean headOscEvent(OscMessage msg) {
  String a = msg.addrPattern();
  boolean isGestureAddr = a.equals(HEAD_NOD_ADDR) || a.equals(HEAD_SHAKE_ADDR);
  if (!a.equals("/head/status") && !a.equals("/head/pose") && !isGestureAddr) return false;

  int now = millis();
  synchronized (lock) {
    if (a.equals("/head/status")) {
      int s = msg.get(0).intValue();
      if (s == TRACKING && headStatus != TRACKING) trackingSince = now;
      if (s != TRACKING) trackingSince = -1;
      if (s != headStatus) println("TRACKING " + statusName(s));
      headStatus = s;
      headStatusTime = now;
      return true;
    }
    if (a.equals("/head/pose")) {
      if (PRINT_POSE) println(nf(msg.get(0).floatValue(), 0, 2) + " " + nf(msg.get(1).floatValue(), 0, 2));
      return true;
    }
    String raw = a + " " + msg.typetag();
    for (int i = 0; i < msg.arguments().length; i++) raw += " " + msg.arguments()[i];
    println(raw);
    lastMsg = raw;
    lastMsgTime = now;

    String g = a.equals(HEAD_NOD_ADDR) ? "nod" : "shake";
    println("DETECTION " + g + " (Wekinator #1 " + a + ")");
    qGesture.add(g);
    qReject.add(trackingProblem(now));
  }
  return true;
}

// Draw thread: accept or ignore each nod/shake detection. Never queues for later.
void handleGesture(String g, String trackingReject) {
  String block = interactionBlock(millis());
  if (trackingReject != null) {
    lastResult = "IGNORED " + g + ": " + trackingReject;
  } else if (block != null) {
    lastResult = "IGNORED " + g + ": " + block;
  } else if (!ROBOT_ENABLED) {
    lastResult = "ACCEPTED " + g + " (robot disabled, not sent)";
    shown = g;
    shownAt = millis();
  } else {
    lastResult = "ACCEPTED " + g;
    println(lastResult);
    shown = g;
    shownAt = millis();
    sendCommand(g.equals("nod") ? CMD_NOD : CMD_SHAKE, g);
    return;
  }
  println(lastResult);
}

// ================= per-frame =================

// Draw thread: drain queues (serial first, so a DONE frees the robot before new gestures).
void headUpdate() {
  int now = millis();
  ArrayList<String> lines, gs, rs;
  synchronized (lock) {
    lines = new ArrayList<String>(qSerial);
    gs = new ArrayList<String>(qGesture);
    rs = new ArrayList<String>(qReject);
    qSerial.clear();
    qGesture.clear();
    qReject.clear();
  }
  for (String line : lines) handleSerialLine(line);
  checkRobotHealth(now);
  for (int i = 0; i < gs.size(); i++) handleGesture(gs.get(i), rs.get(i));
}

// Draws the head panel at the current origin, w pixels wide.
void drawHeadPanel(int w) {
  int now = millis();
  int cx = w / 2;
  String problem, lm;
  int lmTime;
  synchronized (lock) {
    problem = trackingProblem(now);
    lm = lastMsg;
    lmTime = lastMsgTime;
  }
  boolean wekSeen = lmTime > 0;

  fill(255);
  if (now - shownAt < DISPLAY_MS) {
    textSize(48);
    text(shown.toUpperCase(), cx, 60);
  } else {
    textSize(24);
    text(wekSeen ? "idle" : "waiting for head Wekinator...", cx, 60);
  }

  // robot state
  textSize(18);
  if (!ROBOT_ENABLED) {
    fill(150);
    text("robot: disabled", cx, 130);
  } else {
  color rc = robot == READY ? color(0, 220, 0)
           : robot == FAULT ? color(230, 60, 60)
           : robot == NOT_READY ? color(150) : color(230, 180, 60);
  fill(rc);
  String rs2 = "robot: " + ROBOT_NAMES[robot];
  if (robot == AWAIT_ACK || robot == BUSY) rs2 += " " + pendingCmd + " (" + (now - stateSince) + " ms)";
  text(rs2, cx, 130);
  if (robot == FAULT) {
    textSize(12);
    text(faultReason, cx, 155);
    text("press 'r' to recover", cx, 172);
  }
  }

  textSize(13);
  fill(problem == null ? color(0, 220, 0) : color(230, 80, 60));
  text(problem == null ? "head tracking OK" : problem, cx, PANEL_H - 100);
  fill(lastResult.startsWith("ACCEPTED") ? color(0, 220, 0)
       : lastResult.startsWith("IGNORED") ? color(230, 160, 60) : color(255));
  text(lastResult.length() > 0 ? lastResult : "verdict: no gestures yet", cx, PANEL_H - 80);
  fill(255);
  String age = wekSeen ? " (" + (now - lmTime) + " ms ago)" : "";
  text("last detection: " + lm + age, cx, PANEL_H - 50);
}
