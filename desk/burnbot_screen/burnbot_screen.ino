// Burnbot desk screen: Seeed XIAO nRF52840 (Sense / Sense Plus) + 2.4" 240x320 ILI9341 on SPI.
//
// Wires:  VCC->3V3  GND->GND  DIN->D10  CLK->D8  CS->D0  DC->D1  RST->D2  BL->D6
// (the same wiring as the FOOOCUS desk screen, so nothing needs moving)
//
// The Mac sends one line a second saying which level you are on, and this
// draws it: the level and the token burn in words at the top, and below them
// the robot standing in its fire, with the level ladder beside it. Between
// lines the board keeps the fire, the robot and the falling tokens moving by
// itself. What everything looks like is in render.h, which the simulator on
// the Mac shares.
//
// Lines from the Mac (115200, each ends with a new line):
//   V        answers "BURNBOT 3" (2 could not feel a knock; 1 could not react or speak)
//   P        answers "OK"
//   R        starts the display again, answers "OK"
//   O0 / O2  which way up (pins at the bottom / at the top), answers "OK"; remembered
//   B|...    what to show (see render.h), answers "OK"
//   M|...    what the robot is saying, a speech bubble over the words at the top;
//            a bare "M|" takes it away (see render.h), answers "OK"
//   S0/S1/S2 how hard a knock has to be (light, medium, firm), answers "OK"; remembered
//   Q        answers what it is showing, for example "Q|o=0|s=4|w=0|k=1|n=1"
//            (k: it can feel knocks, n: the knock setting)
//
// And to the Mac: "K" when someone knocks twice on the case (the XIAO Sense's motion
// sensor feels it; on a board without one this never comes).
//
// With nothing from the Mac for 15 seconds the robot goes to sleep and the
// screen says it is waiting (anything the robot was saying goes); after ten minutes of that the light goes out
// until the Mac is back.
#include <SPI.h>
#include <Adafruit_GFX.h>
#include <Adafruit_ILI9341.h>
#include <Adafruit_LittleFS.h>
#include <InternalFileSystem.h>
#include <Wire.h>

#include "render.h"

using namespace Adafruit_LittleFS_Namespace;

#define TFT_CS D0
#define TFT_DC D1
#define TFT_RST D2
#define TFT_BL D6
#define SPI_HZ 16000000                    // what this display and these wires take

const int HUD_BAND = 36;                   // rows of words drawn and sent at a time
const int ART_BAND = 8;                    // rows of the scene sent at a time (24 on the display)
const uint32_t FRAME_MS = 66;              // about 15 pictures a second
const uint32_t QUIET_MS = 15000;           // nothing from the Mac this long: say so
const uint32_t DARK_MS = 600000;           // and this long: the light goes out
const char *KEPT = "/burnbot";             // remembered: which way up ('0' or '2'), then the knock setting
const char *KEPT_BEFORE = "/fooocus";      // where the FOOOCUS program kept the same thing

Adafruit_ILI9341 tft(TFT_CS, TFT_DC, TFT_RST);
static uint16_t band[bb::W * HUD_BAND];    // 17 KB, shared by the words and the scene
static uint16_t art[bb::AW * bb::AH];      // this picture of the scene
static uint16_t shown[bb::AW * bb::AH];    // what the display has now
static bb::Scene scene;

bb::State state;
bb::Moment moment;
uint32_t heardAt = 0;                      // when the last line came
uint32_t frameAt = 0;
bool waiting = true, lit = true;
bool wordsStale = true;                    // the words at the top need drawing
bool sceneStale = true;                    // the whole scene needs sending, not only what changed
uint8_t rotation = 0;
uint8_t sensitivity = 1;                   // 0 light, 1 medium, 2 firm
char line[200];
size_t lineLength = 0;

void light(bool on) {
  lit = on;
  digitalWrite(TFT_BL, on ? HIGH : LOW);
}

void startDisplay() {
  tft.begin(SPI_HZ);
  tft.setRotation(rotation);
  wordsStale = sceneStale = true;
}

// Written only when it changes (storage wears with every write).
void remember() {
  InternalFS.remove(KEPT);
  File file(InternalFS);
  if (file.open(KEPT, FILE_O_WRITE)) {
    char kept[2] = {(char)('0' + rotation), (char)('0' + sensitivity)};
    file.write(kept, 2);
    file.close();
  }
}

// Which way up: what this program remembered, or else what FOOOCUS did, so the
// picture is the right way round from the first moment.
void recall() {
  InternalFS.begin();
  const char *places[2] = {KEPT, KEPT_BEFORE};
  for (const char *place : places) {
    File file(InternalFS);
    if (!file.open(place, FILE_O_READ)) continue;
    char kept[2] = {'0', '1'};
    int got = file.read(kept, 2);
    file.close();
    if (got >= 1) {
      rotation = kept[0] == '2' ? 2 : 0;
      if (got == 2 && kept[1] >= '0' && kept[1] <= '2') sensitivity = kept[1] - '0';
      return;
    }
  }
}

// ---------- the knock: two taps on the case ----------
// The XIAO nRF52840 Sense has an LSM6DS3TR-C on its second I2C bus, powered from a pin of
// its own. Its tap detector does the work: this only switches it on and asks it, about 50
// times a second, whether it felt a double tap since the last time.
#if defined(PIN_LSM6DS3TR_C_POWER) && defined(WIRE_INTERFACES_COUNT) && WIRE_INTERFACES_COUNT > 1
const uint8_t IMU = 0x6A;
const uint8_t TAP_THS[3] = {0x08, 0x0C, 0x11};  // light, medium, firm (1 = 62.5 mg)
bool knocks = false;                            // the sensor answered
uint32_t askedAt = 0;

bool imuWrite(uint8_t reg, uint8_t value) {
  Wire1.beginTransmission(IMU);
  Wire1.write(reg);
  Wire1.write(value);
  return Wire1.endTransmission() == 0;
}

int imuRead(uint8_t reg) {
  Wire1.beginTransmission(IMU);
  Wire1.write(reg);
  if (Wire1.endTransmission(false) != 0) return -1;
  if (Wire1.requestFrom(IMU, (size_t)1) != 1) return -1;
  return Wire1.read();
}

void setKnock() {
  if (knocks) imuWrite(0x59, TAP_THS[sensitivity]);   // TAP_THS_6D
}

void startKnock() {
  pinMode(PIN_LSM6DS3TR_C_POWER, OUTPUT);
  digitalWrite(PIN_LSM6DS3TR_C_POWER, HIGH);
  delay(20);
  Wire1.begin();
  knocks = imuRead(0x0F) == 0x6A;               // WHO_AM_I of the LSM6DS3TR-C
  if (!knocks) return;
  imuWrite(0x10, 0x60);                         // CTRL1_XL: 416 Hz, 2 g
  imuWrite(0x58, 0x8F);                         // TAP_CFG: interrupts on, taps on x, y and z, latched
  setKnock();
  imuWrite(0x5A, 0x7F);                         // INT_DUR2: time between the taps, quiet, shock
  imuWrite(0x5B, 0x80);                         // WAKE_UP_THS: double taps as well as single
}

void checkKnock(uint32_t now) {
  if (!knocks || now - askedAt < 20) return;
  askedAt = now;
  int felt = imuRead(0x1C);                     // TAP_SRC; reading it clears the latch
  if (felt > 0 && (felt & 0x10)) Serial.println("K");   // DOUBLE_TAP
}
#else
const bool knocks = false;                      // a XIAO without the motion sensor
void setKnock() {}
void startKnock() {}
void checkKnock(uint32_t) {}
#endif

void send(int top, int rows) {
  tft.startWrite();
  tft.setAddrWindow(0, top, bb::W, rows);
  tft.writePixels(band, (uint32_t)bb::W * rows);
  tft.endWrite();
}

void showWords() {
  for (int y = 0; y < bb::HUD_H; y += HUD_BAND) {
    bb::Band b = {band, y, HUD_BAND};
    bb::drawHud(b, state, waiting, moment);
    send(y, HUD_BAND);
  }
}

// Sends the rows of the scene that differ from what the display has.
void showScene(bool all) {
  const size_t rowBytes = bb::AW * sizeof(uint16_t);
  int y = 0;
  while (y < bb::AH) {
    if (!all && !memcmp(art + y * bb::AW, shown + y * bb::AW, rowBytes)) {
      y++;
      continue;
    }
    int end = y;
    while (end < bb::AH && end - y < ART_BAND && (all || memcmp(art + end * bb::AW, shown + end * bb::AW, rowBytes))) end++;
    int top = bb::HUD_H + y * bb::PX;
    int rows = (end - y) * bb::PX;
    if (top + rows > bb::H) rows = bb::H - top;
    uint16_t *out = band;
    for (int r = 0; r < rows; r++) {
      const uint16_t *from = art + (y + r / bb::PX) * bb::AW;
      for (int x = 0; x < bb::AW; x++) {
        uint16_t c = from[x];
        *out++ = c;
        *out++ = c;
        *out++ = c;
      }
    }
    send(top, rows);
    y = end;
  }
  memcpy(shown, art, sizeof(art));
}

bool sameWords(const bb::State &a, const bb::State &b) {
  return a.look == b.look && a.intensity == b.intensity && !memcmp(a.cuts, b.cuts, sizeof(a.cuts))
      && !strcmp(a.name, b.name) && !strcmp(a.caption, b.caption) && !strcmp(a.rate, b.rate) && !strcmp(a.clock, b.clock);
}

void handle(char *text) {
  if (!text[0]) return;
  if (text[0] == 'V') { Serial.println("BURNBOT 3"); return; }
  if (text[0] == 'P') { Serial.println("OK"); return; }
  if (text[0] == 'R') { startDisplay(); Serial.println("OK"); return; }
  if (text[0] == 'O' && (text[1] == '0' || text[1] == '2')) {
    uint8_t asked = text[1] - '0';
    if (asked != rotation) {
      rotation = asked;
      remember();
      startDisplay();
    }
    Serial.println("OK");
    return;
  }
  if (text[0] == 'S' && text[1] >= '0' && text[1] <= '2') {
    uint8_t asked = text[1] - '0';
    if (asked != sensitivity) {
      sensitivity = asked;
      remember();
      setKnock();
    }
    Serial.println("OK");
    return;
  }
  if (text[0] == 'Q') {
    Serial.print("Q|o=");
    Serial.print(rotation);
    Serial.print("|s=");
    Serial.print(state.look);
    Serial.print("|w=");
    Serial.print(waiting ? 1 : 0);
    Serial.print("|k=");
    Serial.print(knocks ? 1 : 0);
    Serial.print("|n=");
    Serial.println(sensitivity);
    return;
  }
  if (text[0] == 'M') {
    bb::Moment said;
    if (!bb::parseMoment(text, said)) { Serial.println("ERR"); return; }
    if (!bb::sameMoment(moment, said)) wordsStale = true;
    moment = said;
    Serial.println("OK");
    return;
  }
  bb::State next;
  if (!bb::parse(text, next)) { Serial.println("ERR"); return; }
  if (waiting || !sameWords(state, next)) wordsStale = true;
  state = next;
  heardAt = millis();
  waiting = false;
  if (!lit) light(true);
  Serial.println("OK");
}

void setup() {
  Serial.begin(115200);
  pinMode(TFT_BL, OUTPUT);
  recall();
  light(true);
  startDisplay();
  startKnock();
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
  checkKnock(now);
  if (!waiting && now - heardAt > QUIET_MS) {   // the Mac went quiet (asleep, or Burnbot quit)
    waiting = true;
    wordsStale = true;
    moment = bb::Moment();
  }
  if (lit && waiting && now - heardAt > DARK_MS) light(false);

  if (wordsStale) {
    showWords();
    wordsStale = false;
  }
  if (lit && now - frameAt >= FRAME_MS) {
    float dt = frameAt ? (now - frameAt) / 1000.0f : 0.066f;
    frameAt = now;
    scene.step(dt, state, waiting);
    scene.draw(art, state, waiting);
    showScene(sceneStale);
    sceneStale = false;
  }
  delay(1);
}
