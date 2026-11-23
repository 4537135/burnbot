// The Desk Buddy Perch's screen: a 1.5" SH1107 OLED, 128 x 128 and one colour, of which
// the case window shows the top 128 x 116.
//
// Plain C++ like render.h, which it builds on: the firmware sends these pixels to the
// OLED, and the simulator (tools/sim.cpp --perch) writes them to a picture.
//
// The top 30 rows are the words: the level's name, the token burn and the clock, and the
// intensity bar. Below them is the same scene as on the colour screen (robot, ladder, fire,
// falling tokens), one art pixel to one OLED pixel, turned to one colour by ordered
// dithering: dark goes black, bright goes white, the shades between become even patterns
// of dots that stay put while the picture moves.
#pragma once
#include "render.h"

namespace pp {

const int W = 128, H = 116;                 // what the case shows
const int OLED_H = 128;                     // what the OLED has (the case hides 12 rows)
const int TOP = 30;                         // rows of words
const int AW = W, AH = H - TOP;             // the scene: 128 x 86
const int LIFT = 12;                        // the robot's feet, rows above the bottom

// ---------------------------------------------------------------- drawing in one colour
// A frame is W x H bytes, 1 for a lit pixel.

inline void dot(uint8_t *f, int x, int y, uint8_t on = 1) {
  if (x >= 0 && x < W && y >= 0 && y < H) f[y * W + x] = on;
}

inline void box(uint8_t *f, int x, int y, int w, int h, uint8_t on = 1) {
  for (int yy = y; yy < y + h; yy++)
    for (int xx = x; xx < x + w; xx++) dot(f, xx, yy, on);
}

// The 5 x 7 letters of render.h; `gap` is the space between them (one font pixel unless squeezed).
inline void text(uint8_t *f, int x, int y, const char *s, int scale = 1, int gap = -1, uint8_t on = 1) {
  if (gap < 0) gap = scale;
  for (int i = 0; s[i]; i++) {
    const uint8_t *rows = bb::glyph(s[i]);
    if (!rows) continue;
    for (int r = 0; r < 7; r++)
      for (int k = 0; k < 5; k++)
        if (rows[r] & (16 >> k)) box(f, x + i * (5 * scale + gap) + k * scale, y + r * scale, scale, scale, on);
  }
}

inline void centered(uint8_t *f, int y, const char *s, int scale = 1, int gap = -1, uint8_t on = 1) {
  text(f, (W - bb::textWidth(s, scale, gap)) / 2, y, s, scale, gap, on);
}

// Words as large as fit across `room`: twice the size, then with the letters closer, then plain.
inline void headline(uint8_t *f, int y, const char *s, int room = W - 4) {
  if (bb::textWidth(s, 2) <= room) centered(f, y, s, 2);
  else if (bb::textWidth(s, 2, 1) <= room) centered(f, y, s, 2, 1);
  else centered(f, y + 4, s, 1, bb::textWidth(s, 1) <= room ? 1 : 0);
}

// ---------------------------------------------------------------- colour to one colour

// How much of a colour to light, 0 (black) to 16 (white), from how bright it is. A few even
// steps, not a smooth ramp: the robot reads as solid shapes, with a pattern only for its
// shadows, the unlit lamps and the fire's edges.
inline int share(uint16_t c) {
  int r = (c >> 11) * 255 / 31, g = ((c >> 5) & 63) * 255 / 63, b = (c & 31) * 255 / 31;
  int lum = (77 * r + 150 * g + 29 * b) >> 8;
  return lum < 26 ? 0 : lum < 60 ? 4 : lum < 110 ? 8 : lum < 150 ? 12 : 16;
}

const uint8_t BAYER[4][4] = {{0, 8, 2, 10}, {12, 4, 14, 6}, {3, 11, 1, 9}, {15, 7, 13, 5}};

/** The scene (AW x AH, the colours render.h drew) into rows TOP.. of the frame. */
inline void scene(uint8_t *f, const uint16_t *art) {
  for (int y = 0; y < AH; y++)
    for (int x = 0; x < AW; x++)
      f[(TOP + y) * W + x] = BAYER[y & 3][x & 3] < share(art[y * AW + x]);
}

// ---------------------------------------------------------------- the words

/** Which level, the token burn and the clock, and the intensity bar with its notches. */
inline void words(uint8_t *f, const bb::State &s, bool waiting) {
  if (waiting) {
    centered(f, 1, "WAITING FOR", 2, 1);
    centered(f, 16, "THE MAC", 2);
    return;
  }
  headline(f, 0, s.name);

  char rate[24];
  snprintf(rate, sizeof(rate), "%s TOKENS/H", s.rate);
  int rw = bb::textWidth(rate, 1), cw = bb::textWidth(s.clock, 1);
  if (rw + 8 + cw <= W - 2) {
    text(f, 1, 17, rate);
    text(f, W - 1 - cw, 17, s.clock);
  } else {
    centered(f, 17, rate);
  }

  // A dotted track, filled solid as far as the intensity goes. Each notch (where cooking,
  // locked in and on fire begin) is a gap in the fill, or a tick on the track.
  const int bx = 1, bw = W - 2, by = 26;
  int fill = bw * s.intensity / 100;
  for (int x = 0; x < bw; x++) {
    if (x < fill) box(f, bx + x, by, 1, 3);
    else if (x % 2 == 0) dot(f, bx + x, by + 1);
  }
  for (int k = 0; k < 3; k++) {
    int x = bx + bw * s.cuts[k] / 100;
    box(f, x, by, 1, 3, x < bx + fill ? 0 : 1);
  }
}

/** What the robot is saying: a box across the top with the title on a lit bar and up to four
 *  lines below it, and a tail down to the robot's antenna. Drawn over the words and as much
 *  of the scene as it needs (four lines reach row 48; the antenna starts at 52). */
inline void bubble(uint8_t *f, const bb::Moment &m, int tip) {
  int n = m.count < 0 ? 0 : m.count > 4 ? 4 : m.count;
  int h = n ? 13 + 8 * n : 12;
  box(f, 0, 0, W, h + 3, 0);                           // what is under it goes, and a row under the tail
  box(f, 1, 0, W - 2, 1);                              // the border, its corners notched
  box(f, 1, h - 1, W - 2, 1);
  box(f, 0, 1, 1, h - 2);
  box(f, W - 1, 1, 1, h - 2);
  box(f, 2, 2, W - 4, 9);                              // the title, dark on a lit bar
  int room = W - 8;
  text(f, 4, 3, m.title, 1, bb::textWidth(m.title, 1) <= room ? 1 : 0, 0);
  for (int i = 0; i < n; i++) text(f, 4, 13 + 8 * i, m.lines[i], 1, bb::textWidth(m.lines[i], 1) <= room ? 1 : 0);
  // the tail
  box(f, tip - 3, h, 7, 1);
  box(f, tip - 2, h + 1, 5, 1);
  box(f, tip - 1, h + 2, 3, 1);
}

/** The whole frame: the scene (already drawn by render.h into `art`), then the words or what
 *  the robot is saying. `tip`: the robot's column, for the bubble's tail. */
inline void draw(uint8_t *f, const uint16_t *art, const bb::State &s, bool waiting, const bb::Moment &m, int tip) {
  memset(f, 0, W * H);
  scene(f, art);
  if (!waiting && m.on) bubble(f, m, tip);
  else words(f, s, waiting);
}

}  // namespace pp
