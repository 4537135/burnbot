// The display on an ESP32: a 2.4" or 2.8" "TFT LCD Shield" made for the Arduino
// UNO. Its ILI9341 takes the picture on eight data wires at once (LCD_D0..D7)
// with a write strobe (LCD_WR), not on one wire as the XIAO's display does.
// Adafruit's driver cannot do that on an ESP32, so this does, with the few calls
// burnbot_screen makes (named as Adafruit's are): begin, setRotation,
// startWrite/endWrite, setAddrWindow, writePixels. Plus fill, chip and problem.
//
// The shield's 5V pin wants 5 volts (the ESP32's 5V or VIN pin): it makes its own
// 3.3 V for the display, and on 3.3 V that comes out too low and the screen stays white.
#pragma once
#include <Arduino.h>
#include <soc/gpio_reg.h>

struct ShieldPins {
  int8_t d[8];                 // LCD_D0 .. LCD_D7
  int8_t wr, rs, cs, rst, rd;  // -1 for cs, rst or rd: not wired (LCD_CS on GND,
                               // LCD_RST and LCD_RD on 3V3)
};

class Parallel8 {
 public:
  explicit Parallel8(const ShieldPins &pins) : p(pins) {}

  // "" when the pins are usable; otherwise which one is not, and why.
  const char *problem() const { return trouble; }

  bool uses(int8_t gpio) const {
    for (int8_t g : p.d) if (g == gpio) return true;
    return gpio == p.wr || gpio == p.rs || gpio == p.cs || gpio == p.rst || gpio == p.rd;
  }

  void begin(uint32_t = 0) {
    ready = false;
    if (!pinsUsable()) return;
    makeTables();
    for (int8_t g : p.d) output(g, LOW);
    output(p.wr, HIGH);
    output(p.rs, HIGH);
    output(p.cs, HIGH);
    output(p.rd, HIGH);                // high: never asking the display to talk back
    if (p.rst >= 0) {
      output(p.rst, LOW);
      delay(20);
      digitalWrite(p.rst, HIGH);
      delay(150);
    }
    ready = true;
    startWrite();
    command(0x01);                     // and a reset in words, for a shield whose LCD_RST is on 3V3
    delay(150);
    for (const uint8_t *c = INIT; *c;) {
      command(*c++);
      uint8_t n = *c++;
      for (uint8_t i = 0; i < (n & 0x7F); i++) put(*c++);
      if (n & 0x80) delay(150);
    }
    endWrite();
  }

  void setRotation(uint8_t r) {
    // As Adafruit's: 0 portrait, 1 landscape, 2 portrait upside down, 3 landscape the other way.
    static const uint8_t MADCTL[4] = {0x48, 0x28, 0x88, 0xE8};
    if (!ready) return;
    startWrite();
    command(0x36);
    put(MADCTL[r & 3]);
    endWrite();
  }

  void startWrite() { if (ready && p.cs >= 0) digitalWrite(p.cs, LOW); }
  void endWrite() { if (ready && p.cs >= 0) digitalWrite(p.cs, HIGH); }

  void setAddrWindow(uint16_t x, uint16_t y, uint16_t w, uint16_t h) {
    if (!ready || !w || !h) return;
    uint16_t x1 = x + w - 1, y1 = y + h - 1;
    command(0x2A); put(x >> 8); put(x); put(x1 >> 8); put(x1);
    command(0x2B); put(y >> 8); put(y); put(y1 >> 8); put(y1);
    command(0x2C);
  }

  void writePixels(const uint16_t *colors, uint32_t n) {
    if (!ready) return;
    while (n--) {
      uint16_t c = *colors++;
      put(c >> 8);
      put(c & 0xFF);
    }
  }

  void fill(uint16_t color, uint16_t w, uint16_t h) {
    if (!ready) return;
    startWrite();
    setAddrWindow(0, 0, w, h);
    for (uint32_t n = (uint32_t)w * h; n--;) {
      put(color >> 8);
      put(color & 0xFF);
    }
    endWrite();
  }

  // What the display chip says it is, from its ID4 (0xD3): 0x9341 for an ILI9341.
  // 0 when it cannot say: LCD_RD not wired, or a shield whose buffer chips only
  // pass data towards the display (then it does not know, and that is all right).
  uint16_t chip() {
    if (!ready || p.rd < 0) return 0;
    uint8_t got[4] = {0, 0, 0, 0};
    startWrite();
    command(0xD3);
    for (int8_t g : p.d) pinMode(g, INPUT);
    for (uint8_t &b : got) {
      digitalWrite(p.rd, LOW);
      delayMicroseconds(1);
      for (int i = 0; i < 8; i++) b |= digitalRead(p.d[i]) << i;
      digitalWrite(p.rd, HIGH);
      delayMicroseconds(1);
    }
    for (int8_t g : p.d) pinMode(g, OUTPUT);
    endWrite();
    uint16_t id = got[2] << 8 | got[3];
    return id == 0xFFFF ? 0 : id;
  }

 private:
  // The ILI9341's start: Adafruit's list. Each command, how many bytes follow
  // (+0x80: then wait 150 ms), the bytes. 0 ends it.
  static constexpr uint8_t INIT[] = {
    0xEF, 3, 0x03, 0x80, 0x02,
    0xCF, 3, 0x00, 0xC1, 0x30,
    0xED, 4, 0x64, 0x03, 0x12, 0x81,
    0xE8, 3, 0x85, 0x00, 0x78,
    0xCB, 5, 0x39, 0x2C, 0x00, 0x34, 0x02,
    0xF7, 1, 0x20,
    0xEA, 2, 0x00, 0x00,
    0xC0, 1, 0x23,                     // power control
    0xC1, 1, 0x10,
    0xC5, 2, 0x3E, 0x28,               // VCOM
    0xC7, 1, 0x86,
    0x36, 1, 0x48,                     // which way round
    0x37, 1, 0x00,                     // no scrolling
    0x3A, 1, 0x55,                     // 16 bits a pixel
    0xB1, 2, 0x00, 0x18,
    0xB6, 3, 0x08, 0x82, 0x27,
    0xF2, 1, 0x00,
    0x26, 1, 0x01,                     // gamma
    0xE0, 15, 0x0F, 0x31, 0x2B, 0x0C, 0x0E, 0x08, 0x4E, 0xF1, 0x37, 0x07, 0x10, 0x03, 0x0E, 0x09, 0x00,
    0xE1, 15, 0x00, 0x0E, 0x14, 0x03, 0x11, 0x07, 0x31, 0xC1, 0x48, 0x08, 0x0F, 0x0C, 0x31, 0x36, 0x0F,
    0x11, 0x80,                        // awake
    0x29, 0x80,                        // display on
    0x00,
  };

  // The pins an ESP32 (WROOM) can drive: 0, 2, 4, 5, 12-19, 21-23, 25-27, 32, 33.
  static constexpr uint64_t DRIVABLE = 0x30EEFF035ULL;

  const ShieldPins p;
  bool ready = false;
  char trouble[96] = "";
  bool oneBank = true;                 // data and LCD_WR all on GPIO 0-31: three writes a byte
  uint32_t setLo[256], clearLo = 0, wrMask = 0, wrSet = 0, wrClear = 0;
  uint8_t setHi[256], clearHi = 0;

  bool pinsUsable() {
    static const char *NAMES[] = {"LCD_D0", "LCD_D1", "LCD_D2", "LCD_D3", "LCD_D4", "LCD_D5",
                                  "LCD_D6", "LCD_D7", "LCD_WR", "LCD_RS", "LCD_CS", "LCD_RST", "LCD_RD"};
    int8_t all[13];
    for (int i = 0; i < 8; i++) all[i] = p.d[i];
    all[8] = p.wr; all[9] = p.rs; all[10] = p.cs; all[11] = p.rst; all[12] = p.rd;
    for (int i = 0; i < 13; i++) {
      int8_t g = all[i];
      if (g < 0 && i >= 10) continue;  // CS, RST and RD may be left off
      const char *why = nullptr;
      if (g == 1 || g == 3) why = "carries the USB serial line";
      else if (g >= 6 && g <= 11) why = "belongs to the flash chip";
      else if (g >= 34 && g <= 39) why = "can only listen, not drive";
      else if (g < 0 || g > 39 || !(DRIVABLE >> g & 1)) why = "is not a pin this board can drive";
      for (int k = 0; k < i && !why; k++) if (all[k] == g) why = "is used twice";
      if (why) {
        snprintf(trouble, sizeof trouble, "%s on GPIO %d: that pin %s", NAMES[i], g, why);
        return false;
      }
    }
    trouble[0] = 0;
    return true;
  }

  void makeTables() {
    clearLo = clearHi = 0;
    for (int8_t g : p.d) {
      if (g < 32) clearLo |= 1UL << g;
      else clearHi |= 1 << (g - 32);
    }
    for (int b = 0; b < 256; b++) {
      setLo[b] = 0;
      setHi[b] = 0;
      for (int i = 0; i < 8; i++) {
        if (!(b >> i & 1)) continue;
        if (p.d[i] < 32) setLo[b] |= 1UL << p.d[i];
        else setHi[b] |= 1 << (p.d[i] - 32);
      }
    }
    bool wrLow = p.wr < 32;
    wrMask = 1UL << (wrLow ? p.wr : p.wr - 32);
    wrSet = wrLow ? GPIO_OUT_W1TS_REG : GPIO_OUT1_W1TS_REG;
    wrClear = wrLow ? GPIO_OUT_W1TC_REG : GPIO_OUT1_W1TC_REG;
    oneBank = wrLow && clearHi == 0;
  }

  static void output(int8_t g, uint8_t level) {
    if (g < 0) return;
    digitalWrite(g, level);
    pinMode(g, OUTPUT);
    digitalWrite(g, level);
  }

  // One byte onto the data wires; the display takes it as LCD_WR goes back up.
  inline void put(uint8_t b) {
    if (oneBank) {
      REG_WRITE(GPIO_OUT_W1TC_REG, clearLo | wrMask);
      REG_WRITE(GPIO_OUT_W1TS_REG, setLo[b]);
      REG_WRITE(GPIO_OUT_W1TS_REG, wrMask);
    } else {
      REG_WRITE(GPIO_OUT_W1TC_REG, clearLo);
      REG_WRITE(GPIO_OUT1_W1TC_REG, clearHi);
      REG_WRITE(GPIO_OUT_W1TS_REG, setLo[b]);
      REG_WRITE(GPIO_OUT1_W1TS_REG, setHi[b]);
      REG_WRITE(wrClear, wrMask);
      REG_WRITE(wrSet, wrMask);
    }
  }

  void command(uint8_t c) {
    digitalWrite(p.rs, LOW);
    put(c);
    digitalWrite(p.rs, HIGH);
  }
};
