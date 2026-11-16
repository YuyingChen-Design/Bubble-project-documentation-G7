// Reads the smile classifier (Wekinator #2) and smile_osc.py tracking status.
// Pipeline: smile_osc.py -> Wekinator #2 (classifier, input port 6449) -> this sketch
//                      \-> /smile/status heartbeat + /smile/features -> this sketch
//
// Requires the "oscP5" library.
// Port 12000 (shared with the head-pose pipeline; every message has its own address):
//   /smile/outputs f  (Wekinator #2)  -> class: SMILE_CLASS = smiling, NEUTRAL_CLASS = not smiling
//   /smile/status i   (smile_osc.py)  -> 0 starting, 1 tracking, 2 holding, 3 lost, 4 off angle
//   /smile/features ff(smile_osc.py)  -> mouthSmileLeft mouthSmileRight (logging only)
//
// In Wekinator #2's output settings set: OSC message "/smile/outputs", port 12000.
// (Leaving it on /wek/outputs would collide with the head-pose Wekinator.)
//
// A classifier value is ACCEPTED only if tracking is valid at arrival:
//   heartbeat fresh AND status TRACKING continuously for SMILE_SETTLE_MS.
// Otherwise it is IGNORED with a reason and the smile state becomes UNKNOWN.
// No threshold / debounce yet: the classifier's class is used as-is.
//
// Merge-ready: everything smile-specific lives in smile*() functions and the
// SMILE_* constants. oscEvent() only dispatches, so the combined sketch can call
// smileOscEvent(msg) next to the head-pose handler and drawSmilePanel() in draw().

import oscP5.*;
import netP5.*;

// ---- smile config ----
final String SMILE_OUTPUT_ADDR   = "/smile/outputs";
final String SMILE_STATUS_ADDR   = "/smile/status";
final String SMILE_FEATURES_ADDR = "/smile/features";
final int    SMILE_CLASS         = 2;      // Wekinator class you trained as "smiling"
final int    NEUTRAL_CLASS       = 1;      // Wekinator class you trained as "not smiling"
final int    SMILE_HEARTBEAT_MS  = 500;    // no /smile/status this long = smile_osc.py not running
final int    SMILE_SETTLE_MS     = 300;    // tracking must be clean this long before trusting a class
final boolean SMILE_PRINT_FEATURES = false; // print every "L R" sample (20 lines/s)
// ----------------------

final String[] SMILE_STATUS_NAMES = {"starting", "tracking", "face lost (holding)", "face lost", "face turned too far"};
final int SMILE_TRACKING = 1;

// smile state values
final int SMILE_UNKNOWN = -1, SMILE_NO = 0, SMILE_YES = 1;

OscP5 osc;
final Object smileLock = new Object();

// all guarded by smileLock (written on the OSC thread, read in draw)
int smileStatus = -1;
int smileStatusTime = -100000;
int smileTrackingSince = -1;
float smileL = 0, smileR = 0;
int smileFeaturesTime = -100000;
String smileLastRaw = "(none yet)";
int smileLastRawTime = -100000;
int smileState = SMILE_UNKNOWN;
String smileLastLog = "";          // last logged verdict key, to avoid 20 lines/s of spam
String smileVerdict = "";

void setup() {
  size(420, 300);
  textAlign(CENTER, CENTER);
  osc = new OscP5(this, 12000);
}

java.util.HashSet<String> unhandledSeen = new java.util.HashSet<String>();

void oscEvent(OscMessage msg) {
  if (smileOscEvent(msg)) return;
  // (combined sketch: head-pose handler goes here)

  // Anything else: report each unknown address once, e.g. Wekinator still on /wek/outputs.
  String a = msg.addrPattern();
  if (unhandledSeen.add(a)) {
    String raw = a + " " + msg.typetag();
    for (int i = 0; i < msg.arguments().length; i++) raw += " " + msg.arguments()[i];
    println("UNHANDLED " + raw + "   <- not " + SMILE_OUTPUT_ADDR + "? check Wekinator #2 output message name");
  }
}

void draw() {
  background(0);
  drawSmilePanel();
}

// ================= smile =================

String smileStatusName(int s) {
  return (s >= 0 && s < SMILE_STATUS_NAMES.length) ? SMILE_STATUS_NAMES[s] : "unknown " + s;
}

// Why a classifier value arriving now can't be trusted, or null. Lock held.
String smileTrackingProblem(int now) {
  if (now - smileStatusTime > SMILE_HEARTBEAT_MS) return "tracking unavailable (no heartbeat from smile_osc)";
  if (smileStatus != SMILE_TRACKING) return "tracking unavailable (" + smileStatusName(smileStatus) + ")";
  int clean = now - smileTrackingSince;
  if (clean < SMILE_SETTLE_MS) return "tracking unstable (clean for only " + clean + " ms)";
  return null;
}

// Log once per change of (class, verdict), not once per message.
void smileLog(String key, String line) {
  if (key.equals(smileLastLog)) return;
  smileLastLog = key;
  println(line);
}

// Returns true if the message belonged to the smile pipeline. Runs on the OSC thread.
boolean smileOscEvent(OscMessage msg) {
  String a = msg.addrPattern();
  int now = millis();
  synchronized (smileLock) {
    if (a.equals(SMILE_STATUS_ADDR)) {
      int s = msg.get(0).intValue();
      if (s == SMILE_TRACKING && smileStatus != SMILE_TRACKING) smileTrackingSince = now;
      if (s != SMILE_TRACKING) smileTrackingSince = -1;
      if (s != smileStatus) println("SMILE TRACKING " + smileStatusName(s));
      smileStatus = s;
      smileStatusTime = now;
      return true;
    }
    if (a.equals(SMILE_FEATURES_ADDR)) {
      smileL = msg.get(0).floatValue();
      smileR = msg.get(1).floatValue();
      smileFeaturesTime = now;
      if (SMILE_PRINT_FEATURES) println("smile " + nf(smileL, 0, 3) + " " + nf(smileR, 0, 3));
      return true;
    }
    if (a.equals(SMILE_OUTPUT_ADDR)) {
      String raw = a + " " + msg.typetag();
      for (int i = 0; i < msg.arguments().length; i++) raw += " " + msg.arguments()[i];
      smileLastRaw = raw;
      smileLastRawTime = now;
      if (msg.arguments().length == 0) { smileLog("noargs", "SMILE IGNORED: message has no value"); return true; }

      int cls = round(msg.get(0).floatValue());
      String problem = smileTrackingProblem(now);
      if (problem != null) {
        smileState = SMILE_UNKNOWN;
        smileVerdict = "IGNORED class " + cls + ": " + problem;
      } else if (cls == SMILE_CLASS) {
        smileState = SMILE_YES;
        smileVerdict = "ACCEPTED smiling";
      } else if (cls == NEUTRAL_CLASS) {
        smileState = SMILE_NO;
        smileVerdict = "ACCEPTED not smiling";
      } else {
        smileState = SMILE_UNKNOWN;
        smileVerdict = "IGNORED class " + cls + ": not " + NEUTRAL_CLASS + " or " + SMILE_CLASS;
      }
      smileLog(smileVerdict, "SMILE " + smileVerdict + "   (" + raw + ")");
      return true;
    }
  }
  return false;
}

void drawSmilePanel() {
  int now = millis();
  int state, status;
  String problem, verdict, raw;
  int rawTime, featTime;
  float l, r;
  synchronized (smileLock) {
    problem = smileTrackingProblem(now);
    state = smileState;
    status = smileStatus;
    verdict = smileVerdict;
    raw = smileLastRaw;
    rawTime = smileLastRawTime;
    featTime = smileFeaturesTime;
    l = smileL;
    r = smileR;
  }
  boolean wekSeen = rawTime > 0;
  // a class that is no longer arriving shouldn't be shown as current
  if (wekSeen && now - rawTime > SMILE_HEARTBEAT_MS) state = SMILE_UNKNOWN;

  // big state
  textSize(40);
  if (!wekSeen) {
    textSize(22);
    fill(255);
    text("waiting for smile Wekinator...", width/2, 50);
  } else if (state == SMILE_YES) {
    fill(0, 220, 0);
    text("SMILING", width/2, 50);
  } else if (state == SMILE_NO) {
    fill(255);
    text("NOT SMILING", width/2, 50);
  } else {
    fill(150);
    text("UNKNOWN", width/2, 50);
  }

  // feature bars (what Wekinator receives)
  boolean featFresh = now - featTime <= SMILE_HEARTBEAT_MS;
  drawSmileBar("left",  l, 110, featFresh);
  drawSmileBar("right", r, 135, featFresh);

  textSize(13);
  fill(problem == null ? color(0, 220, 0) : color(230, 80, 60));
  text(problem == null ? "tracking OK" : problem, width/2, height - 90);
  fill(verdict.startsWith("ACCEPTED") ? color(0, 220, 0)
       : verdict.startsWith("IGNORED") ? color(230, 160, 60) : color(255));
  text(verdict.length() > 0 ? verdict : "verdict: nothing yet", width/2, height - 65);
  fill(255);
  String age = wekSeen ? " (" + (now - rawTime) + " ms ago)" : "";
  text("wekinator: " + raw + age, width/2, height - 40);
}

void drawSmileBar(String label, float v, int y, boolean fresh) {
  int x = 110, w = 220, h = 14;
  textSize(12);
  fill(255);
  textAlign(RIGHT, CENTER);
  text(label, x - 8, y);
  textAlign(LEFT, CENTER);
  text(fresh ? nf(v, 0, 2) : "--", x + w + 8, y);
  textAlign(CENTER, CENTER);
  noFill();
  stroke(255);
  rect(x, y - h/2, w, h);
  noStroke();
  fill(fresh ? color(0, 180, 220) : color(80));
  rect(x, y - h/2, w * constrain(v, 0, 1), h);
}
