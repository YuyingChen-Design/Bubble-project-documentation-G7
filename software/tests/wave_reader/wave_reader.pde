// Reads the hand-wave DTW model (Wekinator #3) and wave_osc.py tracking status.
// Pipeline: wave_osc.py -> Wekinator #3 (DTW, input port 6450) -> this sketch
//                     \-> /wave/status heartbeat + /wave/features + /wave/angle -> this sketch
//
// Requires the "oscP5" library.
// Port 12000 (shared with head + smile pipelines; every message has its own address):
//   /wave/outputs ... (Wekinator #3) -> shown and logged EXACTLY as received
//   /wave/status i    (wave_osc.py)  -> 0 no hand, 1 tracking, 2 calibrating,
//                                       3 reset (extractor history restarted -> settle timer restarts)
//   /wave/features f..(wave_osc.py)  -> the exact floats Wekinator receives (logging only)
//   /wave/angle f     (wave_osc.py)  -> smoothed tilt phi in degrees (display only)
//
// In Wekinator #3's output settings set: OSC message "/wave/outputs", port 12000.
// (Leaving it on /wek/outputs would collide with the head-pose Wekinator.)
//
// NO post-processing of Wekinator's result: no threshold, no edge detection, no
// interpretation. Each /wave/outputs message is only tagged VALID or INVALID from
// the tracking status at the moment it arrives:
//   VALID   = heartbeat fresh AND hand tracked continuously for WAVE_SETTLE_MS
//   INVALID = anything else (reason shown)
// This is a pipeline check only. No robot output.
//
// Merge-ready: everything lives in wave*() functions and WAVE_* constants;
// oscEvent() only dispatches, draw() calls drawWavePanel(w).

import oscP5.*;
import netP5.*;
import java.util.HashSet;

// ---- wave config ----
final String WAVE_OUTPUT_ADDR   = "/wave/outputs";
final String WAVE_STATUS_ADDR   = "/wave/status";
final String WAVE_FEATURES_ADDR = "/wave/features";
final String WAVE_ANGLE_ADDR    = "/wave/angle";
final int    WAVE_HEARTBEAT_MS  = 500;    // no /wave/status this long = wave_osc.py not running
final int    WAVE_SETTLE_MS     = 1000;   // hand must be tracked this long (>= one wave) to call a result VALID
final boolean WAVE_PRINT_RAW    = true;   // print every /wave/outputs message
// ---------------------

final String[] WAVE_STATUS_NAMES = {"no hand", "tracking", "calibrating", "reset (reacquired / hand changed / gap)"};
final int WAVE_TRACKING = 1;

OscP5 osc;
HashSet<String> unhandledSeen = new HashSet<String>();

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
String waveLastLoggedValidity = "";

void setup() {
  size(420, 320);
  textAlign(CENTER, CENTER);
  osc = new OscP5(this, 12000);
}

void oscEvent(OscMessage msg) {
  if (waveOscEvent(msg)) return;
  // (combined sketch: head + smile handlers go here)

  String a = msg.addrPattern();
  if (unhandledSeen.add(a)) {
    String raw = a + " " + msg.typetag();
    for (int i = 0; i < msg.arguments().length; i++) raw += " " + msg.arguments()[i];
    println("UNHANDLED " + raw + "   <- not " + WAVE_OUTPUT_ADDR + "? check Wekinator #3 output message name");
  }
}

void draw() {
  background(0);
  drawWavePanel(width);
}

// ================= wave =================

String waveStatusName(int s) {
  return (s >= 0 && s < WAVE_STATUS_NAMES.length) ? WAVE_STATUS_NAMES[s] : "unknown " + s;
}

// Why a result arriving now can't be trusted, or null. Lock held.
String waveTrackingProblem(int now) {
  if (now - waveStatusTime > WAVE_HEARTBEAT_MS) return "no heartbeat from wave_osc";
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
      else if (!validity.equals(waveLastLoggedValidity)) println("WAVE " + validity);
      waveLastLoggedValidity = validity;
      return true;
    }
  }
  return false;
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

  // validity
  fill(problemNow == null ? color(0, 220, 0) : color(230, 80, 60));
  text(problemNow == null ? "wave tracking OK" : "tracking: " + problemNow, cx, height - 95);
  fill(lastProblem == null ? color(0, 220, 0) : color(230, 160, 60));
  text(!wekSeen ? "last result: none yet"
       : "last result: " + (lastProblem == null ? "VALID" : "INVALID (" + lastProblem + ")"), cx, height - 70);
  fill(255);
  String age = wekSeen ? " (" + (now - rawTime) + " ms ago)" : "";
  text("wekinator: " + raw + age, cx, height - 40);
}
