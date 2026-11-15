#pragma once
// ======================================================================
// bubble_movements.h - poses and gestures for bubble.ino
//
// Poses are copied from movement-sequences.h (nod/shake from the tested
// head test). Gestures are what each serial command plays: they pick the
// easing, then run one or more poses back to back. The robot stays BUSY
// until the whole gesture has finished.
//
// Easing words: <curve>[-<style>][@<deg/s>], e.g. "cubic@483 r4 bounce@100".
// Servos not named keep the easing set before them in the same gesture.
// Every gesture starts from "none@150" (instant writes) on all servos.
// ======================================================================
#include <Arduino.h>

enum ServoName : uint8_t {
  R1 = 0, R2 = 1, L1 = 2, L2 = 3, R4 = 4, R3 = 5, L3 = 6, L4 = 7,
  HU = 8,   // head upper servo (pin 4)
  HL = 9    // head lower servo (pin 3)
};

const String ServoNames[] = {"R1","R2","L1","L2","R4","R3","L3","L4","HU","HL"};

// Provided by bubble.ino
extern void setServoAngle(uint8_t channel, int angle);
extern void delayWithFace(unsigned long ms);
extern void useEasing(const char* spec);   // finishes queued moves, then changes easing
extern void useSync(bool on);              // true: servos in a step all arrive together
extern void debugLine(const __FlashStringHelper* msg);

// ====== POSES (from movement-sequences.h) ======
inline void runStandPose() {
  setServoAngle(R1, 135);
  setServoAngle(R2, 45);
  setServoAngle(L1, 45);
  setServoAngle(L2, 135);
  setServoAngle(R4, 0);
  setServoAngle(R3, 180);
  setServoAngle(L3, 0);
  setServoAngle(L4, 180);
}

inline void runCutePose() {
  debugLine(F("DEBUG: cute"));
  runStandPose();
  delayWithFace(200);
  setServoAngle(L2, 160);
  setServoAngle(R2, 20);
  setServoAngle(R4, 180);
  setServoAngle(L4, 0);

  setServoAngle(L1, 0);
  setServoAngle(R1, 180);
  setServoAngle(L3, 180);
  setServoAngle(R3, 0);
  delayWithFace(200);
  for (int i = 0; i < 3; i++) {
    setServoAngle(R4, 165);
    setServoAngle(L4, 90);
    delayWithFace(300);
    setServoAngle(R4, 90);
    setServoAngle(L4, 15);
    delayWithFace(300);
  }
  runStandPose();
}

inline void runWavePose() {
  debugLine(F("DEBUG: wave"));
  runStandPose();
  delayWithFace(200);
  setServoAngle(R4, 80); setServoAngle(L3, 150);
  setServoAngle(L2, 70); setServoAngle(R1, 100);
  delayWithFace(200);
  setServoAngle(L3, 180);
  delayWithFace(300);
  for (int i = 0; i < 2; i++) {
    setServoAngle(L3, 180); delayWithFace(300);
    setServoAngle(L3, 100); delayWithFace(300);
  }
  runStandPose();
}

inline void runDisappointedPose() {
  debugLine(F("DEBUG: disappointed"));
  setServoAngle(HL, 90);  setServoAngle(HU, 90);    // start
  delayWithFace(300);
  setServoAngle(HL, 90);
  setServoAngle(HU, 12);
  delayWithFace(300);
  setServoAngle(HU, 180);
  setServoAngle(HL, 90);
  delayWithFace(300);
  setServoAngle(HU, 180);
  setServoAngle(HL, 0);
}

inline void runDisappointedReset() {          // lifts the head back up
  debugLine(F("DEBUG: head reset"));
  setServoAngle(HU, 90);
  delayWithFace(300);
  setServoAngle(HL, 90);
  delayWithFace(300);
}

// Nod as in the head test: (S1, S2) = (HU, HL)
inline void runNodPose() {
  debugLine(F("DEBUG: nod"));
  setServoAngle(HU, 70);  setServoAngle(HL, 120);   // rest
  delayWithFace(300);
  for (int i = 0; i < 4; i++) {
    setServoAngle(HU, 120); setServoAngle(HL, 60);
    delayWithFace(300);
    setServoAngle(HU, 60);  setServoAngle(HL, 120);
    delayWithFace(300);
  }
  setServoAngle(HU, 70);  setServoAngle(HL, 120);   // back to rest
}

// Shake: L1 turns the head through the crank. Sweeps 0 -> 135 -> 0, then
// returns to where stand puts it.
const int SHAKE_MIN    = 0;
const int SHAKE_MAX    = 135;
const int SHAKE_HOME   = 45;   // L1's stand angle - where the shake starts and ends
const int SHAKE_SWEEPS = 1;    // how many 0 -> 135 -> 0 sweeps
inline void runShakePose() {
  debugLine(F("DEBUG: shake"));
  setServoAngle(L1, SHAKE_HOME);
  delayWithFace(0);
  for (int i = 0; i < SHAKE_SWEEPS; i++) {
    setServoAngle(L1, SHAKE_MIN);
    delayWithFace(100);
    setServoAngle(L1, SHAKE_MAX);
    delayWithFace(100);
  }
  setServoAngle(L1, SHAKE_MIN);
  delayWithFace(100);
  setServoAngle(L1, SHAKE_HOME);
}

// ====== GESTURES (one per serial command) ======
inline void gestureNod() {                    // N
  useSync(true);
  useEasing("hu linear@150 hl linear@150");
  runNodPose();
}

inline void gestureShake() {                  // S
  useEasing("l1 sine@67");                    // same pace as the tested shake
  runShakePose();
}

inline void gestureWaveSmiling() {            // W: cute, then wave
  useEasing("cubic@350 r4 bounce@100 l4 bounce@100");
  runCutePose();
  useEasing("cubic@483 l3 circular-inout@660");
  runWavePose();
}

inline void gestureWaveNotSmiling() {         // F: disappointed, then wave
  useEasing("hu quadratic@150 hl quadratic@150");
  runDisappointedPose();
  useEasing("linear@300 l3 bounce@70");
  runWavePose();
  useEasing("hu quadratic@150 hl quadratic@150");
  runDisappointedReset();
}
