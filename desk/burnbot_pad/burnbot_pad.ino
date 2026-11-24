// Burnbot on the Claude Pad: an LCDwiki ES3C28P (ESP32-S3, 2.8" ILI9341V, 320 x 240 on its
// side) in a case with four keys under the screen.
//
//   Upload:  desk/board.sh pad   (it copies render.h and pad.h in from burnbot_screen)
//
// The Mac sends one line a second saying which level you are on, and this draws it (pad.h):
// the words at the top, the robot standing in its fire, and over each key what it does now.
// Between lines the board keeps the scene moving by itself. Only USB: the pad's Wi-Fi stays off.
//
// The keys, left to right, wired to GND (the kit's guide): 1 GPIO2, 2 GPIO3, 3 GPIO14, 4 GPIO21.
// The Mac decides what they do (DENY, TALK, SHOW, APPROVE while Claude waits for a yes) and
// says so in the B line, so the labels on the screen are always the Mac's.
//
// Lines from the Mac (115200, each ends with a new line):
//   V        answers "BURNBOT 4" (4: it has keys, and says which one; 3 felt knocks)
//   P        answers "OK"
//   R        starts the display again, answers "OK"
//   O0 / O2  answers "OK" (the keys are fixed under the screen, so it stays the right way up)
//   B|...    what to show (render.h, and pad.h for ky=, pr=, pp=), answers "OK"
//   M|...    what the robot is saying (render.h), answers "OK"
//   S0/S1/S2 answers "OK" (no knocks here)
//   L0..L9   how bright, 0 dim to 9 full, answers "OK"; remembered
//   Q        answers what it is showing, for example "Q|o=0|s=4|w=0|k=0|n=1|y=4"
//            (k=0: no knocks; y=4: four keys)
//   s        a line about the display and the keys, for desk/board.sh listen
//
// And to the Mac: "K1d" when key 1 goes down, "K1u" when it comes up (K2.. K4 the same).
//
// With nothing from the Mac for 15 seconds the robot goes to sleep and the screen says it is
// waiting; after ten minutes of that the light goes out until the Mac is back or a key is pressed.
#include <SPI.h>
#include <Adafruit_GFX.h>
#include <Adafruit_ILI9341.h>
#include <Preferences.h>

#include "pad.h"

// The board's wiring (lcdwiki.com, 2.8inch ESP32-S3 Display)
const int LCD_CS = 10, LCD_DC = 46, LCD_SCK = 12, LCD_MOSI = 11, LCD_MISO = 13, LCD_BL = 45;
const int AMP_OFF = 1;                      // the speaker's amplifier: high keeps it quiet
const int KEYS[4] = {2, 3, 14, 21};

const uint32_t SPI_HZ = 26000000;
const uint32_t QUIET_MS = 15000;
const uint32_t DARK_MS = 10UL * 60 * 1000;
const uint32_t FRAME_MS = 66;               // 15 frames a second
const uint32_t DEBOUNCE_MS = 25;
const int BAND = 16;                        // rows sent at a time

Adafruit_ILI9341 tft(&SPI, LCD_DC, LCD_CS, -1);
Preferences kept;

bb::State state;
bb::Moment moment;
pd::Pad pad;
bb::Scene scene(pd::AW, pd::AH, pd::LIFT);
static uint16_t art[pd::AW * pd::AH];
uint16_t *frame = nullptr, *shown = nullptr;   // a whole screen each, in PSRAM

bool waiting = true, lit = true, allStale = true;
uint8_t brightness = 9;
uint32_t heardAt = 0, frameAt = 0;

char line[512];
size_t lineLength = 0;

// ---------- the keys ----------
bool keyDown[4];
uint32_t keyChangedAt[4];
uint32_t presses[4];

void startKeys() {
  for (int i = 0; i < 4; i++) {
    pinMode(KEYS[i], INPUT_PULLUP);
    keyDown[i] = digitalRead(KEYS[i]) == LOW;
    keyChangedAt[i] = 0;
    presses[i] = 0;
  }
}

void wake();

// True when a key changed, so the frame shows it at once.
bool checkKeys(uint32_t now) {
  bool changed = false;
  for (int i = 0; i < 4; i++) {
    bool down = digitalRead(KEYS[i]) == LOW;
    if (down == keyDown[i] || now - keyChangedAt[i] < DEBOUNCE_MS) continue;
    keyDown[i] = down;
    keyChangedAt[i] = now;
    changed = true;
    if (down) presses[i]++;
    Serial.printf("K%d%c\n", i + 1, down ? 'd' : 'u');
    if (down && !lit) wake();
  }
  return changed;
}

// ---------- the display ----------
void light(bool on) {
  lit = on;
  analogWrite(LCD_BL, on ? 40 + brightness * 215 / 9 : 0);
}

void wake() {
  heardAt = millis();
  light(true);
}

void startDisplay() {
  SPI.begin(LCD_SCK, LCD_MISO, LCD_MOSI, LCD_CS);
  tft.begin(SPI_HZ);
  tft.setRotation(1);                       // on its side, the USB socket to the right
  tft.invertDisplay(true);                  // this ILI9341V panel shows colours inverted otherwise
  tft.fillScreen(ILI9341_BLACK);
  if (shown) memset(shown, 0, pd::W * pd::H * sizeof(uint16_t));
  allStale = true;
}

// Sends the rows that differ from what the display has, BAND rows at a time.
void show() {
  const size_t rowBytes = pd::W * sizeof(uint16_t);
  int y = 0;
  tft.startWrite();
  while (y < pd::H) {
    if (!allStale && !memcmp(frame + y * pd::W, shown + y * pd::W, rowBytes)) {
      y++;
      continue;
    }
    int end = y;
    while (end < pd::H && end - y < BAND && (allStale || memcmp(frame + end * pd::W, shown + end * pd::W, rowBytes))) end++;
    // Copied into a strip in the chip's own memory, high byte first, and sent as plain bytes.
    static uint16_t strip[pd::W * BAND];
    const uint32_t n = (uint32_t)pd::W * (end - y);
    const uint16_t *from = frame + y * pd::W;
    for (uint32_t i = 0; i < n; i++) strip[i] = (uint16_t)((from[i] << 8) | (from[i] >> 8));
    tft.setAddrWindow(0, y, pd::W, end - y);
    tft.writePixels(strip, n, true, true);   // big-endian already: goes out through writeBytes
    memcpy(shown + y * pd::W, frame + y * pd::W, rowBytes * (end - y));
    y = end;
  }
  tft.endWrite();
  allStale = false;
}

// ---------- kept across restarts ----------
void remember() {
  kept.begin("burnbot", false);
  kept.putUChar("bright", brightness);
  kept.end();
}

void recall() {
  kept.begin("burnbot", true);
  brightness = kept.getUChar("bright", 9);
  if (brightness > 9) brightness = 9;
  kept.end();
}

// ---------- the Mac's lines ----------
void status() {
  // No reading from the display here: its ID query (command 0xD9) leaves this panel drawing
  // every row along its top edge until it is set up again.
  Serial.printf("display: ILI9341, psram %u, keys:", (unsigned)ESP.getPsramSize());
  for (int i = 0; i < 4; i++) Serial.printf(" %d=%s(%lu)", i + 1, keyDown[i] ? "down" : "up", (unsigned long)presses[i]);
  Serial.println();
}

void handle(char *text) {
  if (!text[0]) return;
  if (text[0] == 'V') { Serial.println("BURNBOT 4"); return; }
  if (text[0] == 'P') { Serial.println("OK"); return; }
  if (!strcmp(text, "s")) { status(); return; }
  if (text[0] == 'R') { startDisplay(); light(lit); Serial.println("OK"); return; }
  if ((text[0] == 'O' && (text[1] == '0' || text[1] == '2')) || (text[0] == 'S' && text[1] >= '0' && text[1] <= '2')) {
    Serial.println("OK");
    return;
  }
  if (text[0] == 'L' && text[1] >= '0' && text[1] <= '9') {
    brightness = text[1] - '0';
    remember();
    if (lit) light(true);
    Serial.println("OK");
    return;
  }
  if (text[0] == 'Q') {
    Serial.printf("Q|o=0|s=%d|w=%d|k=0|n=1|y=4\n", (int)state.look, waiting ? 1 : 0);
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
  pd::Pad keys;
  if (!bb::parse(text, next) || !pd::parsePad(text, keys)) { Serial.println("ERR"); return; }
  state = next;
  pad = keys;
  heardAt = millis();
  waiting = false;
  if (!lit) light(true);
  Serial.println("OK");
}

void setup() {
  Serial.setRxBufferSize(2048);
  Serial.setTxTimeoutMs(0);                 // with nobody listening, drop what it says rather than wait
  Serial.begin(115200);
  pinMode(AMP_OFF, OUTPUT);
  digitalWrite(AMP_OFF, HIGH);
  pinMode(LCD_BL, OUTPUT);
  startKeys();
  recall();
  frame = (uint16_t *)ps_malloc(pd::W * pd::H * sizeof(uint16_t));
  shown = (uint16_t *)ps_malloc(pd::W * pd::H * sizeof(uint16_t));
  if (!frame || !shown) {                   // no PSRAM: should not happen on this board
    frame = (uint16_t *)malloc(pd::W * pd::H * sizeof(uint16_t));
    shown = (uint16_t *)malloc(pd::W * pd::H * sizeof(uint16_t));
  }
  delay(300);                               // the screen shares the chip's reset line: let it wake
  startDisplay();
  light(true);
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
  bool pressed = checkKeys(now);
  if (!waiting && now - heardAt > QUIET_MS) {   // the Mac went quiet (asleep, or Burnbot quit)
    waiting = true;
    moment = bb::Moment();
    pad = pd::Pad();
  }
  if (lit && waiting && now - heardAt > DARK_MS) light(false);

  if (lit && frame && shown && (pressed || now - frameAt >= FRAME_MS)) {
    float dt = frameAt ? (now - frameAt) / 1000.0f : FRAME_MS / 1000.0f;
    if (dt > 0.25f) dt = 0.25f;
    frameAt = now;
    scene.step(dt, state, waiting);
    scene.draw({art, pd::AW, pd::AH}, state, waiting);
    pd::draw(frame, art, state, waiting, moment, pad, scene.cx, keyDown);
    show();
  }
  delay(1);
}
