// Reads Wekinator DTW output via OSC and drives an Arduino robot over serial.
// Pipeline: head_pose_osc -> Wekinator (DTW) -> this sketch -> Arduino
//                        \-> /head/status heartbeat -> this sketch
//
// Requires the "oscP5" library (Sketch > Import Library > Manage Libraries).
// Port 12000 receives:
//   /output_1       (Wekinator)     -> nod
//   /output_2       (Wekinator)     -> shake
//   /wek/outputs ff (Wekinator)     -> DTW distances [nod, shake]; fires below MATCH_DISTANCE
//   /head/status i  (head_pose_osc) -> 0 calibrating, 1 tracking, 2 holding, 3 lost, 4 recovering
//   /head/pose ff   (head_pose_osc) -> pitch yaw, same values Wekinator gets (logging only)
//
// Arduino protocol (serial, SERIAL_BAUD):
//   sent     : 'N' = nod, 'S' = shake (single char, no newline)
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
// Gesture checks, in order (every detection logged as ACCEPTED or IGNORED + reason):
//   1. tracking : heartbeat fresh AND status TRACKING for TRACKING_SETTLE_MS (at arrival)
//   2. robot    : state must be READY. Gestures are never queued for later.

import oscP5.*;
import netP5.*;
import processing.serial.*;
import java.util.ArrayList;

// ---- serial to Arduino ----
// Close the Arduino Serial Monitor first: only one program can open the port.
final String SERIAL_PORT = "COM9";   // "" = use the last port in the list
final int SERIAL_BAUD = 115200;    // must match Serial.begin() on the Arduino

// ---- tuning ----
final int ACK_TIMEOUT_MS     = 1000;   // command sent -> BUSY must arrive within this
final int DONE_TIMEOUT_MS    = 10000;  // BUSY -> DONE must arrive within this (longest animation + margin)
final int PORT_CHECK_MS      = 1000;   // how often to check the port still exists
final int DISPLAY_MS         = 2000;   // how long the accepted gesture stays on screen (display only)
final int HEARTBEAT_MS       = 500;    // no /head/status for this long = head_pose_osc not running
final int TRACKING_SETTLE_MS = 1000;   // tracking must be clean this long before a gesture counts
final boolean PRINT_POSE     = true;   // print every "pitch yaw" sample (20 lines/s)
final boolean PRINT_DEBUG    = true;   // echo Arduino "DEBUG:" lines (never affect state)
// /wek/outputs carries DTW distances (lower = better match). Watch the console
// while you nod: set this between the idle value and the value a real nod reaches.
final float MATCH_DISTANCE   = 50.0;
// ----------------

final String[] STATUS_NAMES = {"calibrating", "tracking", "face lost (holding)", "face lost", "recovering"};
final int TRACKING = 1;

// robot states
final int NOT_READY = 0, READY = 1, AWAIT_ACK = 2, BUSY = 3, FAULT = 4;
final String[] ROBOT_NAMES = {"NOT READY", "READY", "WAITING FOR BUSY", "BUSY", "FAULT"};

OscP5 osc;
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
boolean lastMsgMapped = false;
boolean nodWasIn = false;
boolean shakeWasIn = false;

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

void setup() {
  size(460, 320);
  textAlign(CENTER, CENTER);
  osc = new OscP5(this, 12000);
  openSerial();
}

// ================= serial =================

void openSerial() {
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
      } else {
        fault("READY while waiting for BUSY on " + pendingCmd + " - Arduino reset? command cancelled");
      }
      break;
    case BUSY:
      if (line.equals("DONE")) {
        println("COMMAND " + pendingCmd + " done");
        pendingCmd = "";
        setRobot(READY);
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

void keyPressed() {
  if (key == 'r' || key == 'R') recover();
}

// The only place a command is sent. Marks busy BEFORE writing.
void sendCommand(String g) {
  String code = g.equals("nod") ? "N" : "S";
  pendingCmd = code;
  setRobot(AWAIT_ACK);            // gate closed before anything leaves
  try {
    arduino.write(code);
    println("COMMAND SENT " + code);
  } catch (Exception e) {
    fault("write failed for " + code + " (" + e.getMessage() + ")");
  }
}

// ================= OSC / gestures =================

// Why a gesture arriving now must be ignored, or null if tracking is valid. Lock held.
String trackingProblem(int now) {
  if (now - headStatusTime > HEARTBEAT_MS) return "tracking unavailable (no heartbeat from head_pose_osc)";
  if (headStatus != TRACKING) return "tracking unavailable (" + statusName(headStatus) + ")";
  int clean = now - trackingSince;
  if (clean < TRACKING_SETTLE_MS) return "tracking unstable (clean for only " + clean + " ms)";
  return null;
}

String statusName(int s) {
  return (s >= 0 && s < STATUS_NAMES.length) ? STATUS_NAMES[s] : "unknown " + s;
}

// OSC thread: logs, records status, queues detections; never touches the robot.
void oscEvent(OscMessage msg) {
  String a = msg.addrPattern();
  int now = millis();
  synchronized (lock) {
    if (a.equals("/head/status")) {
      int s = msg.get(0).intValue();
      if (s == TRACKING && headStatus != TRACKING) trackingSince = now;
      if (s != TRACKING) trackingSince = -1;
      if (s != headStatus) println("TRACKING " + statusName(s));
      headStatus = s;
      headStatusTime = now;
      return;
    }
    if (a.equals("/head/pose")) {
      if (PRINT_POSE) println(nf(msg.get(0).floatValue(), 0, 2) + " " + nf(msg.get(1).floatValue(), 0, 2));
      return;
    }
    String raw = a + " " + msg.typetag();
    for (int i = 0; i < msg.arguments().length; i++) raw += " " + msg.arguments()[i];
    println(raw);
    lastMsg = raw;
    lastMsgTime = now;

    String g = null;
    if (a.equals("/output_1")) g = "nod";
    else if (a.equals("/output_2")) g = "shake";
    else if (a.equals("/wek/outputs") && msg.arguments().length >= 2) {
      // DTW distances [nod, shake], lower = closer. Fire once per dip below MATCH_DISTANCE.
      float dNod = msg.get(0).floatValue(), dShake = msg.get(1).floatValue();
      boolean nodIn = dNod < MATCH_DISTANCE, shakeIn = dShake < MATCH_DISTANCE;
      if (nodIn && !nodWasIn && dNod <= dShake) g = "nod";
      else if (shakeIn && !shakeWasIn && dShake < dNod) g = "shake";
      nodWasIn = nodIn;
      shakeWasIn = shakeIn;
      lastMsgMapped = true;
      if (g == null) return;
    }
    if (!a.equals("/wek/outputs")) lastMsgMapped = (g != null);
    if (g == null) return;
    println("RECEIVED " + g);
    qGesture.add(g);
    qReject.add(trackingProblem(now));
  }
}

// Draw thread: accept or ignore each detection. Never queues for later.
void handleGesture(String g, String trackingReject) {
  if (trackingReject != null) {
    lastResult = "IGNORED " + g + ": " + trackingReject;
  } else if (robot != READY) {
    String why = robot == FAULT ? "robot fault (" + faultReason + ")"
               : robot == NOT_READY ? "robot not ready (no READY yet)"
               : "robot busy with " + pendingCmd;
    lastResult = "IGNORED " + g + ": " + why;
  } else {
    lastResult = "ACCEPTED " + g;
    println(lastResult);
    shown = g;
    shownAt = millis();
    sendCommand(g);
    return;
  }
  println(lastResult);
}

// ================= main loop =================

void draw() {
  int now = millis();

  // 1. drain both queues (serial first, so a DONE frees the robot before new gestures)
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

  // 2. render
  String problem, lm;
  int lmTime;
  boolean mapped;
  synchronized (lock) {
    problem = trackingProblem(now);
    lm = lastMsg;
    lmTime = lastMsgTime;
    mapped = lastMsgMapped;
  }
  boolean wekSeen = lmTime > 0;

  background(0);
  fill(255);
  if (now - shownAt < DISPLAY_MS) {
    textSize(48);
    text(shown.toUpperCase(), width/2, 60);
  } else {
    textSize(24);
    text(wekSeen ? "idle" : "waiting for Wekinator...", width/2, 60);
  }

  // robot state
  textSize(18);
  color rc = robot == READY ? color(0, 220, 0)
           : robot == FAULT ? color(230, 60, 60)
           : robot == NOT_READY ? color(150) : color(230, 180, 60);
  fill(rc);
  String rs2 = "robot: " + ROBOT_NAMES[robot];
  if (robot == AWAIT_ACK || robot == BUSY) rs2 += " " + pendingCmd + " (" + (now - stateSince) + " ms)";
  text(rs2, width/2, 130);
  if (robot == FAULT) {
    textSize(12);
    text(faultReason, width/2, 155);
    text("press 'r' to recover", width/2, 172);
  }

  textSize(13);
  fill(problem == null ? color(0, 220, 0) : color(230, 80, 60));
  text(problem == null ? "tracking OK" : problem, width/2, height - 100);
  fill(lastResult.startsWith("ACCEPTED") ? color(0, 220, 0)
       : lastResult.startsWith("IGNORED") ? color(230, 160, 60) : color(255));
  text(lastResult.length() > 0 ? lastResult : "verdict: no gestures yet", width/2, height - 80);
  fill(255);
  String age = wekSeen ? " (" + (now - lmTime) + " ms ago)" : "";
  text("wekinator: " + lm + age, width/2, height - 50);
  if (wekSeen && !mapped) {
    fill(230, 160, 60);
    text("address not mapped - expected /output_1, /output_2 or /wek/outputs", width/2, height - 30);
  }
}
