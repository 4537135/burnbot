// Pad hardware test: checks the Claude Pad's touch, speaker, microphone and battery, without Burnbot.
//
//   Upload:          desk/board.sh pad-hw-test     (copies desk/pad_hw/*.h in)
//   Talk to it:      desk/board.sh listen --pad    (type the commands below)
//   Record to Mac:   desk/board.sh pad-rec x.wav 5 && afplay x.wav
//   Play from Mac:   desk/board.sh pad-play some.wav
//   Burnbot back:    desk/board.sh pad
//
// The screen shows a checklist that updates as you go. The keys, left to right:
//   1  a short tone         2  hold: record (A| lines) and show the level
//   3  touch mode on/off    4  read the battery
//
// Commands (one per line):
//   s                        status
//   scan | scan all          I2C devices on SDA 16 / SCL 15; "all" looks for 0x18 and 0x38 on other pins
//   id                       the codec's and the touch chip's ID bytes
//   touch [secs]             raw touch points: T rx ry -> sx sy (through the shipped calibration)
//   tone [hz] [secs] [vol]   a sine on the speaker (1000 Hz, 1 s, 30%)
//   vol N                    speaker volume 0..100        mg N   microphone gain 0..7
//   amp low|high|off         which level switches the amplifier on (or no amplifier pin)
//   mic [secs]               microphone levels per I2S slot, every 100 ms
//   slot L|R|mono            which slot the microphone is read from
//   rec [secs]               records and sends AS|, A| and AE| lines
//   loop [secs]              microphone straight to the speaker, quietly
//   bat                      battery millivolts
//   pins i2c SDA SCL | pins i2s MCLK BCLK WS DOUT DIN | pins amp N | pins touch RST INT
//   PL|seq|b64, PE, PX       sound from the Mac (what pad-play sends)
//
// Pins from LCDwiki's ES3C28P table; the scan and the "pins" commands are for when this unit differs.
#include <Adafruit_ILI9341.h>
#include <SPI.h>
#include <Wire.h>
#include "es8311.h"
#include "ft6336.h"
#include "padaudio.h"
#include "calib.h"

const int LCD_CS = 10, LCD_DC = 46, LCD_SCK = 12, LCD_MOSI = 11, LCD_MISO = 13, LCD_BL = 45;
const int KEYS[4] = {2, 3, 14, 21};
const int BAT = 9;

int sdaPin = 16, sclPin = 15;
Adafruit_ILI9341 tft(&SPI, LCD_DC, LCD_CS, -1);

bool codecOk = false, touchOk = false, audioOk = false;
uint16_t codecId = 0;
String audioWhy = "";
int volume = 60, gain = 6;
bool touchMode = false;
uint32_t touchUntil = 0, micUntil = 0, loopUntil = 0, recUntil = 0;
bool keyDown[4], wasDown[4];
uint32_t keyAt[4];
uint32_t recCount = 0;
char line[2100];
size_t lineLength = 0;

// ---------- screen ----------
void row(int i, const String &label, const String &value, uint16_t color) {
  int y = 34 + i * 22;
  tft.fillRect(0, y, 320, 20, ILI9341_BLACK);
  tft.setTextSize(2);
  tft.setTextColor(ILI9341_LIGHTGREY);
  tft.setCursor(8, y);
  tft.print(label);
  tft.setTextColor(color);
  tft.setCursor(104, y);
  tft.print(value);
}

int batteryMv() {
  uint32_t sum = 0;
  for (int i = 0; i < 16; i++) sum += analogReadMilliVolts(BAT);
  return (int)(sum / 16) * 2;   // a 1:2 divider
}

void drawChecklist() {
  tft.fillScreen(ILI9341_BLACK);
  tft.setTextSize(2);
  tft.setTextColor(ILI9341_ORANGE);
  tft.setCursor(8, 8);
  tft.print("PAD HARDWARE TEST");
  char s[40];
  snprintf(s, sizeof s, "%04X %s", codecId, codecOk ? "ok" : "no");
  row(0, "CODEC", s, codecOk && codecId == 0x8311 ? ILI9341_GREEN : ILI9341_RED);
  row(1, "TOUCH", touchOk ? ft::ids() : String("none"), touchOk ? ILI9341_GREEN : ILI9341_RED);
  row(2, "AUDIO", audioOk ? String("running") : audioWhy, audioOk ? ILI9341_GREEN : ILI9341_RED);
  snprintf(s, sizeof s, "%d mV", batteryMv());
  row(3, "BATT", s, ILI9341_WHITE);
  row(4, "MIC", "-", ILI9341_WHITE);
  row(5, "KEYS", "1 tone 2 rec 3 touch 4 bat", ILI9341_DARKGREY);
  for (int i = 0; i < 4; i++) tft.drawRect(i * 80 + 4, 212, 72, 24, ILI9341_DARKGREY);
}

void meter(int peak) {
  static uint32_t at = 0;
  if (millis() - at < 60) return;
  at = millis();
  int w = (int)(200L * min(peak, 32767) / 32767);
  int y = 34 + 4 * 22;
  tft.fillRect(104, y + 2, 200, 14, ILI9341_BLACK);
  tft.fillRect(104, y + 2, w, 14, au::recording ? ILI9341_RED : ILI9341_GREEN);
}

// ---------- parts ----------
void startBus() {
  Wire.end();
  Wire.begin(sdaPin, sclPin, 100000);
}

void startAll() {
  startBus();
  audioOk = au::begin(audioWhy);   // I2S first: the codec needs MCLK running
  delay(20);
  codecId = es::chipId();
  codecOk = codecId != 0 && es::begin(Wire, 0x18, volume, gain);
  touchOk = ft::begin(Wire, ft::resetPin, ft::intPin);
  Serial.printf("i2c %d/%d  codec %04X %s  touch %s  audio %s\n", sdaPin, sclPin, codecId,
                codecOk ? "ok" : "no", touchOk ? ft::ids().c_str() : "none", audioOk ? "ok" : audioWhy.c_str());
}

bool probe(uint8_t a) {
  Wire.beginTransmission(a);
  return Wire.endTransmission() == 0;
}

void scan() {
  Serial.printf("scan SDA %d SCL %d:", sdaPin, sclPin);
  int n = 0;
  for (uint8_t a = 1; a < 127; a++)
    if (probe(a)) { Serial.printf(" %02X", a); n++; }
  Serial.println(n ? "" : " nothing");
}

void scanAll() {
  const int P[] = {1, 4, 5, 6, 7, 8, 9, 15, 16, 17, 18, 38, 39, 40, 41, 42, 47, 48};
  const int n = sizeof P / sizeof P[0];
  Serial.println("looking for 0x18 (codec) and 0x38 (touch) on every pin pair…");
  au::end();
  audioOk = false;
  for (int i = 0; i < n; i++)
    for (int j = 0; j < n; j++) {
      if (i == j) continue;
      Wire.end();
      Wire.begin(P[i], P[j], 100000);
      bool c = probe(0x18), t = probe(0x38);
      if (c || t) Serial.printf("  SDA %d SCL %d:%s%s\n", P[i], P[j], c ? " 18" : "", t ? " 38" : "");
    }
  Serial.println("done; restarting with the current pins");
  startAll();
  drawChecklist();
}

void status() {
  Serial.printf("pad hw test: i2c %d/%d codec %04X %s, touch %s, audio %s, i2s mclk %d bclk %d ws %d dout %d din %d, "
                "amp %d (%s), vol %d, gain %d, slot %d, battery %d mV, read errors %lu\n",
                sdaPin, sclPin, codecId, codecOk ? "ok" : "no", touchOk ? ft::ids().c_str() : "none",
                audioOk ? "ok" : audioWhy.c_str(), au::pins.mclk, au::pins.bclk, au::pins.ws, au::pins.dout,
                au::pins.din, au::pins.amp, au::pins.ampOnLow ? "on when low" : "on when high", volume, gain,
                au::slot.load(), batteryMv(), (unsigned long)au::readErrors.load());
}

void startRec(uint32_t seconds) {
  au::startRecording(Serial, ++recCount);
  recUntil = millis() + seconds * 1000;
}

// ---------- commands ----------
int arg(const char *text, int which, int fallback) {
  const char *p = text;
  for (int i = 0; i <= which; i++) {
    p = strchr(p, ' ');
    if (!p) return fallback;
    while (*p == ' ') p++;
  }
  return *p ? atoi(p) : fallback;
}

void handle(char *text) {
  if (au::playLine(text, Serial)) return;
  if (!strcmp(text, "s") || !strcmp(text, "V")) { status(); return; }
  if (!strcmp(text, "scan")) { scan(); return; }
  if (!strcmp(text, "scan all")) { scanAll(); return; }
  if (!strcmp(text, "id")) {
    Serial.printf("codec FD %02X FE %02X FF %02X   touch A8/A3/A6 %s\n", es::r(0xFD) & 0xFF, es::r(0xFE) & 0xFF,
                  es::r(0xFF) & 0xFF, ft::ids().c_str());
    return;
  }
  if (!strncmp(text, "touch", 5)) { touchUntil = millis() + arg(text, 0, 20) * 1000UL; touchMode = true; return; }
  if (!strncmp(text, "tone", 4)) {
    au::tone(arg(text, 0, 1000), arg(text, 1, 1) * 1000, arg(text, 2, 30));
    Serial.println("tone");
    return;
  }
  if (!strncmp(text, "vol ", 4)) { volume = arg(text, 0, 60); es::volume(volume); Serial.println("OK"); return; }
  if (!strncmp(text, "mg ", 3)) { gain = arg(text, 0, 4); es::micGain(gain); Serial.println("OK"); return; }
  if (!strncmp(text, "amp ", 4)) {
    if (!strcmp(text + 4, "off")) au::pins.amp = -1;
    else au::pins.ampOnLow = strcmp(text + 4, "high") != 0;
    Serial.printf("amplifier on when %s\n", au::pins.ampOnLow ? "low" : "high");
    return;
  }
  if (!strncmp(text, "mic", 3)) { micUntil = millis() + arg(text, 0, 5) * 1000UL; return; }
  if (!strncmp(text, "slot ", 5)) {
    au::slot = text[5] == 'R' || text[5] == 'r' ? 1 : text[5] == 'L' || text[5] == 'l' ? 0 : 2;
    Serial.printf("microphone slot %d\n", au::slot.load());
    return;
  }
  if (!strncmp(text, "rec", 3)) { startRec(arg(text, 0, 5)); return; }
  if (!strncmp(text, "loop", 4)) {
    es::volume(30);
    au::loopback = true;
    loopUntil = millis() + arg(text, 0, 5) * 1000UL;
    return;
  }
  if (!strcmp(text, "bat")) { Serial.printf("battery %d mV\n", batteryMv()); return; }
  if (!strncmp(text, "pins i2c ", 9)) {
    sdaPin = arg(text, 1, 16);
    sclPin = arg(text, 2, 15);
    startAll();
    drawChecklist();
    return;
  }
  if (!strncmp(text, "pins i2s ", 9)) {
    au::pins.mclk = arg(text, 1, 4);
    au::pins.bclk = arg(text, 2, 5);
    au::pins.ws = arg(text, 3, 7);
    au::pins.dout = arg(text, 4, 8);
    au::pins.din = arg(text, 5, 6);
    startAll();
    drawChecklist();
    return;
  }
  if (!strncmp(text, "pins amp ", 9)) { au::pins.amp = arg(text, 1, 1); pinMode(au::pins.amp, OUTPUT); au::amp(false); return; }
  if (!strncmp(text, "pins touch ", 11)) {
    ft::resetPin = arg(text, 1, 18);
    ft::intPin = arg(text, 2, 17);
    touchOk = ft::begin(Wire, ft::resetPin, ft::intPin);
    Serial.printf("touch %s\n", touchOk ? ft::ids().c_str() : "none");
    return;
  }
  Serial.printf("unknown: %s\n", text);
}

// ---------- keys ----------
void checkKeys() {
  for (int i = 0; i < 4; i++) {
    bool d = digitalRead(KEYS[i]) == LOW;
    if (d == wasDown[i]) { keyAt[i] = millis(); continue; }
    if (millis() - keyAt[i] < 25) continue;
    wasDown[i] = d;
    tft.fillRect(i * 80 + 5, 213, 70, 22, d ? ILI9341_ORANGE : ILI9341_BLACK);
    if (!d) {
      if (i == 1) { au::stopRecording(Serial, "up"); recUntil = 0; }
      continue;
    }
    if (i == 0) au::tone(880, 300, 30);
    if (i == 1) startRec(45);
    if (i == 2) { touchMode = !touchMode; touchUntil = touchMode ? millis() + 600000UL : 0; Serial.printf("touch %s\n", touchMode ? "on" : "off"); }
    if (i == 3) {
      char s[20];
      snprintf(s, sizeof s, "%d mV", batteryMv());
      row(3, "BATT", s, ILI9341_WHITE);
      Serial.printf("battery %s\n", s);
    }
  }
}

void setup() {
  Serial.setRxBufferSize(16384);
  Serial.setTxBufferSize(16384);
  Serial.setTxTimeoutMs(0);
  Serial.begin(115200);
  for (int i = 0; i < 4; i++) { pinMode(KEYS[i], INPUT_PULLUP); wasDown[i] = false; keyAt[i] = millis(); }
  pinMode(LCD_BL, OUTPUT);
  digitalWrite(LCD_BL, HIGH);
  delay(300);                               // the screen shares the chip's reset line: let it wake
  SPI.begin(LCD_SCK, LCD_MISO, LCD_MOSI, LCD_CS);
  tft.begin(26000000);
  tft.setRotation(1);
  tft.invertDisplay(true);
  analogReadResolution(12);
  startAll();
  drawChecklist();
  status();
}

void loop() {
  while (Serial.available()) {
    char c = (char)Serial.read();
    if (c == '\n' || c == '\r') {
      line[lineLength] = 0;
      if (lineLength) handle(line);
      lineLength = 0;
    } else if (lineLength < sizeof line - 1) {
      line[lineLength++] = c;
    }
  }
  checkKeys();
  au::poll(Serial);
  uint32_t now = millis();

  if (au::recording) {
    au::sendMic(Serial, 4);
    meter(au::level);
    if (recUntil && now > recUntil) { au::stopRecording(Serial, "max"); recUntil = 0; }
  }
  if (micUntil) {
    static uint32_t at = 0;
    meter(au::level);
    if (now - at >= 100) {
      at = now;
      Serial.printf("mic L %5d  R %5d\n", au::peakL.load(), au::peakR.load());
    }
    if (now > micUntil) micUntil = 0;
  }
  if (loopUntil && now > loopUntil) { au::loopback = false; es::volume(volume); loopUntil = 0; Serial.println("loop off"); }

  if (touchMode && touchOk) {
    static bool was = false;
    static uint32_t at = 0;
    if (now - at >= 16) {
      at = now;
      int rx, ry, sx, sy;
      bool down;
      if (ft::read(rx, ry, down) && down) {
        cal::apply(cal::DEFAULT_AFFINE, rx, ry, sx, sy);
        tft.fillCircle(sx, sy, 3, ILI9341_CYAN);
        Serial.printf("T %d %d -> %d %d\n", rx, ry, sx, sy);
        was = true;
      } else if (was) {
        Serial.println("T up");
        was = false;
      }
    }
    if (touchUntil && now > touchUntil) { touchMode = false; Serial.println("touch off"); }
  }
}
