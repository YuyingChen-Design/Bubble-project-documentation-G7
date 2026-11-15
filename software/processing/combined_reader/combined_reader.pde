// Combined reader: head nod/shake (Wekinator #1 DTW) + smile (Wekinator #2 classifier)
//                  + hand wave (Wekinator #3 DTW) -> one interaction -> Arduino.
//
// Requires the "oscP5" library. Everything arrives on port 12000; each message is
// routed by its address. The first time each address arrives it is logged as
// "ADDRESS <addr> -> <route>", so the routing can be verified at startup.
//
// ROUTING TABLE (port 12000)
//   address          sender                      route   meaning
//   /output_1        Wekinator #1 (head, DTW)    head    nod detection
//   /output_2        Wekinator #1 (head, DTW)    head    shake detection
//   /smile/outputs   Wekinator #2 (smile, clf)   smile   class: 1 smiling, 2 straight-faced
//   /wave/outputs    Wekinator #3 (wave, DTW)    wave    wave detection (every message)
//   /head/status     combined_osc.py             head    tracking validity heartbeat
//   /head/pose       combined_osc.py             head    pitch yaw (logging)
//   /smile/status    combined_osc.py             smile   tracking validity heartbeat
//   /smile/features  combined_osc.py             smile   mouthSmileLeft/Right (display)
//   /wave/status     combined_osc.py             wave    tracking validity heartbeat
//   /wave/features   combined_osc.py             wave    z values sent to Wekinator #3 (display)
//   /wave/angle      combined_osc.py             wave    phi degrees (display)
//   anything else                                -       logged once as UNHANDLED
//
// Wekinator setup:
//   #1 head  DTW        : input :6448, output :12000 (gesture messages /output_1, /output_2)
//   #2 smile classifier : input :6449, output :12000, message "/smile/outputs"
//   #3 wave  DTW        : input :6450, output :12000, message "/wave/outputs"
//   NOTE: if Wekinator #3 also sends a per-gesture "/output_1" on a match, it cannot be
//   told apart from the head nod on this port. Watch the ADDRESS lines at startup.
//
// Tabs:
//   combined_reader.pde : setup, draw, OSC dispatch, keys, routing (this file)
//   head.pde            : nod/shake + Arduino READY/BUSY/DONE state machine
//   smile.pde           : smile classifier + tracking checks (records predictions)
//   wave.pde            : wave detections + tracking checks
//   interaction.pde     : shared interaction state, expression assessment, command table
//
// Keys: r = recover the robot from FAULT (only when ROBOT_ENABLED)

import oscP5.*;
import netP5.*;
import processing.serial.*;
import java.util.ArrayList;
import java.util.HashSet;

// ---- robot on/off ----
// false = pipeline verification only: no serial port is opened, nothing is sent
// to the Arduino, and gestures that pass their checks are ACCEPTED / DECIDED without
// the robot gate. true = full READY/BUSY/DONE robot interaction from head.pde.
final boolean ROBOT_ENABLED = true;

final int BAR_H = 60;                         // interaction bar at the top
final int PANEL_H = 320;                      // height of each pipeline panel
final int HEAD_PANEL_X = 0,    HEAD_PANEL_W = 460;
final int SMILE_PANEL_X = 470, SMILE_PANEL_W = 420;
final int WAVE_PANEL_X = 900,  WAVE_PANEL_W = 420;

OscP5 osc;
HashSet<String> addressesSeen = new HashSet<String>();

void setup() {
  size(1320, 380);                            // BAR_H + PANEL_H
  textAlign(CENTER, CENTER);
  osc = new OscP5(this, 12000);
  if (ROBOT_ENABLED) openSerial();
  else println("ROBOT DISABLED (ROBOT_ENABLED = false): serial not opened, no commands will be sent");
}

// OSC thread: route each message to its pipeline; log each address the first time.
void oscEvent(OscMessage msg) {
  String route = "UNHANDLED";
  if (smileOscEvent(msg)) route = "smile";
  else if (headOscEvent(msg)) route = "head";
  else if (waveOscEvent(msg)) route = "wave";

  String a = msg.addrPattern();
  boolean first;
  synchronized (addressesSeen) { first = addressesSeen.add(a); }
  if (first) {
    String raw = a + " " + msg.typetag();
    for (int i = 0; i < msg.arguments().length; i++) raw += " " + msg.arguments()[i];
    println("ADDRESS " + a + " -> " + route + "   (first message: " + raw + ")");
  }
}

void draw() {
  // order: serial replies + robot health + nod/shake, then the running assessment,
  // then wave detections (so a wave can't start while a command was just sent)
  headUpdate();
  exprUpdate();
  waveUpdate();

  background(0);
  drawInteractionBar(width, BAR_H);

  pushMatrix();
  translate(HEAD_PANEL_X, BAR_H);
  drawHeadPanel(HEAD_PANEL_W);
  popMatrix();

  stroke(70);
  line(SMILE_PANEL_X - 5, BAR_H + 10, SMILE_PANEL_X - 5, height - 10);
  line(WAVE_PANEL_X - 5, BAR_H + 10, WAVE_PANEL_X - 5, height - 10);
  noStroke();

  pushMatrix();
  translate(SMILE_PANEL_X, BAR_H);
  drawSmilePanel(SMILE_PANEL_W);
  popMatrix();

  pushMatrix();
  translate(WAVE_PANEL_X, BAR_H);
  drawWavePanel(WAVE_PANEL_W);
  popMatrix();
}

void keyPressed() {
  if (ROBOT_ENABLED && (key == 'r' || key == 'R')) recover();
}
