// Burnbot on the Desk Buddy Perch: an ESP32 DevKit with a 1.5" SH1107 OLED (128 x 128, one
// colour, I2C) and six MX keys. See the Perch Quick Start for the build.
//
//   OLED   SDA->GPIO15  SCL->GPIO4  VCC->3V3  GND->GND   address 0x3C (or 0x3D)
//   Keys   PLAY 23  PAUSE 5  OK 21  MIC 22  STOP 18  WIN 19, each to GND (internal pull-ups)
//
// It speaks the same lines as the colour desk screen (burnbot_screen.ino), so the Mac app
// treats it as one: V, P, R, O0/O2, S0-2, Q, B|..., M|.... It draws the same scene from
// render.h, turned to one colour by perch.h. The case window hides the OLED's bottom 12
// rows, so the picture is 128 x 116.
//
// A press of any key sends K, the same as a double knock on the XIAO Sense: Burnbot closes
// the card on screen (with "Knock to close" on in its settings). The app shows the
// knock settings because Q answers k=1; the sensitivity (S) is kept but means nothing here.
//
// After 15 s without a line from the Mac the robot sleeps ("Waiting for the Mac"); after
// 10 minutes the OLED turns off, to spare it, and comes back with the next line or key.

#include <Wire.h>
#include <Preferences.h>
#include <Adafruit_GFX.h>
#include <Adafruit_SH110X.h>
#include "perch.h"

const int I2C_SDA = 15, I2C_SCL = 4;
const int SW_PINS[6] = {23, 5, 21, 22, 18, 19};
const char *const KEY_NAMES[6] = {"PLAY", "PAUSE", "OK", "MIC", "STOP", "WIN"};
const int LED = 2;                          // the blue LED: on while the Mac talks, blinks with each line
const uint8_t ROTATION_NORMAL = 2;          // the module sits upside down in the case

const uint32_t QUIET_MS = 15000;
const uint32_t DARK_MS = 10UL * 60 * 1000;
const uint32_t FRAME_MS = 83;               // 12 frames a second; a whole frame takes ~45 ms over I2C
const uint32_t DEBOUNCE_MS = 25;

// 100 kHz throughout: the OLED has no pull-ups of its own, and the ESP32's weak internal
// ones are too slow for 400 kHz (it answers once, then drops off the bus).
const uint32_t I2C_HZ = 100000;
Adafruit_SH1107 oled(128, pp::OLED_H, &Wire, -1, I2C_HZ, I2C_HZ);
Preferences kept;
bool oledOk = false;
uint8_t oledAddr = 0;

bb::State state;
bb::Moment moment;
bb::Scene scene(pp::AW, pp::AH, pp::LIFT);
static uint16_t art[pp::AW * pp::AH];
static uint8_t frame[pp::W * pp::H];
static uint8_t shown[pp::W * pp::H];

bool waiting = true, lit = true, allStale = true;
uint8_t rotation = 0;                       // 0 the right way up in the case, 2 turned round (the app's O0/O2)
uint8_t sensitivity = 1;
uint32_t heardAt = 0, frameAt = 0, blinkAt = 0;

char line[200];
size_t lineLength = 0;

// ---------- the keys ----------
bool keyDown[6];
uint32_t keyChangedAt[6];
uint32_t presses[6];

void startKeys() {
  for (int i = 0; i < 6; i++) {
    pinMode(SW_PINS[i], INPUT_PULLUP);
    keyDown[i] = digitalRead(SW_PINS[i]) == LOW;
    keyChangedAt[i] = 0;
    presses[i] = 0;
  }
}

void wake();

void checkKeys(uint32_t now) {
  for (int i = 0; i < 6; i++) {
    bool down = digitalRead(SW_PINS[i]) == LOW;
    if (down == keyDown[i] || now - keyChangedAt[i] < DEBOUNCE_MS) continue;
    keyDown[i] = down;
    keyChangedAt[i] = now;
    if (down) {
      presses[i]++;
      Serial.println("K");
      if (!lit) wake();
    }
  }
}

// ---------- the OLED ----------
// A reset in the middle of a transfer can leave the OLED holding SDA low. Nine clocks and a
// stop let it finish and let go.
void freeBus() {
  Wire.end();
  pinMode(I2C_SDA, INPUT_PULLUP);
  pinMode(I2C_SCL, OUTPUT_OPEN_DRAIN);
  digitalWrite(I2C_SCL, HIGH);
  for (int i = 0; i < 9 && digitalRead(I2C_SDA) == LOW; i++) {
    digitalWrite(I2C_SCL, LOW);  delayMicroseconds(10);
    digitalWrite(I2C_SCL, HIGH); delayMicroseconds(10);
  }
  pinMode(I2C_SDA, OUTPUT_OPEN_DRAIN);              // stop: SDA rises while SCL is high
  digitalWrite(I2C_SDA, LOW);  delayMicroseconds(10);
  digitalWrite(I2C_SDA, HIGH); delayMicroseconds(10);
  Wire.begin(I2C_SDA, I2C_SCL, I2C_HZ);
}

void startOled() {
  oledOk = false;
  freeBus();
  const uint8_t addrs[2] = {0x3C, 0x3D};
  for (uint8_t a : addrs) {
    Wire.beginTransmission(a);
    if (Wire.endTransmission() == 0 && oled.begin(a, true)) {
      oledAddr = a;
      oledOk = true;
      break;
    }
  }
  if (!oledOk) return;
  oled.setRotation(rotation == 2 ? (ROTATION_NORMAL + 2) % 4 : ROTATION_NORMAL);
  oled.clearDisplay();
  oled.display();
  memset(shown, 0, sizeof(shown));
  allStale = true;
}

void light(bool on) {
  lit = on;
  if (oledOk) oled.oled_command(on ? SH110X_DISPLAYON : SH110X_DISPLAYOFF);
  digitalWrite(LED, LOW);
}

void wake() {
  heardAt = millis();
  light(true);
}

// Copies the pixels that changed into the library's buffer; it then sends only the pages
// (8-row strips) and columns those pixels are in.
void show() {
  if (!oledOk) return;
  bool any = false;
  for (int y = 0; y < pp::H; y++)
    for (int x = 0; x < pp::W; x++) {
      int i = y * pp::W + x;
      if (!allStale && frame[i] == shown[i]) continue;
      oled.drawPixel(x, y, frame[i] ? SH110X_WHITE : SH110X_BLACK);
      any = true;
    }
  if (any) oled.display();
  memcpy(shown, frame, sizeof(shown));
  allStale = false;
}

// ---------- kept across restarts ----------
void remember() {
  kept.begin("burnbot", false);
  kept.putUChar("rotation", rotation);
  kept.putUChar("knock", sensitivity);
  kept.end();
}

void recall() {
  kept.begin("burnbot", true);
  rotation = kept.getUChar("rotation", 0) == 2 ? 2 : 0;
  sensitivity = kept.getUChar("knock", 1);
  if (sensitivity > 2) sensitivity = 1;
  kept.end();
}

// ---------- the Mac's lines ----------
void status() {
  if (oledOk) Serial.printf("display: SH1107 at 0x%02X, ", oledAddr);
  else {
    Serial.print("display: not found on SDA 15 / SCL 4 (SDA reads ");
    Serial.print(digitalRead(I2C_SDA) ? "high" : "LOW");
    Serial.print(", SCL ");
    Serial.print(digitalRead(I2C_SCL) ? "high" : "LOW");
    Serial.print("; I2C answers:");
    int found = 0;
    for (uint8_t a = 1; a < 127; a++) {
      Wire.beginTransmission(a);
      if (Wire.endTransmission() == 0) { Serial.printf(" 0x%02X", a); found++; }
    }
    if (!found) Serial.print(" none");
    Serial.print("), ");
  }
  Serial.print("keys:");
  for (int i = 0; i < 6; i++) Serial.printf(" %s=%s(%lu)", KEY_NAMES[i], keyDown[i] ? "down" : "up", (unsigned long)presses[i]);
  Serial.println();
}

void handle(char *text) {
  if (!text[0]) return;
  if (text[0] == 'V') { Serial.println("BURNBOT 3"); return; }
  if (text[0] == 'P') { Serial.println("OK"); return; }
  if (!strcmp(text, "s")) { status(); return; }
  if (text[0] == 'R') { startOled(); if (!lit) light(false); Serial.println("OK"); return; }
  if (text[0] == 'O' && (text[1] == '0' || text[1] == '2')) {
    uint8_t asked = text[1] - '0';
    if (asked != rotation) {
      rotation = asked;
      remember();
      startOled();
    }
    Serial.println("OK");
    return;
  }
  if (text[0] == 'S' && text[1] >= '0' && text[1] <= '2') {
    uint8_t asked = text[1] - '0';
    if (asked != sensitivity) {
      sensitivity = asked;
      remember();
    }
    Serial.println("OK");
    return;
  }
  if (text[0] == 'Q') {
    Serial.printf("Q|o=%d|s=%d|w=%d|k=1|n=%d\n", rotation, (int)state.look, waiting ? 1 : 0, sensitivity);
    return;
  }
  if (text[0] == 'M') {
    bb::Moment said;
    if (!bb::parseMoment(text, said)) { Serial.println("ERR"); return; }
    moment = said;
    Serial.println("OK");
    return;
  }
  bb::State next;
  if (!bb::parse(text, next)) { Serial.println("ERR"); return; }
  state = next;
  heardAt = millis();
  waiting = false;
  if (!lit) light(true);
  digitalWrite(LED, HIGH);
  blinkAt = heardAt;
  Serial.println("OK");
}

void setup() {
  Serial.setRxBufferSize(1024);
  Serial.begin(115200);
  pinMode(LED, OUTPUT);
  startKeys();
  recall();
  Wire.begin(I2C_SDA, I2C_SCL, I2C_HZ);
  delay(250);
  startOled();
  light(true);
  // Only seen with board.sh listen --reset; nothing here looks like an answer to the Mac.
  status();
}

void loop() {
  while (Serial.available()) {
    char c = (char)Serial.read();
    if (c == '\n' || c == '\r') {
      line[lineLength] = 0;
      handle(line);
      lineLength = 0;
    } else if (lineLength < sizeof(line) - 1) {
      line[lineLength++] = c;
    }
  }

  uint32_t now = millis();
  checkKeys(now);
  static uint32_t retryAt = 0;                  // a loose or slow screen: keep asking for it
  if (!oledOk && now - retryAt > 2000) {
    retryAt = now;
    startOled();
    if (oledOk) { light(lit); Serial.println("display: found it"); }
  }
  if (blinkAt && now - blinkAt > 40) {
    digitalWrite(LED, LOW);
    blinkAt = 0;
  }
  if (!waiting && now - heardAt > QUIET_MS) {   // the Mac went quiet (asleep, or Burnbot quit)
    waiting = true;
    moment = bb::Moment();
  }
  if (lit && waiting && now - heardAt > DARK_MS) light(false);

  if (lit && now - frameAt >= FRAME_MS) {
    float dt = frameAt ? (now - frameAt) / 1000.0f : FRAME_MS / 1000.0f;
    if (dt > 0.25f) dt = 0.25f;
    frameAt = now;
    scene.step(dt, state, waiting);
    scene.draw({art, pp::AW, pp::AH}, state, waiting);
    pp::draw(frame, art, state, waiting, moment, scene.cx);
    show();
  }
  delay(1);
}
