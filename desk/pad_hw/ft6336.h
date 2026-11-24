// FT6336: the Claude Pad's touch controller, on I2C at 0x38 (reset on GPIO 18, interrupt on 17).
//
// Firmware only. read() gives the first touch point in the panel's own (raw) units; calib.h turns
// those into screen pixels.
#pragma once
#include <Arduino.h>
#include <Wire.h>

namespace ft {

inline TwoWire *bus = &Wire;
inline uint8_t address = 0x38;
inline int resetPin = 18, intPin = 17;

inline int r(uint8_t reg) {
  bus->beginTransmission(address);
  bus->write(reg);
  if (bus->endTransmission(false) != 0) return -1;
  if (bus->requestFrom(address, (uint8_t)1) != 1) return -1;
  return bus->read();
}

// true when the chip answers.
inline bool begin(TwoWire &wire, int rst = 18, int irq = 17, uint8_t addr = 0x38) {
  bus = &wire;
  address = addr;
  resetPin = rst;
  intPin = irq;
  if (resetPin >= 0) {
    pinMode(resetPin, OUTPUT);
    digitalWrite(resetPin, LOW);
    delay(10);
    digitalWrite(resetPin, HIGH);
  }
  if (intPin >= 0) pinMode(intPin, INPUT_PULLUP);
  delay(300);                               // it ignores I2C while it starts
  return r(0xA8) >= 0;
}

// The vendor (0xA8), chip (0xA3) and firmware (0xA6) bytes, as "11 64 02"; "none" if it is silent.
inline String ids() {
  int v = r(0xA8), c = r(0xA3), f = r(0xA6);
  if (v < 0) return "none";
  char s[16];
  snprintf(s, sizeof s, "%02X %02X %02X", v, c & 0xFF, f & 0xFF);
  return s;
}

// The first touch point: down is false when nothing touches the glass, or the chip did not answer.
inline bool read(int &x, int &y, bool &down) {
  bus->beginTransmission(address);
  bus->write(0x02);
  if (bus->endTransmission(false) != 0) { down = false; return false; }
  uint8_t b[5];
  if (bus->requestFrom(address, (uint8_t)5) != 5) { down = false; return false; }
  for (int i = 0; i < 5; i++) b[i] = bus->read();
  int points = b[0] & 0x0F;
  down = points >= 1 && points <= 2;
  if (down) {
    x = (b[1] & 0x0F) << 8 | b[2];
    y = (b[3] & 0x0F) << 8 | b[4];
  }
  return true;
}

}  // namespace ft
