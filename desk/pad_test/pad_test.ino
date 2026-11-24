// Pad test: checks the Claude Pad (LCDwiki ES3C28P, ESP32-S3) screen and keys without Burnbot.
//
//   Upload:          desk/board.sh pad-test
//   See its notes:   desk/board.sh listen
//   Burnbot back:    desk/board.sh pad
//
// It draws colour bars and four key boxes along the bottom edge. A box lights while its key
// is down, and each press and release is printed over USB ("key 1 down", "key 1 up").
//
//   Screen  ILI9341V, SPI: CS 10, DC 46, SCK 12, MOSI 11, MISO 13, reset on EN, backlight 45 (high = on)
//   Keys    1 -> GPIO 2, 2 -> GPIO 3, 3 -> GPIO 14, 4 -> GPIO 21, each to GND (internal pull-ups)
//
// Source for the pins: lcdwiki.com/2.8inch_ESP32-S3_Display.

#include <SPI.h>
#include <Adafruit_GFX.h>
#include <Adafruit_ILI9341.h>

const int CS = 10, DC = 46, SCK_ = 12, MOSI_ = 11, MISO_ = 13, BL = 45, AMP_OFF = 1;
const int KEYS[4] = {2, 3, 14, 21};
const char *const NAMES[4] = {"KEY 1", "KEY 2", "KEY 3", "KEY 4"};

Adafruit_ILI9341 tft(&SPI, DC, CS, -1);
bool down[4];

void box(int i, bool on) {
  const int w = 320 / 4, y = 196, h = 44;
  uint16_t fill = on ? ILI9341_ORANGE : ILI9341_BLACK;
  tft.fillRect(i * w + 3, y, w - 6, h - 4, fill);
  tft.drawRect(i * w + 3, y, w - 6, h - 4, ILI9341_ORANGE);
  tft.setTextSize(2);
  tft.setTextColor(on ? ILI9341_BLACK : ILI9341_ORANGE);
  tft.setCursor(i * w + 11, y + 13);
  tft.print(NAMES[i]);
}

void setup() {
  Serial.begin(115200);
  pinMode(AMP_OFF, OUTPUT);
  digitalWrite(AMP_OFF, HIGH);              // speaker amplifier off: no hiss
  for (int i = 0; i < 4; i++) pinMode(KEYS[i], INPUT_PULLUP);
  pinMode(BL, OUTPUT);
  digitalWrite(BL, HIGH);

  SPI.begin(SCK_, MISO_, MOSI_, CS);
  tft.begin(40000000);
  tft.setRotation(1);                       // landscape, 320 x 240
  tft.invertDisplay(true);                  // this panel shows colours inverted otherwise
  tft.fillScreen(ILI9341_BLACK);

  const uint16_t bars[] = {ILI9341_RED, ILI9341_GREEN, ILI9341_BLUE, ILI9341_WHITE,
                           ILI9341_ORANGE, ILI9341_CYAN, ILI9341_MAGENTA, ILI9341_YELLOW};
  for (int i = 0; i < 8; i++) tft.fillRect(i * 40, 0, 40, 120, bars[i]);
  tft.setTextColor(ILI9341_WHITE);
  tft.setTextSize(2);
  tft.setCursor(10, 140);
  tft.print("Burnbot pad test");
  tft.setTextSize(1);
  tft.setCursor(10, 166);
  // No reading from the display: on this panel an ID query leaves it drawing every row along
  // its top edge until it is set up again.
  tft.print("pad test: press each key");
  for (int i = 0; i < 4; i++) box(i, false);
  Serial.println("pad test ready");
}

void loop() {
  for (int i = 0; i < 4; i++) {
    bool d = digitalRead(KEYS[i]) == LOW;
    if (d != down[i]) {
      delay(25);
      if ((digitalRead(KEYS[i]) == LOW) != d) continue;
      down[i] = d;
      box(i, d);
      Serial.printf("key %d %s\n", i + 1, d ? "down" : "up");
    }
  }
  static uint32_t last;
  if (millis() - last > 5000) { last = millis(); Serial.println("pad test ready"); }
  delay(5);
}
