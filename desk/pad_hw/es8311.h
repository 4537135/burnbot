// ES8311: the Claude Pad's audio codec (speaker out, microphone in), on I2C at 0x18.
//
// Firmware only. The register sequence follows Espressif's ES8311 driver
// (github.com/espressif/esp-bsp, components/es8311/es8311.c, Apache-2.0): the codec is an I2S
// slave, its master clock comes from the MCLK pin at 256 x 16 kHz = 4.096 MHz, 16-bit samples.
// Start I2S (so MCLK runs) before es::begin().
#pragma once
#include <Arduino.h>
#include <Wire.h>

namespace es {

inline TwoWire *bus = &Wire;
inline uint8_t address = 0x18;

inline bool w(uint8_t reg, uint8_t v) {
  bus->beginTransmission(address);
  bus->write(reg);
  bus->write(v);
  return bus->endTransmission() == 0;
}

inline int r(uint8_t reg) {
  bus->beginTransmission(address);
  bus->write(reg);
  if (bus->endTransmission(false) != 0) return -1;
  if (bus->requestFrom(address, (uint8_t)1) != 1) return -1;
  return bus->read();
}

// 0x8311 when the chip answers (registers 0xFD and 0xFE), 0 when it does not.
inline uint16_t chipId() {
  int a = r(0xFD), b = r(0xFE);
  return (a < 0 || b < 0) ? 0 : (uint16_t)(a << 8 | b);
}

// Speaker volume, 0..100 (0 is silent).
inline void volume(int v) {
  v = v < 0 ? 0 : v > 100 ? 100 : v;
  w(0x32, v == 0 ? 0 : (uint8_t)(v * 256 / 100 - 1));
}

// Microphone amplifier, 0..7: about 6 dB a step, 0 dB to 42 dB.
inline void micGain(int g) { w(0x16, (uint8_t)(g < 0 ? 0 : g > 7 ? 7 : g)); }

// Microphone level after the amplifier, in 0.5 dB steps: 0xBF is 0 dB, 0xFF is +32 dB.
inline void micLevel(uint8_t v) { w(0x17, v); }

inline void mute(bool on) {
  int v = r(0x31);
  if (v >= 0) w(0x31, on ? (v | 0x60) : (v & ~0x60));
}

// true when every register write went through.
inline bool begin(TwoWire &wire, uint8_t addr = 0x18, int vol = 60, int gain = 6) {   // gain 6: about 36 dB, speech from arm's length peaks near 75%
  bus = &wire;
  address = addr;
  bool ok = w(0x00, 0x1F);                 // reset
  delay(20);
  ok &= w(0x00, 0x00);
  ok &= w(0x00, 0x80);                     // power on, slave
  ok &= w(0x01, 0x3F);                     // every clock on, MCLK from its pin, not inverted

  // 4.096 MHz MCLK, 16 kHz: pre_div 1, pre_multi x1, adc_div 1, dac_div 1, fs single speed,
  // LRCK divider 256, BCLK divider 4, oversampling 0x10 for both converters.
  int v;
  v = r(0x02); ok &= v >= 0 && w(0x02, (uint8_t)((v & 0x07) | (0 << 5) | (0 << 3)));
  ok &= w(0x03, 0x10);
  ok &= w(0x04, 0x10);
  ok &= w(0x05, 0x00);
  v = r(0x06); ok &= v >= 0 && w(0x06, (uint8_t)((v & 0xE0) | (4 - 1)));
  v = r(0x07); ok &= v >= 0 && w(0x07, (uint8_t)((v & 0xC0) | 0x00));
  ok &= w(0x08, 0xFF);

  v = r(0x00); ok &= v >= 0 && w(0x00, (uint8_t)(v & 0xBF));   // slave (bit 6 clear)
  ok &= w(0x09, 0x0C);                     // DAC input: I2S, 16-bit
  ok &= w(0x0A, 0x0C);                     // ADC output: I2S, 16-bit

  ok &= w(0x0D, 0x01);                     // analog power up
  ok &= w(0x0E, 0x02);                     // microphone amplifier and ADC modulator on
  ok &= w(0x12, 0x00);                     // DAC on
  ok &= w(0x13, 0x10);                     // output drive on
  ok &= w(0x1C, 0x6A);                     // ADC equaliser bypassed, DC offset removed
  ok &= w(0x37, 0x08);                     // DAC equaliser bypassed

  ok &= w(0x14, 0x1A);                     // analog microphone, amplifier input selected
  micLevel(0xBF);
  micGain(gain);
  volume(vol);
  mute(false);
  return ok;
}

}  // namespace es
