// ======================================================================
// bubble.ino - Sesame robot firmware for the Processing / Wekinator link
// Nano Every. Same easing engine as sesame_easing.ino, same serial
// protocol as the gesture test and mock_robot.ino.
//
// Commands (single character, 115200 baud, newline optional):
//   N = nod              HU, HL linear @150
//   S = shake            L1 sweeps +50 -> -50 (turns the head)
//   W = wavesmiling      cute, then wave
//   F = wavenotsmiling   disappointed, then wave
//   ? = ping             answers READY when idle
//
// Protocol lines (exact, nothing else on the line):
//   READY  after set-up (and in answer to '?' when idle)
//   BUSY   command accepted, gesture starting
//   DONE   whole gesture finished, including its final servo move
// Commands that arrive while busy are read and thrown away, never queued.
// Everything else printed starts with "DEBUG:".
//
// Built-in LED while busy: N = 1 blink, S = 2, W = 3, F = 4 (repeating).
//
// The gestures and poses live in bubble_movements.h.
// Needs the "ServoEasing" library by Armin Joachimsmeyer.
// ======================================================================
// ================= WIRING - FILL IN =================
// The Nano Every pin each servo's signal wire is plugged into.
// Any pin left as PIN_NOT_SET (or used twice) stops the robot from
// reporting READY, and the Serial Monitor shows a DEBUG line saying which.
#define PIN_NOT_SET 255

const uint8_t PIN_R1 = 7;   // right hip 1   (its knee is R3)
const uint8_t PIN_R2 = 6;   // right hip 2   (its knee is R4)
const uint8_t PIN_L1 = 11;   // left hip 1    (its knee is L3) - turns the head in shake
const uint8_t PIN_L2 = 10;   // left hip 2    (its knee is L4)
const uint8_t PIN_R4 = 5;   // right knee 4
const uint8_t PIN_R3 = 8;   // right knee 3
const uint8_t PIN_L3 = 12;   // left knee 3   - the waving arm
const uint8_t PIN_L4 = 9;   // left knee 4
const uint8_t PIN_HU = 4;   // head upper servo
const uint8_t PIN_HL = 3;   // head lower servo
// ====================================================

#define MAX_EASING_SERVOS 10     // must be set before the include
#include <ServoEasing.hpp>
#include "bubble_movements.h"

// ================= CONFIG =================
const long BAUD = 115200;
const bool SEND_READY_AFTER_DONE = false;     // same switch as mock_robot.ino

// Same order as the ServoName enum in bubble_movements.h - fill the pins in at the top.
const uint8_t NUM_SERVOS = sizeof(ServoNames) / sizeof(ServoNames[0]);   // 10
const uint8_t servoPins[NUM_SERVOS] = {PIN_R1, PIN_R2, PIN_L1, PIN_L2, PIN_R4,
                                       PIN_R3, PIN_L3, PIN_L4, PIN_HU, PIN_HL};

// Pulse range (matches the ESP32 original, 732-2500 us). The Servo library
// clips to this range, so overshooting curves (back, elastic) can't go past it.
const int SERVO_MIN_US = 732;
const int SERVO_MAX_US = 2500;

int motorCurrentDelay = 20;  // ms pause after each instant ('none') servo write
int8_t servoSubtrim[NUM_SERVOS] = {0, 0, 0, 0, 0, 0, 0, 0, 0, 0};

// Servos attached at power-up, and where they start (the rest stay limp until used)
struct StartPos { uint8_t ch; uint8_t angle; };
const StartPos START_POSITIONS[] = {
  {R1, 135}, {R2, 45}, {L1, 45}, {L2, 135},    // stand, as in sesame_easing
  {R4, 0},   {R3, 180}, {L3, 0}, {L4, 180},
  {HU, 70},  {HL, 120},                        // head at the nod's rest position
};

struct CmdInfo { char c; const char* name; uint8_t blinks; };
const CmdInfo CMDS[] = {
  {'N', "nod",            1},
  {'S', "shake",          2},
  {'W', "wavesmiling",    3},
  {'F', "wavenotsmiling", 4},
};
const uint8_t N_CMDS = sizeof(CMDS) / sizeof(CMDS[0]);
// ==========================================

// --- EASING TABLES ------------------------------------------------------
const uint8_t EASING_NONE = 0xFF;    // instant write, like the original firmware
const uint8_t CURVE_SPECIAL_BOUNCE = 0xFE;
const uint8_t CURVE_SPECIAL_PRECISION = 0xFD;

struct NamedValue { const char* name; uint8_t value; };
const NamedValue curveTable[] = {
  {"none",      EASING_NONE},
  {"linear",    EASE_LINEAR},
  {"quadratic", EASE_QUADRATIC_IN},
  {"cubic",     EASE_CUBIC_IN},
  {"quartic",   EASE_QUARTIC_IN},
  {"sine",      EASE_SINE_IN},
  {"circular",  EASE_CIRCULAR_IN},
  {"back",      EASE_BACK_IN},
  {"elastic",   EASE_ELASTIC_IN},
  {"bounce",    CURVE_SPECIAL_BOUNCE},
  {"precision", CURVE_SPECIAL_PRECISION},
  {"user",      EASE_USER_IN},
};
const uint8_t CURVE_COUNT = sizeof(curveTable) / sizeof(curveTable[0]);

const NamedValue styleTable[] = {
  {"in",       CALL_STYLE_IN},
  {"out",      CALL_STYLE_OUT},
  {"inout",    CALL_STYLE_IN_OUT},
  {"bouncing", CALL_STYLE_BOUNCING_OUT_IN},
};
const uint8_t STYLE_COUNT = sizeof(styleTable) / sizeof(styleTable[0]);

struct EaseSetting { uint8_t type; uint16_t speed; };

// --- STATE --------------------------------------------------------------
ServoEasing servos[NUM_SERVOS];
bool servoAttached[NUM_SERVOS] = {false};
int  lastAngle[NUM_SERVOS];
int  pendingTarget[NUM_SERVOS];
bool hasPending[NUM_SERVOS] = {false};
bool movesPending = false;
EaseSetting activeEase[NUM_SERVOS];
bool syncServos = false;

bool busy = false;
bool wiringOk = false;                   // set in setup(); no READY and no moves until true
const CmdInfo* current = nullptr;
unsigned long busySince = 0;
unsigned long cmdCount = 0;

// NOTE: keep every struct ABOVE the first function in this file. The Arduino
// IDE inserts function prototypes just before the first function, so any
// type defined later is "not declared" in those prototypes.

// --- USER CURVE -----------------------------------------------------------
// Used by the 'user' curve: t goes 0..1, return 0..1 (ease-IN shape).
float userEaseIn(float t, void*) {
  return t * t * (3.0f - 2.0f * t);   // smoothstep - edit me
}

void debugLine(const __FlashStringHelper* msg) { Serial.println(msg); }

// --- SERIAL -------------------------------------------------------------
const CmdInfo* findCmd(char c) {
  for (uint8_t i = 0; i < N_CMDS; i++) if (CMDS[i].c == c) return &CMDS[i];
  return nullptr;
}

void updateLed() {
  if (!busy || !current) { digitalWrite(LED_BUILTIN, LOW); return; }
  const unsigned long step = 300, gap = 700;
  unsigned long period = current->blinks * step + gap;
  unsigned long ph = (millis() - busySince) % period;
  bool on = ph < current->blinks * step && (ph % step) < step / 2;
  digitalWrite(LED_BUILTIN, on ? HIGH : LOW);
}

void runGesture(const CmdInfo* cmd);

// Reads everything waiting. Runs while idle (from loop) AND during gestures
// (from every wait), so serial is never ignored. While busy, nothing queues.
void pollInput() {
  while (Serial.available()) {
    char c = toupper(Serial.read());
    if (c == '\r' || c == '\n' || c == ' ' || c == '\t') continue;
    if (!wiringOk) {
      Serial.println(F("DEBUG: ERROR wiring not filled in - set the PIN_ values at the top of bubble.ino"));
      continue;
    }
    if (c == '?') { if (!busy) Serial.println("READY"); continue; }   // ping
    if (busy) {
      Serial.print(F("DEBUG: ERROR command while busy "));
      Serial.println(c);
      continue;
    }
    const CmdInfo* cmd = findCmd(c);
    if (!cmd) {
      Serial.print(F("DEBUG: unknown command "));
      Serial.println(c);
      continue;
    }
    runGesture(cmd);
  }
  updateLed();
}

// --- EASING ENGINE (same rules as sesame_easing.ino) ----------------------
void waitPolling(unsigned long ms) {
  unsigned long start = millis();
  do { pollInput(); } while (millis() - start < ms);
}

// Start every queued ease (each at its own speed) and wait until all arrive.
void flushMoves() {
  if (!movesPending) return;
  movesPending = false;
  for (uint8_t i = 0; i < NUM_SERVOS; i++) {
    if (!hasPending[i]) continue;
    hasPending[i] = false;
    servos[i].setEaseTo(pendingTarget[i], activeEase[i].speed);
  }
  if (syncServos) synchronizeAllServosAndStartInterrupt(false);  // stretch to slowest
  while (!updateAllServos()) pollInput();   // we poll; no timer interrupt used
}

void applyEasing(const EaseSetting e[NUM_SERVOS]) {
  for (uint8_t i = 0; i < NUM_SERVOS; i++) {
    activeEase[i] = e[i];
    if (e[i].type != EASING_NONE) servos[i].setEasingType(e[i].type);
  }
}

int findName(const NamedValue* table, uint8_t count, const char* name) {
  for (uint8_t i = 0; i < count; i++)
    if (strcmp(name, table[i].name) == 0) return i;
  return -1;
}

// curve + optional style -> ServoEasing type byte, or -1 if not a valid combo
int makeEaseType(uint8_t curve, int style /* -1 = not given */) {
  if (curve == EASING_NONE) return style < 0 ? EASING_NONE : -1;
  if (curve == CURVE_SPECIAL_BOUNCE) {
    if (style < 0 || style == CALL_STYLE_OUT) return EASE_BOUNCE_OUT;
    if (style == CALL_STYLE_IN) return EASE_BOUNCE_IN;
    return -1;
  }
  if (curve == CURVE_SPECIAL_PRECISION) {
    if (style < 0 || style == CALL_STYLE_OUT) return EASE_PRECISION_OUT;
    if (style == CALL_STYLE_IN) return EASE_PRECISION_IN;
    return -1;
  }
  if (curve == EASE_LINEAR) return style == CALL_STYLE_BOUNCING_OUT_IN ? -1 : EASE_LINEAR;
  return curve | (style < 0 ? CALL_STYLE_IN_OUT : style);
}

// One word: "sine", "sine-out", "back-in@300", "@80"
bool parseSettingWord(char* word, int& type, bool& hasType, int& speed, bool& hasSpeed) {
  hasType = hasSpeed = false;
  char* at = strchr(word, '@');
  if (at) {
    *at = '\0';
    speed = atoi(at + 1);
    if (speed < 1 || speed > 2000) return false;
    hasSpeed = true;
  }
  if (*word == '\0') return hasSpeed;
  char* dash = strchr(word, '-');
  int style = -1;
  if (dash) {
    *dash = '\0';
    int s = findName(styleTable, STYLE_COUNT, dash + 1);
    if (s < 0) return false;
    style = styleTable[s].value;
  }
  int c = findName(curveTable, CURVE_COUNT, word);
  if (c < 0) return false;
  type = makeEaseType(curveTable[c].value, style);
  if (type < 0) return false;
  hasType = true;
  return true;
}

// Servo name ("l3", "HU") or index ("6") -> index, else -1
int servoNameOrIndex(const char* tok) {
  if (tok[0] >= '0' && tok[0] <= '9' && tok[1] == '\0') return tok[0] - '0';
  for (uint8_t i = 0; i < NUM_SERVOS; i++)
    if (strcasecmp(tok, ServoNames[i].c_str()) == 0) return i;
  return -1;
}

const int ALL_SERVOS = 100;
int servoTokenToIndex(const char* tok) {
  if (strcmp(tok, "all") == 0) return ALL_SERVOS;
  return servoNameOrIndex(tok);
}

void applyToServos(EaseSetting out[NUM_SERVOS], int idx, int type, bool hasType, int speed, bool hasSpeed) {
  for (uint8_t i = 0; i < NUM_SERVOS; i++) {
    if (idx != ALL_SERVOS && idx != i) continue;
    if (hasType)  out[i].type = type;
    if (hasSpeed) out[i].speed = speed;
  }
}

// Parse a whole spec into out[] (out holds the starting values).
bool parseEasingSpec(const char* text, EaseSetting out[NUM_SERVOS]) {
  char buf[64];
  strncpy(buf, text, sizeof(buf) - 1);
  buf[sizeof(buf) - 1] = '\0';
  for (char* p = buf; *p; p++) *p = tolower(*p);
  int type, speed;
  bool hasType, hasSpeed;
  for (char* tok = strtok(buf, " "); tok; tok = strtok(nullptr, " ")) {
    int idx = servoTokenToIndex(tok);
    if (idx < 0) {                                    // bare setting = all servos
      if (!parseSettingWord(tok, type, hasType, speed, hasSpeed)) return false;
      applyToServos(out, ALL_SERVOS, type, hasType, speed, hasSpeed);
      continue;
    }
    char* word = strtok(nullptr, " ");
    if (!word || !parseSettingWord(word, type, hasType, speed, hasSpeed)) return false;
    applyToServos(out, idx, type, hasType, speed, hasSpeed);
  }
  return true;
}

// --- HELPERS USED BY bubble_movements.h ------------------------------------
void useEasing(const char* spec) {
  flushMoves();                          // finish anything queued with the old easing
  EaseSetting e[NUM_SERVOS];
  memcpy(e, activeEase, sizeof(e));
  if (parseEasingSpec(spec, e)) applyEasing(e);
  else { Serial.print(F("DEBUG: ERROR bad easing spec: ")); Serial.println(spec); }
}

void useSync(bool on) {
  flushMoves();
  syncServos = on;
}

void delayWithFace(unsigned long ms) {
  flushMoves();          // finish the servos set since the last pause
  waitPolling(ms);
}

void setServoAngle(uint8_t channel, int angle) {
  if (channel >= NUM_SERVOS || servoPins[channel] == PIN_NOT_SET) return;
  int adjusted = constrain(angle + servoSubtrim[channel], 0, 180);

  // Attach on first use, so servos stay limp at power-on.
  // The first position can't be eased (start position unknown), so it jumps.
  if (!servoAttached[channel]) {
    servos[channel].attach(servoPins[channel], adjusted, SERVO_MIN_US, SERVO_MAX_US);
    servoAttached[channel] = true;
    lastAngle[channel] = adjusted;
    waitPolling(motorCurrentDelay);
    return;
  }

  uint8_t type = activeEase[channel].type;
  if (type == EASING_NONE) {
    servos[channel].write(adjusted);          // instant
    lastAngle[channel] = adjusted;
    waitPolling(motorCurrentDelay);
  } else if (adjusted != lastAngle[channel]) {
    pendingTarget[channel] = adjusted;        // starts at the next pause
    hasPending[channel] = true;
    movesPending = true;
    // A bouncing style goes to the target and comes back, so it ends where it began.
    if ((type & CALL_STYLE_MASK) != CALL_STYLE_BOUNCING_OUT_IN)
      lastAngle[channel] = adjusted;
  }
}

// --- GESTURES -------------------------------------------------------------
void resetEasing() {
  EaseSetting e[NUM_SERVOS];
  for (uint8_t i = 0; i < NUM_SERVOS; i++) e[i] = {EASING_NONE, 150};
  applyEasing(e);
  syncServos = false;
}

void runGesture(const CmdInfo* cmd) {
  busy = true;                           // gate closed before anything moves
  current = cmd;
  busySince = millis();
  cmdCount++;
  Serial.print(F("DEBUG: cmd #")); Serial.print(cmdCount);
  Serial.print(' '); Serial.print(cmd->c);
  Serial.print(F(" (")); Serial.print(cmd->name); Serial.println(')');
  Serial.println("BUSY");

  resetEasing();
  switch (cmd->c) {
    case 'N': gestureNod(); break;
    case 'S': gestureShake(); break;
    case 'W': gestureWaveSmiling(); break;
    case 'F': gestureWaveNotSmiling(); break;
  }
  flushMoves();                          // the last move of a gesture has no pause after it

  busy = false;
  current = nullptr;
  updateLed();
  Serial.println("DONE");
  if (SEND_READY_AFTER_DONE) Serial.println("READY");
}

// --- MAIN ----------------------------------------------------------------
void setup() {
  pinMode(LED_BUILTIN, OUTPUT);
  Serial.begin(BAUD);
  unsigned long t0 = millis();
  while (!Serial && millis() - t0 < 3000) {}   // boards with native USB

  for (uint8_t i = 0; i < NUM_SERVOS; i++) {
    servos[i].registerUserEaseInFunction(userEaseIn);
    lastAngle[i] = 90;
  }
  resetEasing();

  // Check the wiring block at the top before moving anything.
  wiringOk = true;
  for (uint8_t i = 0; i < NUM_SERVOS; i++) {
    if (servoPins[i] == PIN_NOT_SET) {
      Serial.print(F("DEBUG: ERROR pin for ")); Serial.print(ServoNames[i]); Serial.println(F(" not set"));
      wiringOk = false;
      continue;
    }
    for (uint8_t j = 0; j < i; j++) if (servoPins[j] == servoPins[i]) {
      Serial.print(F("DEBUG: ERROR ")); Serial.print(ServoNames[i]); Serial.print(F(" and "));
      Serial.print(ServoNames[j]); Serial.print(F(" both on pin ")); Serial.println((int)servoPins[i]);
      wiringOk = false;
    }
  }
  if (!wiringOk) {
    Serial.println(F("DEBUG: fill in the PIN_ values at the top of bubble.ino, then upload again"));
    return;                              // no servos attached, no READY
  }

  for (const StartPos& s : START_POSITIONS) {
    servos[s.ch].attach(servoPins[s.ch], s.angle, SERVO_MIN_US, SERVO_MAX_US);
    servoAttached[s.ch] = true;
    lastAngle[s.ch] = s.angle;
    delay(motorCurrentDelay);                  // 20 ms between servos, like the main firmware
  }
  delay(300);
  while (Serial.available()) Serial.read();    // drop anything sent during start-up

  Serial.println(F("DEBUG: bubble ready, commands N S W F, ? = ping"));
  Serial.println("READY");
}

void loop() {
  pollInput();
}
