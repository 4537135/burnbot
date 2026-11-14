// Everything the Burnbot desk screen draws, and how it reads what the Mac sends.
//
// Plain C++ with no Arduino in it: the firmware (burnbot_screen.ino) pushes
// these pixels to the display, and the simulator (tools/sim.cpp) writes the
// very same pixels to a picture on the Mac, so a screen can be checked without
// the board.
//
// The display is 240 x 320. The top 108 rows are words and numbers at full
// sharpness. Below them is the pixel-art scene (the robot, the level ladder,
// the fire, the falling tokens), drawn 80 x 71 and shown three times the size.
#pragma once
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

namespace bb {

const int W = 240, H = 320;
const int HUD_H = 108;                      // rows of words and numbers
const int PX = 3;                           // one art pixel is 3 x 3 on the display
const int AW = W / PX;                      // 80
const int AH = (H - HUD_H + PX - 1) / PX;   // 71 (the last row is cut short)
const int FH = 36;                          // rows the fire can reach

// 0xRRGGBB -> the display's 16 bits.
constexpr uint16_t rgb(uint32_t c) { return (uint16_t)(((c >> 8) & 0xF800) | ((c >> 5) & 0x07E0) | ((c >> 3) & 0x001F)); }

inline uint16_t mix(uint16_t under, uint16_t over, int a) {      // a: 0 nothing ... 255 all of it
  if (a <= 0) return under;
  if (a >= 255) return over;
  a += a >> 7;
  int ur = under >> 11, ug = (under >> 5) & 63, ub = under & 31;
  int r = ur + ((((over >> 11) - ur) * a) >> 8);
  int g = ug + (((((over >> 5) & 63) - ug) * a) >> 8);
  int b = ub + ((((over & 31) - ub) * a) >> 8);
  return (uint16_t)((r << 11) | (g << 5) | b);
}

// The robot's seven looks. The first six are the levels 0 to 5; autopilot is
// off the ladder (Claude working while the person is away).
enum Look { ASLEEP, IDLE, WARMING, CRUISING, LOCKED, OVERDRIVE, AUTOPILOT };

const uint16_t ACCENT[7] = {rgb(0x8493b8), rgb(0x9d968e), rgb(0xb8774c), rgb(0xf58d4d), rgb(0xffc74f), rgb(0xfff0c4), rgb(0x72b4f8)};
const uint16_t GLOW[7] = {rgb(0x8493b8), rgb(0x9d968e), rgb(0xb8774c), rgb(0xf58d4d), rgb(0xffc74f), rgb(0xff5a36), rgb(0x72b4f8)};
const uint16_t GROUND[7] = {rgb(0x070a14), rgb(0x0c0a0a), rgb(0x0e0907), rgb(0x0e0907), rgb(0x150c06), rgb(0x1c0805), rgb(0x070d16)};
const uint16_t INK = rgb(0xf6ece3), DIM = rgb(0x8f8177);

// What the Mac last said. The words arrive ready to draw, so renaming a level
// on the Mac needs nothing new on the board.
struct State {
  int look = ASLEEP;
  int level = 0, top = 5;                   // level -1: off the ladder
  int usual = -1;                           // the level usually reached at this hour, -1 unknown
  int intensity = 0;                        // 0 to 100
  int flame = 0;                            // 0 to 100: how hard tokens are burning
  int cuts[3] = {30, 75, 93};               // where cooking, locked in and on fire begin
  char name[20] = "ASLEEP";                 // the level's name
  char caption[20] = "LEVEL 0 OF 5";
  char rate[12] = "0";                      // tokens per hour, already shortened ("94.3M")
  char clock[8] = "";
};

// ---------------------------------------------------------------- reading a line
// "B|s=3|lv=3|tp=5|u=1|i=34|f=62|c=30,75,93|nm=COOKING|cp=LEVEL 3 OF 5|rt=94.3M|tm=17:58"

inline void copyText(char *to, size_t size, const char *from, size_t length) {
  size_t n = length < size - 1 ? length : size - 1;
  for (size_t i = 0; i < n; i++) {
    char c = from[i];
    to[i] = (c >= 'a' && c <= 'z') ? (char)(c - 32) : c;
  }
  to[n] = 0;
}

inline bool parse(const char *line, State &s) {
  if (line[0] != 'B' || line[1] != '|') return false;
  const char *p = line + 2;
  while (*p) {
    const char *eq = strchr(p, '=');
    if (!eq) return false;
    const char *end = strchr(eq, '|');
    if (!end) end = eq + strlen(eq);
    size_t klen = (size_t)(eq - p), vlen = (size_t)(end - eq - 1);
    const char *v = eq + 1;
    auto is = [&](const char *key) { return strlen(key) == klen && !strncmp(p, key, klen); };
    if (is("s")) s.look = atoi(v);
    else if (is("lv")) s.level = atoi(v);
    else if (is("tp")) s.top = atoi(v);
    else if (is("u")) s.usual = atoi(v);
    else if (is("i")) s.intensity = atoi(v);
    else if (is("f")) s.flame = atoi(v);
    else if (is("c")) sscanf(v, "%d,%d,%d", &s.cuts[0], &s.cuts[1], &s.cuts[2]);
    else if (is("nm")) copyText(s.name, sizeof(s.name), v, vlen);
    else if (is("cp")) copyText(s.caption, sizeof(s.caption), v, vlen);
    else if (is("rt")) copyText(s.rate, sizeof(s.rate), v, vlen);
    else if (is("tm")) copyText(s.clock, sizeof(s.clock), v, vlen);
    p = *end ? end + 1 : end;
  }
  if (s.look < 0 || s.look > AUTOPILOT) s.look = ASLEEP;
  if (s.intensity < 0) s.intensity = 0;
  if (s.intensity > 100) s.intensity = 100;
  if (s.flame < 0) s.flame = 0;
  if (s.flame > 100) s.flame = 100;
  return true;
}

// ---------------------------------------------------------------- letters
// A 5 x 7 font, the same one the Mac screens use. Each row is five bits.

struct Glyph { char c; uint8_t rows[7]; };
const Glyph FONT[] = {
    {'A', {14, 17, 17, 31, 17, 17, 17}}, {'B', {30, 17, 17, 30, 17, 17, 30}}, {'C', {14, 17, 16, 16, 16, 17, 14}},
    {'D', {30, 17, 17, 17, 17, 17, 30}}, {'E', {31, 16, 16, 30, 16, 16, 31}}, {'F', {31, 16, 16, 30, 16, 16, 16}},
    {'G', {14, 17, 16, 23, 17, 17, 15}}, {'H', {17, 17, 17, 31, 17, 17, 17}}, {'I', {14, 4, 4, 4, 4, 4, 14}},
    {'J', {7, 2, 2, 2, 2, 18, 12}}, {'K', {17, 18, 20, 24, 20, 18, 17}}, {'L', {16, 16, 16, 16, 16, 16, 31}},
    {'M', {17, 27, 21, 21, 17, 17, 17}}, {'N', {17, 17, 25, 21, 19, 17, 17}}, {'O', {14, 17, 17, 17, 17, 17, 14}},
    {'P', {30, 17, 17, 30, 16, 16, 16}}, {'Q', {14, 17, 17, 17, 21, 18, 13}}, {'R', {30, 17, 17, 30, 20, 18, 17}},
    {'S', {15, 16, 16, 14, 1, 1, 30}}, {'T', {31, 4, 4, 4, 4, 4, 4}}, {'U', {17, 17, 17, 17, 17, 17, 14}},
    {'V', {17, 17, 17, 17, 17, 10, 4}}, {'W', {17, 17, 17, 21, 21, 21, 10}}, {'X', {17, 17, 10, 4, 10, 17, 17}},
    {'Y', {17, 17, 17, 10, 4, 4, 4}}, {'Z', {31, 1, 2, 4, 8, 16, 31}},
    {'0', {14, 17, 19, 21, 25, 17, 14}}, {'1', {4, 12, 4, 4, 4, 4, 14}}, {'2', {14, 17, 1, 2, 4, 8, 31}},
    {'3', {31, 2, 4, 2, 1, 17, 14}}, {'4', {2, 6, 10, 18, 31, 2, 2}}, {'5', {31, 16, 30, 1, 1, 17, 14}},
    {'6', {6, 8, 16, 30, 17, 17, 14}}, {'7', {31, 1, 2, 4, 8, 8, 8}}, {'8', {14, 17, 17, 14, 17, 17, 14}},
    {'9', {14, 17, 17, 15, 1, 2, 12}},
    {'-', {0, 0, 0, 31, 0, 0, 0}}, {'.', {0, 0, 0, 0, 0, 12, 12}}, {',', {0, 0, 0, 0, 12, 4, 8}},
    {'!', {4, 4, 4, 4, 4, 0, 4}}, {'%', {24, 25, 2, 4, 8, 19, 3}}, {'/', {0, 1, 2, 4, 8, 16, 0}},
    {':', {0, 12, 12, 0, 12, 12, 0}}, {'+', {0, 4, 4, 31, 4, 4, 0}},
};

inline const uint8_t *glyph(char c) {
  for (const Glyph &g : FONT) if (g.c == c) return g.rows;
  return nullptr;                           // a space, or a letter the font lacks
}

// `gap` is the space between letters in display pixels (one font pixel unless squeezed).
inline int textWidth(const char *text, int scale, int gap = -1) {
  if (gap < 0) gap = scale;
  int n = (int)strlen(text);
  return n ? n * (5 * scale + gap) - gap : 0;
}

// ---------------------------------------------------------------- the words at the top
// Drawn a band of display rows at a time, so the board never holds a whole picture.

struct Band { uint16_t *px; int y0, rows; };

inline void bandRect(Band &b, int x, int y, int w, int h, uint16_t c) {
  int x1 = x + w > W ? W : x + w, y1 = y + h > b.y0 + b.rows ? b.y0 + b.rows : y + h;
  if (x < 0) x = 0;
  if (y < b.y0) y = b.y0;
  for (int yy = y; yy < y1; yy++) {
    uint16_t *row = b.px + (yy - b.y0) * W;
    for (int xx = x; xx < x1; xx++) row[xx] = c;
  }
}

inline void bandText(Band &b, int x, int y, const char *text, int scale, uint16_t c, int gap = -1) {
  if (y >= b.y0 + b.rows || y + 7 * scale <= b.y0) return;
  if (gap < 0) gap = scale;
  for (int i = 0; text[i]; i++) {
    const uint8_t *rows = glyph(text[i]);
    if (!rows) continue;
    for (int r = 0; r < 7; r++)
      for (int k = 0; k < 5; k++)
        if (rows[r] & (16 >> k)) bandRect(b, x + i * (5 * scale + gap) + k * scale, y + r * scale, scale, scale, c);
  }
}

inline void bandCentered(Band &b, int y, const char *text, int scale, uint16_t c, int gap = -1) {
  bandText(b, (W - textWidth(text, scale, gap)) / 2, y, text, scale, c, gap);
}

/** The top of the screen: which level, its name, the token burn, and how far up the intensity scale. */
inline void drawHud(Band &b, const State &s, bool waiting) {
  int look = waiting ? ASLEEP : s.look;
  uint16_t ground = GROUND[look], accent = ACCENT[look];
  bandRect(b, 0, b.y0, W, b.rows, ground);
  if (waiting) {
    bandCentered(b, 26, "WAITING FOR", 3, DIM);
    bandCentered(b, 58, "THE MAC", 3, DIM);
    return;
  }
  bandText(b, 8, 6, s.caption, 2, accent);
  // the clock, unless a long caption needs the room
  if (8 + textWidth(s.caption, 2) + 14 + textWidth(s.clock, 2) + 8 <= W) bandText(b, W - 8 - textWidth(s.clock, 2), 6, s.clock, 2, DIM);

  // The level's name, as large as fits: full size, then with the letters closer, then a size down.
  const int room = W - 16;
  if (textWidth(s.name, 4) <= room) bandCentered(b, 29, s.name, 4, accent);
  else if (textWidth(s.name, 4, 2) <= room) bandCentered(b, 29, s.name, 4, accent, 2);
  else bandCentered(b, 32, s.name, 3, accent);

  const char *unit = "TOKENS/H";
  int rate = textWidth(s.rate, 3), gap = 9;
  int x = (W - (rate + gap + textWidth(unit, 2))) / 2;
  bandText(b, x, 68, s.rate, 3, INK);
  bandText(b, x + rate + gap, 75, unit, 2, DIM);

  // Intensity, with a notch where each level above warming up begins.
  const int bx = 8, bw = W - 16, by = 98, bh = 5;
  bandRect(b, bx, by, bw, bh, mix(ground, accent, 46));
  bandRect(b, bx, by, bw * s.intensity / 100, bh, accent);
  for (int k = 0; k < 3; k++) bandRect(b, bx + bw * s.cuts[k] / 100 - 1, by - 2, 2, bh + 4, ground);
}

// ---------------------------------------------------------------- the pixel-art scene

inline void rect(uint16_t *fb, float fx, float fy, int w, int h, uint16_t c, int a = 255) {
  int x = (int)lroundf(fx), y = (int)lroundf(fy);
  int x1 = x + w > AW ? AW : x + w, y1 = y + h > AH ? AH : y + h;
  if (x < 0) x = 0;
  if (y < 0) y = 0;
  for (int yy = y; yy < y1; yy++)
    for (int xx = x; xx < x1; xx++) fb[yy * AW + xx] = a >= 255 ? c : mix(fb[yy * AW + xx], c, a);
}

/** The robot, standing with its feet at (cx, gy). The same drawing as on the Mac, look for look. */
inline void robot(uint16_t *fb, int cx, int gy, int look, float t) {
  bool asleep = look == ASLEEP, idle = look == IDLE, locked = look == LOCKED, over = look == OVERDRIVE, autop = look == AUTOPILOT;
  bool working = look == WARMING || look == CRUISING || locked || over;
  uint16_t accent = ACCENT[look];
  uint16_t body = rgb(0xd9774f), hi = rgb(0xf3a57f), sh = rgb(0xad5330), dark = rgb(0x7a391e);
  if (asleep) { body = rgb(0x80554a); hi = rgb(0x96685b); sh = rgb(0x664238); dark = rgb(0x4a2f27); }
  if (over) { body = rgb(0xea6a3a); hi = rgb(0xffb489); sh = rgb(0xb8481f); }
  const uint16_t screen = rgb(0x1e110c), white = rgb(0xffffff);
#define R(x, y, w, h, c) rect(fb, (float)(x), (float)(y), w, h, c)

  float pace = asleep ? 1.1f : idle ? 1.7f : autop ? 2.0f : look == WARMING ? 3.0f : look == CRUISING ? 4.2f : locked ? 6.0f : 9.0f;
  int bob = sinf(t * pace) > 0.35f ? 1 : 0;
  int x0 = cx + (over ? (int)lroundf(sinf(t * 41)) : 0) + (autop ? (int)lroundf(sinf(t * 1.3f)) : 0);
  int hy = gy - 43 + bob + (asleep ? 2 : 0);   // top of the head

  // legs and feet
  R(x0 - 9, gy - 5, 5, 5, sh);
  R(x0 + 4, gy - 5, 5, 5, sh);
  R(x0 - 10, gy - 2, 7, 2, dark);
  R(x0 + 3, gy - 2, 7, 2, dark);

  // arms: resting at the sides, or raised and tapping while working
  float tapHz = look == WARMING ? 3 : look == CRUISING ? 6 : locked ? 10 : 15;
  int beat = (int)floorf(t * tapHz);
  if (working) {
    int l = beat % 2 ? 0 : 2, r = beat % 2 ? 2 : 0;
    R(x0 - 15, gy - 18, 4, 6, sh);
    R(x0 + 11, gy - 18, 4, 6, sh);
    R(x0 - 17, gy - 13 + l, 5, 4, body);
    R(x0 + 12, gy - 13 + r, 5, 4, body);
    R(x0 - 17, gy - 10 + l, 5, 2, hi);
    R(x0 + 12, gy - 10 + r, 5, 2, hi);
    int sx = beat % 2 ? x0 + 13 : x0 - 16;   // key sparks under the hand that just came down
    R(sx + (beat * 7) % 4, gy - 6, 1, 1, rgb(0xffe9c7));
    if (locked || over) R(sx + (beat * 5) % 4, gy - 4, 1, 1, accent);
  } else {
    R(x0 - 15, gy - 18, 4, 11, sh);
    R(x0 + 11, gy - 18, 4, 11, sh);
    R(x0 - 15, gy - 9, 4, 3, hi);
    R(x0 + 11, gy - 9, 4, 3, hi);
  }

  // body with a chest meter
  R(x0 - 11, gy - 19, 22, 14, body);
  R(x0 - 11, gy - 19, 22, 1, hi);
  R(x0 - 11, gy - 6, 22, 1, sh);
  R(x0 + 10, gy - 18, 1, 12, sh);
  R(x0 - 6, gy - 16, 12, 7, screen);
  for (int k = 0; k < 3; k++) {
    int h = working ? 1 + (int)floorf((sinf(t * (5 + k * 2.3f) + k * 1.7f) + 1) * 2.4f) : asleep ? 1 : autop ? 3 : 2;
    R(x0 - 5 + k * 4, gy - 10 - h, 2, h, asleep ? rgb(0x5d4a44) : accent);
  }

  // neck and head
  R(x0 - 3, gy - 21 + bob, 6, 2, sh);
  R(x0 - 15, hy, 30, 22, body);
  R(x0 - 16, hy + 1, 32, 20, body);
  R(x0 - 15, hy, 30, 1, hi);
  R(x0 - 16, hy + 1, 1, 20, hi);
  R(x0 + 15, hy + 1, 1, 20, sh);
  R(x0 - 15, hy + 21, 30, 1, sh);
  R(x0 - 18, hy + 8, 2, 6, sh);
  R(x0 + 16, hy + 8, 2, 6, sh);
  R(x0 - 11, hy + 4, 22, 13, screen);
  R(x0 - 12, hy + 5, 24, 11, screen);

  // eyes
  uint16_t glow = asleep ? rgb(0x8a90a6) : autop ? rgb(0xa9d4ff) : locked ? rgb(0xffd87c) : over ? white : rgb(0xffe9c7);
  int ey = hy + 7, lx = x0 - 8, rx = x0 + 4;
  static const int LOOKS[6] = {-1, 0, 0, 1, 0, 0};
  int glance = idle ? LOOKS[(int)floorf(t / 1.3f) % 6] : 0;
  bool blink = !asleep && !over && !autop && fmodf(t, locked ? 6.3f : 3.7f) < 0.13f;
  if (asleep || blink) {
    R(lx, ey + 4, 4, 1, glow);
    R(rx, ey + 4, 4, 1, glow);
  } else if (autop) {
    int eyes[2] = {lx, rx};
    for (int ex : eyes) {
      R(ex, ey + 2, 1, 2, glow);
      R(ex + 1, ey + 1, 2, 1, glow);
      R(ex + 3, ey + 2, 1, 2, glow);
    }
  } else if (locked || over) {
    rect(fb, lx - 1, ey, 6, 5, accent, 71);
    rect(fb, rx - 1, ey, 6, 5, accent, 71);
    R(lx, ey + 1, 4, 3, glow);
    R(rx, ey + 1, 4, 3, glow);
    R(lx + 3, ey + 1, 1, 1, screen);          // slanted inner corners: the focused look
    R(rx, ey + 1, 1, 1, screen);
    if (over) {
      for (int k = 0; k < 3; k++) {
        int up = ((int)floorf(t * 14) + k) % 3;
        R(lx + (k * 7 + (int)floorf(t * 20)) % 4, ey - 1 - up, 1, 2, rgb(0xff9a3d));
        R(rx + (k * 5 + (int)floorf(t * 17)) % 4, ey - 1 - up, 1, 2, rgb(0xff9a3d));
      }
    }
  } else {
    R(lx + glance, ey, 4, 5, glow);
    R(rx + glance, ey, 4, 5, glow);
    if (look == CRUISING) {
      R(lx + glance, ey, 1, 1, white);
      R(rx + glance, ey, 1, 1, white);
    }
  }

  // mouth
  int my = hy + 14;
  if (asleep) R(x0 - 1, my, 2, 1, glow);
  else if (autop) {
    R(x0 - 4, my - 1, 1, 1, glow);
    R(x0 - 3, my, 6, 1, glow);
    R(x0 + 3, my - 1, 1, 1, glow);
  } else if (over) {
    R(x0 - 4, my - 1, 8, 2, white);
    for (int k = 0; k < 3; k++) R(x0 - 2 + k * 2, my - 1, 1, 2, screen);
  } else if (locked) R(x0 - 3, my, 6, 1, glow);
  else if (look == CRUISING) {
    R(x0 - 3, my - 1, 1, 1, glow);
    R(x0 - 2, my, 4, 1, glow);
    R(x0 + 2, my - 1, 1, 1, glow);
  } else R(x0 - 2, my, 4, 1, glow);

  // antenna
  R(x0 - 1, hy - 5, 2, 5, sh);
  if (autop) {
    static const int BLADE[4] = {9, 6, 2, 6};
    int w = BLADE[(int)floorf(t * 12) % 4];
    R(x0 - 1, hy - 8, 2, 3, rgb(0x9fd0ff));
    R(x0 - w / 2.0f, hy - 8, w, 1, rgb(0xd6ebff));
  } else {
    uint16_t bulb = rgb(0x5a4640);
    if (idle) bulb = sinf(t * 1.6f) > 0.6f ? rgb(0xe6ab62) : rgb(0x7a5a3a);
    else if (working) bulb = (locked || over || beat % 2) ? accent : rgb(0x8a5a3a);
    if (locked || over) rect(fb, x0 - 4, hy - 11, 8, 8, accent, (int)(255 * (0.25f + 0.15f * sinf(t * 5))));
    R(x0 - 2, hy - 9, 4, 4, bulb);
    if (over) R(x0 - 1, hy - 8, 2, 2, rgb(0xfff6d2));
  }

  // headphones go on when it locks in
  if (locked || over) {
    uint16_t band = rgb(0x2c2832), cup = rgb(0x3b3542);
    R(x0 - 17, hy - 2, 34, 2, band);
    R(x0 - 18, hy - 1, 2, 8, band);
    R(x0 + 16, hy - 1, 2, 8, band);
    R(x0 - 20, hy + 6, 4, 11, cup);
    R(x0 + 16, hy + 6, 4, 11, cup);
    R(x0 - 20, hy + 10, 1, 3, accent);
    R(x0 + 19, hy + 10, 1, 3, accent);
  }

  // on fire: the head is burning
  if (over) {
    for (int k = 0; k < 6; k++) {
      int fx = x0 - 13 + k * 5 + (int)lroundf(sinf(t * 9 + k));
      int fh = 3 + (int)floorf((sinf(t * 13 + k * 2.1f) + 1) * 2.4f);
      R(fx, hy - fh, 2, fh, rgb(0xff8a2e));
      if (fh > 4) R(fx, hy - fh + 2, 1, fh - 3, rgb(0xffe08a));
    }
  }

  // asleep: z z z
  if (asleep) {
    for (int k = 0; k < 3; k++) {
      float p = fmodf(t * 0.32f + k / 3.0f, 1.0f);
      float zx = x0 + 16 + p * 12, zy = hy - 2 - p * 18;
      int w = p > 0.5f ? 4 : 3, a = (int)(255 * fminf(1.0f, (1 - p) * 1.6f));
      uint16_t z = rgb(0xc5cde4);
      rect(fb, zx, zy, w, 1, z, a);
      for (int d = 1; d < w - 1; d++) rect(fb, zx + w - 1 - d, zy + d, 1, 1, z, a);
      rect(fb, zx, zy + w - 1, w, 1, z, a);
    }
  }
#undef R
}

struct Drop { float x, y, vy, spin; bool on; };
struct Ember { float x, y, vx, vy, life, ttl; bool on; };

// A token: a small diamond that spins as it falls, so three widths of it.
const char *const TOKEN[3][5] = {
    {"..x..", ".xhx.", "xhxxs", ".xxs.", "..s.."},
    {".x.", "xhx", "xhs", "xxs", ".s."},
    {"x", "h", "x", "s", "s"},
};

/** The moving part of the screen: fire, falling tokens, embers, and the robot standing in them. */
struct Scene {
  static const int CX = 45, GY = 54;        // the robot's feet
  uint8_t fire[AW * FH];
  float bump[AW];
  uint16_t palette[37];
  uint8_t soft[37];
  Drop drops[20];
  Ember embers[56];
  float flame = 0, t = 0, dropAcc = 0, emberAcc = 0, night = 0, fireAcc = 0;
  uint32_t seed = 0x2545F491;
  bool primed = false;

  Scene() {
    memset(fire, 0, sizeof(fire));
    memset(bump, 0, sizeof(bump));
    memset(drops, 0, sizeof(drops));
    memset(embers, 0, sizeof(embers));
    // heat 1..36 -> colour; the lowest heats are see-through so flame edges stay soft
    const int stops[6][4] = {{0, 40, 6, 4}, {6, 128, 22, 8}, {14, 214, 70, 18}, {22, 247, 138, 36}, {30, 255, 204, 92}, {36, 255, 247, 214}};
    palette[0] = 0;
    soft[0] = 0;
    for (int i = 1; i <= 36; i++) {
      int k = 0;
      while (stops[k + 1][0] < i) k++;
      float f = (float)(i - stops[k][0]) / (stops[k + 1][0] - stops[k][0]);
      int c[3];
      for (int j = 0; j < 3; j++) c[j] = (int)(stops[k][j + 1] + (stops[k + 1][j + 1] - stops[k][j + 1]) * f);
      palette[i] = rgb(((uint32_t)c[0] << 16) | ((uint32_t)c[1] << 8) | (uint32_t)c[2]);
      soft[i] = i < 4 ? (uint8_t)(i * 62) : 255;
    }
  }

  uint32_t next() { seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5; return seed; }
  float chance() { return (next() & 0xFFFFFF) / 16777216.0f; }

  void stepFire() {
    const int base = (FH - 1) * AW;
    for (int x = 0; x < AW; x++) {
      float lump = 0.74f + 0.26f * sinf(x * 0.23f + t * 2.3f) * sinf(x * 0.061f - t * 1.1f);
      float h = 27 * flame * lump + bump[x];              // 27, not the full 36: flames to the robot's waist, never over its face
      if (flame < 0.1f && chance() < 0.5f) h *= 0.4f;       // embers flicker
      bump[x] *= 0.9f;
      fire[base + x] = h <= 0 ? 0 : h >= 36 ? 36 : (uint8_t)h;
    }
    for (int y = 1; y < FH; y++) {
      int row = y * AW;
      for (int x = 0; x < AW; x++) {
        int v = fire[row + x];
        uint32_t r = next();
        int dx = x - (int)(r % 3) + 1;
        if (dx < 0) dx = 0;
        else if (dx >= AW) dx = AW - 1;
        int cool = ((r >> 8) & 255) < 235 ? 1 : 0;
        fire[row - AW + dx] = (uint8_t)(v > cool ? v - cool : 0);
      }
    }
  }

  void burst(float x) {
    for (int d = -4; d <= 4; d++) {
      int i = (int)lroundf(x) + d;
      if (i >= 0 && i < AW) bump[i] += 16 - abs(d) * 3;
    }
    int made = 0;
    for (Ember &e : embers) {
      if (e.on || made >= 4) continue;
      e = {x + chance() * 4 - 2, AH - 3 - chance() * 5, (chance() - 0.5f) * 16, -(18 + chance() * 26), 1, 0.8f + chance() * 1.2f, true};
      made++;
    }
  }

  /** Moves everything on by dt seconds. */
  void step(float dt, const State &s, bool waiting) {
    if (dt > 0.2f) dt = 0.2f;
    t += dt;
    int look = waiting ? ASLEEP : s.look;
    float target = waiting ? 0 : s.flame / 100.0f;
    float wantNight = look == ASLEEP ? 1 : look == IDLE ? 0.45f : 0;
    if (!primed) {                          // the first reading: start where things are
      primed = true;
      flame = target;
      night = wantNight;
    }
    flame += (target - flame) * (1 - expf(-dt * 1.1f));
    night += (wantNight - night) * (1 - expf(-dt * 0.8f));

    fireAcc += dt;
    for (int n = 0; fireAcc >= 1 / 20.0f && n < 3; n++) {
      fireAcc -= 1 / 20.0f;
      stepFire();
    }

    // more burn, more tokens falling into the fire
    float rate = flame > 0.1f ? 0.25f + 3.5f * flame * flame : 0;
    dropAcc += rate * dt;
    while (dropAcc >= 1) {
      dropAcc -= 1;
      for (Drop &d : drops) {
        if (d.on) continue;
        d = {14 + chance() * (AW - 20), -6, 14 + chance() * 18, chance() * 4, true};
        break;
      }
    }
    float surface = AH - 5 - flame * 14;
    for (Drop &d : drops) {
      if (!d.on) continue;
      d.vy += 110 * dt;
      d.y += d.vy * dt;
      d.spin += dt * 7;
      if (d.y >= surface) {
        burst(d.x + 2);
        d.on = false;
      }
    }

    emberAcc += flame * AW * 0.22f * dt;
    while (emberAcc >= 1) {
      emberAcc -= 1;
      for (Ember &e : embers) {
        if (e.on) continue;
        e = {chance() * AW, AH - 2 - chance() * flame * 26, (chance() - 0.5f) * 6, -(7 + chance() * 16), 1, 1.4f + chance() * 2.4f, true};
        break;
      }
    }
    for (Ember &e : embers) {
      if (!e.on) continue;
      e.life -= dt / e.ttl;
      if (e.life <= 0) { e.on = false; continue; }
      e.x += (e.vx + sinf(t * 3 + e.y * 0.2f) * 4) * dt;
      e.y += e.vy * dt;
    }
  }

  /** Draws the scene into fb, AW x AH. */
  void draw(uint16_t *fb, const State &s, bool waiting) {
    int look = waiting ? ASLEEP : s.look;
    uint16_t ground = GROUND[look];
    for (int i = 0; i < AW * AH; i++) fb[i] = ground;

    // stars come out when nothing is happening
    if (night > 0.02f) {
      uint32_t h = 0x9E3779B9;
      for (int k = 0; k < 26; k++) {
        h = h * 1664525u + 1013904223u;
        int x = (h >> 8) % AW, y = (h >> 20) % (AH * 6 / 10);
        float twinkle = 0.35f + 0.65f * fabsf(sinf(t * 0.7f + k));
        rect(fb, x, y, 1, 1, rgb(0xcfd8f0), (int)(255 * night * twinkle));
      }
    }

    // locked in: a slow sunburst behind the robot
    if (look == LOCKED || look == OVERDRIVE) {
      float spin = t * (look == OVERDRIVE ? 0.5f : 0.18f);
      for (int k = 0; k < 12; k++) {
        float a = k / 12.0f * 6.2831853f + spin, ca = cosf(a), sa = sinf(a);
        int alpha = (int)(255 * (look == OVERDRIVE ? 0.10f : 0.075f) * (0.75f + 0.25f * sinf(t * 2 + k)));
        for (int r = 24; r < 78; r += 2) {
          int w = r / 10 < 1 ? 1 : r / 10;
          rect(fb, CX + ca * r - w / 2.0f, GY - 30 + sa * r - w / 2.0f, w, w, GLOW[look], alpha);
        }
      }
    }

    // The ladder: one lamp per level, lit up to where you are. A tick marks
    // the level you usually reach at this hour.
    for (int level = 0; level <= s.top && level <= 5; level++) {
      int y = 5 + (5 - level) * 8;
      bool lit = !waiting && s.level >= level;
      bool here = !waiting && s.level == level;
      if (here) rect(fb, 2, y - 1, 9, 8, ACCENT[level], 255);
      rect(fb, 3, y, 7, 6, lit ? ACCENT[level] : rgb(0x2a221d), 255);
      if (here) rect(fb, 5, y + 2, 3, 2, ground, 255);
      if (!waiting && s.usual == level) rect(fb, 12, y + 2, 3, 2, INK, 255);
    }
    if (!waiting && s.level < 0) rect(fb, 3, 53, 7, 2, ACCENT[AUTOPILOT], 255);   // off the ladder

    // platform
    rect(fb, CX - 19, GY + 3, 3, AH - GY, rgb(0x17110e));
    rect(fb, CX + 16, GY + 3, 3, AH - GY, rgb(0x17110e));
    rect(fb, CX - 24, GY, 48, 3, rgb(0x2b211c));
    rect(fb, CX - 24, GY, 48, 1, rgb(0x46362c));

    robot(fb, CX, GY, look, t);

    // tokens
    for (const Drop &d : drops) {
      if (!d.on) continue;
      static const int FRAME[4] = {0, 1, 2, 1};
      const char *const *rows = TOKEN[FRAME[(int)d.spin % 4]];
      int w = (int)strlen(rows[0]);
      for (int r = 0; r < 5; r++)
        for (int q = 0; q < w; q++) {
          char ch = rows[r][q];
          if (ch == '.') continue;
          rect(fb, lroundf(d.x) + (5 - w) / 2.0f + q, lroundf(d.y) + r, 1, 1, ch == 'x' ? rgb(0xffd2ac) : ch == 'h' ? rgb(0xffffff) : rgb(0xdd8552));
        }
    }

    // fire, over the robot's feet
    for (int y = 0; y < FH; y++) {
      int ay = AH - FH + y;
      if (ay < 0) continue;
      for (int x = 0; x < AW; x++) {
        int v = fire[y * AW + x];
        if (v) fb[ay * AW + x] = mix(fb[ay * AW + x], palette[v], soft[v]);
      }
    }

    for (const Ember &e : embers) {
      if (!e.on) continue;
      uint16_t c = e.life > 0.66f ? rgb(0xffe7a3) : e.life > 0.33f ? rgb(0xff9a3d) : rgb(0xb5431b);
      rect(fb, e.x, e.y, 1, 1, c, (int)(255 * fminf(1.0f, e.life * 1.5f)));
    }
  }
};

}  // namespace bb
