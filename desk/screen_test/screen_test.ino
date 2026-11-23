// Screen test: checks the display's wires and chip without Burnbot.
//
//   Upload:          desk/board.sh upload desk/screen_test
//   See its notes:   desk/board.sh listen --reset
//   Burnbot back:    desk/board.sh screen
//
// Every 20 seconds it goes round these steps. Each test draws its number as bars:
//
//   dark for 2 s   the backlight wire (BL) works
//   1 bar          Burnbot's own display driver (ILI9341), slow
//   2 bars         the same at Burnbot's full speed (16 MHz)
//   3 bars         any 16-bit display chip (ST7789, ST7796…), slow
//   4 bars         an 18-bit display chip (ILI9488, the 3.5" ones), slow
//
// Colours can come out swapped or inverted on some screens; count the bars.
// If the display's SDO pin is wired (GPIO 19 / D9), it also reads the chip's ID.

#include <SPI.h>
#include <Adafruit_GFX.h>
#include <Adafruit_ILI9341.h>

#if defined(ARDUINO_ARCH_ESP32)
#include <driver/gpio.h>
const int CS = 5, DC = 27, RST = 33, BL = 32, P_DIN = 23, P_CLK = 18, P_SDO = 19;
const char *WIRE[] = {"CS  -> GPIO 5 ", "DC  -> GPIO 27", "RST -> GPIO 33", "BL  -> GPIO 32",
                      "DIN -> GPIO 23", "CLK -> GPIO 18", "SDO -> GPIO 19"};
#else
const int CS = D0, DC = D1, RST = D2, BL = D6, P_DIN = D10, P_CLK = D8, P_SDO = D9;
const char *WIRE[] = {"CS  -> D0 ", "DC  -> D1 ", "RST -> D2 ", "BL  -> D6 ",
                      "DIN -> D10", "CLK -> D8 ", "SDO -> D9 "};
#endif

const uint32_t SLOW = 2000000, FAST = 16000000;

Adafruit_ILI9341 tft(CS, DC, RST);
uint32_t hz = SLOW;

// ---------- the wires, before SPI takes them ----------
// A display input reads "free" whether or not a wire reaches it, so this is a hint:
// it can show a wire that lands on 3V3 or GND, or a pin pulled up on the display.
void probeWires() {
  const int pins[] = {CS, DC, RST, BL, P_DIN, P_CLK, P_SDO};
  Serial.println("Wires (a hint only):");
  for (int i = 0; i < 7; i++) {
    pinMode(pins[i], INPUT_PULLDOWN);
    delay(5);
    int down = digitalRead(pins[i]);
    pinMode(pins[i], INPUT_PULLUP);
    delay(5);
    int up = digitalRead(pins[i]);
    const char *what = down && up    ? "held HIGH (on 3V3, or pulled up on the display)"
                       : !down && !up ? "held LOW (on GND, or a backlight transistor)"
                       : !down && up  ? "free (unwired, or a plain input)"
                                      : "odd";
    Serial.print("  ");
    Serial.print(WIRE[i]);
    Serial.print("  ");
    Serial.println(what);
  }
}

// ---------- talking to the chip directly ----------
void command(uint8_t c, const uint8_t *data = nullptr, int n = 0) {
  SPI.beginTransaction(SPISettings(hz, MSBFIRST, SPI_MODE0));
  digitalWrite(CS, LOW);
  digitalWrite(DC, LOW);
  SPI.transfer(c);
  digitalWrite(DC, HIGH);
  for (int i = 0; i < n; i++) SPI.transfer(data[i]);
  digitalWrite(CS, HIGH);
  SPI.endTransaction();
}

// Prints the raw bytes the chip sends back for a read command (needs SDO wired).
void readBack(const char *label, uint8_t c, int n) {
  SPI.beginTransaction(SPISettings(1000000, MSBFIRST, SPI_MODE0));
  digitalWrite(CS, LOW);
  digitalWrite(DC, LOW);
  SPI.transfer(c);
  digitalWrite(DC, HIGH);
  Serial.print("    ");
  Serial.print(label);
  for (int i = 0; i < n; i++) {
    uint8_t b = SPI.transfer(0);
    Serial.print(b < 16 ? " 0" : " ");
    Serial.print(b, HEX);
  }
  Serial.println();
  digitalWrite(CS, HIGH);
  SPI.endTransaction();
}

void readChip(const char *when) {
  Serial.print("  chip reads, ");
  Serial.println(when);
  readBack("ID     (04):", 0x04, 4);
  readBack("power  (0A):", 0x0A, 2);
  readBack("ILI ID (D3):", 0xD3, 4);
}

void hardReset() {
  digitalWrite(RST, LOW);
  delay(20);
  digitalWrite(RST, HIGH);
  delay(150);
}

// The few commands every MIPI display chip shares: reset, wake, pixel size, on.
void plainSetup(uint8_t pixelFormat) {
  hardReset();
  command(0x01);  // software reset
  delay(150);
  command(0x11);  // wake up
  delay(150);
  command(0x3A, &pixelFormat, 1);
  uint8_t madctl = 0x08;
  command(0x36, &madctl, 1);
  command(0x13);  // normal mode
  command(0x29);  // display on
  delay(20);
}

// Fills w x h with `bars` coloured bars on black, a row at a time.
void plainBars(int w, int h, int bars, int bytesPerPixel, const uint8_t *colour) {
  uint8_t cols[4] = {0, 0, (uint8_t)((w - 1) >> 8), (uint8_t)((w - 1) & 0xFF)};
  uint8_t rows[4] = {0, 0, (uint8_t)((h - 1) >> 8), (uint8_t)((h - 1) & 0xFF)};
  command(0x2A, cols, 4);
  command(0x2B, rows, 4);
  static const uint8_t black[3] = {0, 0, 0};
  SPI.beginTransaction(SPISettings(hz, MSBFIRST, SPI_MODE0));
  digitalWrite(CS, LOW);
  digitalWrite(DC, LOW);
  SPI.transfer(0x2C);  // write pixels
  digitalWrite(DC, HIGH);
  for (int y = 0; y < h; y++) {
    bool on = (y * (2 * bars + 1) / h) % 2 == 1;
    const uint8_t *px = on ? colour : black;
    for (int x = 0; x < w; x++)
      for (int b = 0; b < bytesPerPixel; b++) SPI.transfer(px[b]);
  }
  digitalWrite(CS, HIGH);
  SPI.endTransaction();
}

// ---------- the tests ----------
void driverBars(uint32_t speed, int bars, uint16_t colour) {
  tft.begin(speed);
  tft.setRotation(0);
  tft.fillScreen(ILI9341_BLACK);
  int band = tft.height() / (2 * bars + 1);
  for (int i = 0; i < bars; i++) tft.fillRect(0, band * (2 * i + 1), tft.width(), band, colour);
}

void step(const char *what) {
  Serial.print("[");
  Serial.print(millis() / 1000);
  Serial.print("s] ");
  Serial.println(what);
}

void setup() {
  Serial.begin(115200);
  delay(300);
  Serial.println();
  Serial.println("SCREEN TEST");
  probeWires();

  pinMode(CS, OUTPUT);
  digitalWrite(CS, HIGH);
  pinMode(DC, OUTPUT);
  pinMode(RST, OUTPUT);
  digitalWrite(RST, HIGH);
  pinMode(BL, OUTPUT);
  digitalWrite(BL, HIGH);
#if defined(ARDUINO_ARCH_ESP32)
  SPI.begin(P_CLK, P_SDO, P_DIN);
  gpio_pulldown_en((gpio_num_t)P_SDO);  // an unwired SDO then reads 00, not noise
#else
  SPI.begin();
#endif

  hz = SLOW;
  hardReset();
  readChip("just after reset");
}

void loop() {
  step("dark for 2 s (backlight off)");
  digitalWrite(BL, LOW);
  delay(2000);
  digitalWrite(BL, HIGH);

  step("1 bar: Burnbot's driver (ILI9341), 2 MHz, red");
  driverBars(SLOW, 1, ILI9341_RED);
  hz = SLOW;
  readChip("after Burnbot's driver set it up");
  delay(3000);

  step("2 bars: Burnbot's driver, 16 MHz, blue");
  driverBars(FAST, 2, ILI9341_BLUE);
  delay(3000);

  step("3 bars: any 16-bit chip (ST7789, ST7796...), 2 MHz, yellow");
  hz = SLOW;
  plainSetup(0x55);
  static const uint8_t yellow16[2] = {0xFF, 0xE0};
  plainBars(240, 320, 3, 2, yellow16);
  readChip("after the plain 16-bit setup");
  delay(3000);

  step("4 bars: 18-bit chip (ILI9488), 2 MHz, green");
  plainSetup(0x66);
  static const uint8_t green18[3] = {0x00, 0xFC, 0x00};
  plainBars(320, 480, 4, 3, green18);
  delay(3000);
}
