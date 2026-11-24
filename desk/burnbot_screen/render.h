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
const int ROBOT_X = 45;                     // the art column the robot stands on
const int MAX_AW = 160;                     // the widest scene a screen can ask for (the Claude Pad, 320 wide at 2x)

// A picture of the scene, w x h art pixels. The colour screen's is AW x AH; another
// screen can have a scene of its own size (see Scene).
struct Art { uint16_t *px; int w, h; };

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
// off the ladder (the AI working while the person is away).
enum Look { ASLEEP, IDLE, WARMING, CRUISING, LOCKED, OVERDRIVE, AUTOPILOT };

// A reaction drawn over the level's face for a few seconds (the same three as on the Mac).
enum Expr { EX_NONE, EX_WORRIED, EX_HAPPY, EX_WAITING, EX_PUZZLED, EX_BORED };

// One colour per level, cold to hot like a temperature scale (the same as on the Mac).
const uint16_t ACCENT[7] = {rgb(0x6f83ad), rgb(0x62a8f5), rgb(0x4fc9a4), rgb(0xf4c542), rgb(0xff8030), rgb(0xf43f6b), rgb(0xa78bfa)};
const uint16_t GROUND[7] = {rgb(0x0a0f1a), rgb(0x0b0d12), rgb(0x0b0d12), rgb(0x0b0d12), rgb(0x120e0b), rgb(0x170b0c), rgb(0x0e0c18)};
const uint16_t INK = rgb(0xeef1f6), DIM = rgb(0x6c7686);

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
  int expr = EX_NONE;                       // a reaction over the face
  int wins = 0, target = 0, streak = 0;     // today's wins against the goal (target 0: none sent)
};

// What the robot is saying: a speech bubble that takes the place of the words at
// the top while it shows. The Mac fits the words to the screen before sending them.
struct Moment {
  bool on = false;
  char kind = 0;                            // w waiting on you, b a breakthrough, m your move, d session over
  char title[24] = "";
  char lines[4][20] = {"", "", "", ""};
  int count = 0;                            // lines in use
  int head = 1;                             // how many of them are the first, brighter line wrapped
};

// ---------------------------------------------------------------- reading a line
// "B|s=3|lv=3|tp=5|u=1|i=34|f=62|c=30,75,93|nm=COOKING|cp=LEVEL 3 OF 5|rt=94.3M|tm=17:58|ex=w"

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
    else if (is("ex")) s.expr = *v == 'w' ? EX_WORRIED : *v == 'h' ? EX_HAPPY : *v == 'a' ? EX_WAITING
                              : *v == 'p' ? EX_PUZZLED : *v == 'd' ? EX_BORED : EX_NONE;
    else if (is("gl")) {                      // "3/4": wins today / the goal
      s.wins = atoi(v);
      const char *slash = (const char *)memchr(v, '/', vlen);
      s.target = slash ? atoi(slash + 1) : 0;
    }
    else if (is("sk")) s.streak = atoi(v);
    p = *end ? end + 1 : end;
  }
  if (s.look < 0 || s.look > AUTOPILOT) s.look = ASLEEP;
  if (s.intensity < 0) s.intensity = 0;
  if (s.intensity > 100) s.intensity = 100;
  if (s.flame < 0) s.flame = 0;
  if (s.flame > 100) s.flame = 100;
  return true;
}

// "M|k=w|h=1|t=YOUR CALL|a=SHOP IS STUCK|b=UNTIL YOU SAY YES|c=TO RM -RF DIST &&|d=NPM RUN BUILD"
// k: w waiting on you, b a breakthrough, m your move, d session over. h: how many of the lines
// are the first one (it is brighter), wrapped. The Mac wraps the words to 18 columns.
// A bare "M|" takes the bubble away. Lines a to d, in order; the title alone is fine too.
inline bool parseMoment(const char *line, Moment &m) {
  if (line[0] != 'M' || line[1] != '|') return false;
  Moment next;
  const char *p = line + 2;
  while (*p) {
    const char *eq = strchr(p, '=');
    if (!eq) return false;
    const char *end = strchr(eq, '|');
    if (!end) end = eq + strlen(eq);
    size_t klen = (size_t)(eq - p), vlen = (size_t)(end - eq - 1);
    const char *v = eq + 1;
    if (klen == 1 && *p == 'k') next.kind = *v;
    else if (klen == 1 && *p == 'h') next.head = atoi(v);
    else if (klen == 1 && *p == 't') copyText(next.title, sizeof(next.title), v, vlen);
    else if (klen == 1 && *p >= 'a' && *p <= 'd') {
      int i = *p - 'a';
      copyText(next.lines[i], sizeof(next.lines[i]), v, vlen);
      if (i + 1 > next.count) next.count = i + 1;
    }
    p = *end ? end + 1 : end;
  }
  next.on = next.title[0] != 0;
  m = next;
  return true;
}

inline bool sameMoment(const Moment &a, const Moment &b) {
  if (a.on != b.on || a.kind != b.kind || a.count != b.count || a.head != b.head || strcmp(a.title, b.title)) return false;
  for (int i = 0; i < a.count; i++)
    if (strcmp(a.lines[i], b.lines[i])) return false;
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
    // for what the robot says: commands, file names, questions
    {'&', {12, 18, 20, 8, 21, 18, 13}}, {'\'', {4, 4, 8, 0, 0, 0, 0}}, {'"', {10, 10, 0, 0, 0, 0, 0}},
    {'(', {2, 4, 4, 4, 4, 4, 2}}, {')', {8, 4, 4, 4, 4, 4, 8}}, {'?', {14, 17, 1, 2, 4, 0, 4}},
    {'=', {0, 0, 31, 0, 31, 0, 0}}, {'_', {0, 0, 0, 0, 0, 0, 31}}, {'*', {0, 10, 4, 10, 0, 0, 0}},
    {'#', {10, 10, 31, 10, 31, 10, 10}}, {';', {0, 12, 12, 0, 12, 4, 8}}, {'<', {0, 2, 4, 8, 4, 2, 0}},
    {'>', {0, 8, 4, 2, 4, 8, 0}}, {'@', {14, 17, 23, 21, 23, 16, 14}}, {'$', {4, 15, 20, 14, 5, 30, 4}},
    {'|', {4, 4, 4, 4, 4, 4, 4}}, {'[', {6, 4, 4, 4, 4, 4, 6}}, {']', {12, 4, 4, 4, 4, 4, 12}},
    {'~', {0, 0, 8, 21, 2, 0, 0}},
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

/** What the robot is saying, in a box with a tail down to its antenna, where the words
 *  at the top usually are (on the Mac, too, the level steps back while it speaks).
 *  Pixel-style like the Mac's: notched corners, a 3-pixel border in the bubble's colour. */
inline void drawBubble(Band &b, const State &s, const Moment &m) {
  const uint16_t paper = rgb(0x0b0f15), ink2 = rgb(0xaab3c1);
  uint16_t ground = GROUND[s.look];
  uint16_t line = m.kind == 'w' ? rgb(0xffd25e) : m.kind == 'b' ? rgb(0x4fc9a4) : ACCENT[s.look];
  bandRect(b, 0, b.y0, W, b.rows, ground);

  const int x = 2, y = 0, w = W - 4, h = 102, k = 3;   // k: the border, one art pixel
  bandRect(b, x + k, y, w - 2 * k, k, line);
  bandRect(b, x + k, y + h - k, w - 2 * k, k, line);
  bandRect(b, x, y + k, k, h - 2 * k, line);
  bandRect(b, x + w - k, y + k, k, h - 2 * k, line);
  bandRect(b, x + k, y + k, w - 2 * k, h - 2 * k, paper);
  // the tail, stepping down to the robot's antenna below (art x 45 is display x 135)
  const int tip = ROBOT_X * PX;             // the middle of the antenna's bulb
  bandRect(b, tip - 6, y + h, 12, 3, line);
  bandRect(b, tip - 3, y + h + 3, 6, 3, line);

  // Title, then up to four lines (the first brighter), centred in the box from top to bottom.
  const int scale = 2, pitch = 7 * scale + 4, inner = h - 2 * k;
  int n = m.count < 0 ? 0 : m.count > 4 ? 4 : m.count;
  int content = 7 * scale + (n ? 6 + n * pitch - 4 : 0);
  int ty = y + k + (inner - content) / 2, tx = x + k + 7, room = w - 2 * k - 14;
  int gap = textWidth(m.title, scale) <= room ? scale : 1;
  bandText(b, tx, ty, m.title, scale, line, gap);
  for (int i = 0; i < n; i++) {
    int lg = textWidth(m.lines[i], scale) <= room ? scale : 1;
    bandText(b, tx, ty + 7 * scale + 6 + i * pitch, m.lines[i], scale, i < m.head ? INK : ink2, lg);
  }
}

/** The top of the screen: which level, its name, the token burn, and how far up the intensity scale,
 *  or what the robot is saying when it says something. */
inline void drawHud(Band &b, const State &s, bool waiting, const Moment &m) {
  if (!waiting && m.on) {
    drawBubble(b, s, m);
    return;
  }
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

inline void rect(Art fb, float fx, float fy, int w, int h, uint16_t c, int a = 255) {
  int x = (int)lroundf(fx), y = (int)lroundf(fy);
  int x1 = x + w > fb.w ? fb.w : x + w, y1 = y + h > fb.h ? fb.h : y + h;
  if (x < 0) x = 0;
  if (y < 0) y = 0;
  for (int yy = y; yy < y1; yy++) {
    uint16_t *row = fb.px + yy * fb.w;
    for (int xx = x; xx < x1; xx++) row[xx] = a >= 255 ? c : mix(row[xx], c, a);
  }
}

/** The robot, standing with its feet at (cx, gy): steel grey, with a face that glows in the level's colour.
 *  The same drawing as on the Mac, look for look; `expr` is a reaction over the face (Expr). */
inline void robot(Art fb, int cx, int gy, int look, float t, int expr = EX_NONE) {
  bool asleep = look == ASLEEP && expr == EX_NONE, idle = look == IDLE, locked = look == LOCKED, over = look == OVERDRIVE, autop = look == AUTOPILOT;
  bool working = look == WARMING || look == CRUISING || locked || over;
  uint16_t accent = ACCENT[look];
  uint16_t body = rgb(0xa3b0c2), hi = rgb(0xd2dae5), sh = rgb(0x75839a), dark = rgb(0x4d586b);
  if (asleep) { body = rgb(0x5f6878); hi = rgb(0x757f90); sh = rgb(0x4a5261); dark = rgb(0x353b47); }
  const uint16_t screen = rgb(0x0e131b), white = rgb(0xffffff);
  const uint16_t glow = asleep ? rgb(0x7c869b) : mix(accent, white, over ? 191 : 115);
#define R(x, y, w, h, c) rect(fb, (float)(x), (float)(y), w, h, c)

  float pace = asleep ? 1.1f : idle ? 1.7f : autop ? 2.0f : look == WARMING ? 3.0f : look == CRUISING ? 4.2f : locked ? 6.0f : 9.0f;
  int bob = sinf(t * pace) > 0.35f ? 1 : 0;
  bool bored = expr == EX_BORED;
  int x0 = cx + (over ? (int)lroundf(sinf(t * 41)) : 0) + (autop || bored ? (int)lroundf(sinf(t * (bored ? 0.8f : 1.3f))) : 0);
  int hy = gy - 43 + bob + (asleep ? 2 : 0);   // top of the head

  // legs and feet
  R(x0 - 9, gy - 5, 5, 5, sh);
  R(x0 + 4, gy - 5, 5, 5, sh);
  R(x0 - 10, gy - 2, 7, 2, dark);
  R(x0 + 3, gy - 2, 7, 2, dark);

  // arms: resting at the sides, or raised and tapping while working
  float tapHz = look == WARMING ? 3 : look == CRUISING ? 6 : locked ? 10 : 15;
  int beat = (int)floorf(t * tapHz);
  if (expr == EX_HAPPY) {
    // both arms thrown up, waving out of step
    int wl = (int)floorf(t * 5) % 2, wr = (int)floorf(t * 5 + 1) % 2;
    R(x0 - 15, gy - 20, 4, 3, sh);
    R(x0 - 18, gy - 23, 4, 3, sh);
    R(x0 - 21, gy - 26 - wl, 4, 3, body);
    R(x0 - 22, gy - 29 - wl, 5, 3, hi);
    R(x0 + 11, gy - 20, 4, 3, sh);
    R(x0 + 14, gy - 23, 4, 3, sh);
    R(x0 + 17, gy - 26 - wr, 4, 3, body);
    R(x0 + 17, gy - 29 - wr, 5, 3, hi);
  } else if (working && !bored) {
    int l = beat % 2 ? 0 : 2, r = beat % 2 ? 2 : 0;
    R(x0 - 15, gy - 18, 4, 6, sh);
    R(x0 + 11, gy - 18, 4, 6, sh);
    R(x0 - 17, gy - 13 + l, 5, 4, body);
    R(x0 + 12, gy - 13 + r, 5, 4, body);
    R(x0 - 17, gy - 10 + l, 5, 2, hi);
    R(x0 + 12, gy - 10 + r, 5, 2, hi);
    int sx = beat % 2 ? x0 + 13 : x0 - 16;   // key sparks under the hand that just came down
    R(sx + (beat * 7) % 4, gy - 6, 1, 1, white);
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
    R(x0 - 5 + k * 4, gy - 10 - h, 2, h, asleep ? rgb(0x4f5868) : accent);
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
  int ey = hy + 7, lx = x0 - 8, rx = x0 + 4;
  static const int LOOKS[6] = {-1, 0, 0, 1, 0, 0};
  int glance = idle ? LOOKS[(int)floorf(t / 1.3f) % 6] : 0;
  bool blink = !asleep && !over && !autop && fmodf(t, locked ? 6.3f : 3.7f) < 0.13f;
  if (expr == EX_WORRIED) {
    // brows up in the middle, small eyes
    R(lx, ey - 1, 2, 1, glow);
    R(lx + 2, ey - 2, 2, 1, glow);
    R(rx, ey - 2, 2, 1, glow);
    R(rx + 2, ey - 1, 2, 1, glow);
    R(lx + 1, ey + 1, 2, 3, glow);
    R(rx + 1, ey + 1, 2, 3, glow);
  } else if (expr == EX_HAPPY) {
    int eyes[2] = {lx, rx};
    for (int ex : eyes) {
      R(ex, ey + 2, 1, 2, glow);
      R(ex + 1, ey + 1, 2, 1, glow);
      R(ex + 3, ey + 2, 1, 2, glow);
    }
  } else if (expr == EX_WAITING) {
    // wide awake, looking out at you
    if (fmodf(t, 2.9f) < 0.12f) {
      R(lx, ey + 3, 4, 1, glow);
      R(rx, ey + 3, 4, 1, glow);
    } else {
      R(lx, ey - 1, 4, 6, glow);
      R(rx, ey - 1, 4, 6, glow);
      R(lx + 1, ey + 1, 2, 2, screen);
      R(rx + 1, ey + 1, 2, 2, screen);
    }
  } else if (expr == EX_PUZZLED) {
    // left brow up, right eye narrowed
    R(lx, ey - 2, 4, 1, glow);
    R(lx, ey, 4, 5, glow);
    R(rx, ey + 1, 4, 1, glow);
    R(rx, ey + 2, 4, 2, glow);
  } else if (bored) {
    // half shut, looking off to the side, now and then the other way
    int away = (int)floorf(t / 3.1f) % 3 == 2 ? -1 : 1;
    R(lx + away, ey + 2, 4, 1, sh);
    R(rx + away, ey + 2, 4, 1, sh);
    R(lx + away, ey + 3, 4, 2, glow);
    R(rx + away, ey + 3, 4, 2, glow);
  } else if (asleep || blink) {
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
    rect(fb, lx - 1, ey, 6, 5, accent, 76);
    rect(fb, rx - 1, ey, 6, 5, accent, 76);
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
  if (expr == EX_WORRIED) {
    for (int k = 0; k < 4; k++) R(x0 - 4 + k * 2, my - (k % 2), 2, 1, glow);
  } else if (expr == EX_HAPPY) {
    R(x0 - 5, my - 2, 1, 1, glow);
    R(x0 + 4, my - 2, 1, 1, glow);
    R(x0 - 4, my - 1, 8, 1, white);
    R(x0 - 3, my, 6, 1, glow);
  } else if (expr == EX_WAITING) R(x0 - 1, my - 1, 2, 2, glow);
  else if (expr == EX_PUZZLED) {
    R(x0 - 2, my, 4, 1, glow);
    R(x0 + 2, my - 1, 2, 1, glow);
  } else if (bored) R(x0 - 3, my, 6, 1, glow);
  else if (asleep) R(x0 - 1, my, 2, 1, glow);
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
    R(x0 - 1, hy - 8, 2, 3, accent);
    R(x0 - w / 2.0f, hy - 8, w, 1, glow);
  } else {
    uint16_t bulb = rgb(0x4a5362);
    if (idle) bulb = sinf(t * 1.6f) > 0.6f ? accent : rgb(0x4f5a6c);
    else if (working) bulb = (locked || over || beat % 2) ? accent : rgb(0x566173);
    if (locked || over) rect(fb, x0 - 4, hy - 11, 8, 8, accent, (int)(255 * (0.25f + 0.15f * sinf(t * 5))));
    R(x0 - 2, hy - 9, 4, 4, bulb);
    if (over) R(x0 - 1, hy - 8, 2, 2, rgb(0xfff6d2));
  }

  // headphones go on when it locks in
  if (locked || over) {
    uint16_t band = rgb(0x232a36), cup = rgb(0x303a49);
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
    // smoke puffing out of its ears, as public/robot.js draws it: each puff drifts out and up and
    // grows as it fades, three to an ear, the ears out of step
    static const uint32_t SMOKE[3] = {0xd6dde8, 0xa3adbd, 0x6b7484};
    for (int side = -1; side <= 1; side += 2) {
      int ear = side < 0 ? x0 - 21 : x0 + 20;   // just outside the cup
      for (int k = 0; k < 3; k++) {
        float p = fmodf(t / 1.4f + k / 3.0f + (side > 0 ? 1 / 6.0f : 0), 1);
        int size = 1 + (int)floorf(p * 3);
        int x = ear + side * (int)lroundf(1 + p * 4 + sinf(p * 6 + k)) - (side < 0 ? size - 1 : 0);
        R(x, hy + 11 - (int)lroundf(p * 12) - size + 1, size, size, rgb(SMOKE[size - 1]));
      }
    }
  }

  // reactions that reach past the face
  if (expr == EX_WORRIED) {
    // a bead of sweat sliding down the side of the head
    int s = (int)floorf(fmodf(t * 2.5f, 5));
    R(x0 + 13, hy + 2 + s, 1, 1, rgb(0xbfe3ff));
    R(x0 + 12, hy + 3 + s, 3, 2, rgb(0x8cc8f5));
  } else if (expr == EX_HAPPY) {
    static const int SX[4] = {-24, 21, -19, 25}, SY[4] = {-6, -9, 4, 2};
    for (int k = 0; k < 4; k++) {
      if ((int)floorf(t * 6 + k * 1.7f) % 3 == 0) continue;
      uint16_t c = k % 2 ? rgb(0xfff6d2) : accent;
      R(x0 + SX[k], hy + SY[k] - 1, 1, 3, c);
      R(x0 + SX[k] - 1, hy + SY[k], 3, 1, c);
    }
  } else if (expr == EX_WAITING) {
    // "!" over its shoulder, pulsing (a row lower than on the Mac: the scene starts right above)
    if (fmodf(t, 1.2f) < 0.85f) {
      R(x0 + 19, hy - 11, 2, 5, rgb(0xffd25e));
      R(x0 + 19, hy - 5, 2, 2, rgb(0xffd25e));
    }
  } else if (expr == EX_PUZZLED) {
    // "?" over its shoulder, bobbing
    int bx = x0 + 18, by = hy - 11 + (int)floorf(t * 1.6f) % 2;
    uint16_t q = rgb(0xc5cde4);
    R(bx + 1, by, 2, 1, q);
    R(bx, by + 1, 1, 1, q);
    R(bx + 3, by + 1, 1, 2, q);
    R(bx + 2, by + 3, 1, 1, q);
    R(bx + 1, by + 4, 1, 1, q);
    R(bx + 1, by + 6, 1, 1, q);
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

// A token: a small chip that turns as it falls, so three widths of it.
const char *const TOKEN[3][3] = {
    {"xhx", "xxs", "sss"},
    {"hx", "xs", "ss"},
    {"h", "x", "s"},
};

/** The moving part of the screen: fire, falling tokens, embers, and the robot standing in them. */
struct Scene {
  int aw = AW, ah = AH;                     // its size in art pixels
  int cx = ROBOT_X, gy = 54;                // the robot's feet
  float reach = 27;                         // how high the fire can climb: to the robot's waist, never over its face
  uint8_t fire[MAX_AW * FH];
  float bump[MAX_AW];
  uint16_t palette[37];
  uint8_t soft[37];
  Drop drops[20];
  Ember embers[56];
  float flame = 0, t = 0, dropAcc = 0, emberAcc = 0, night = 0, fireAcc = 0;
  uint32_t seed = 0x2545F491;
  bool primed = false;

  /** A scene of w x h art pixels with the robot's feet `lift` rows above the bottom. The colour
   *  screen's is 80 x 71 with the feet 17 up; the Perch's OLED has one of its own. */
  Scene(int w = AW, int h = AH, int lift = AH - 54) { size(w, h, lift); }

  void size(int w, int h, int lift) {
    aw = w > MAX_AW ? MAX_AW : w;
    ah = h;
    cx = aw * ROBOT_X / AW;                 // the same place across, 45 of 80
    gy = ah - lift;
    reach = (float)(lift + 10);             // up to the waist, 10 rows above the feet
    clear();
  }

  void clear() {
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
    const int base = (FH - 1) * aw;
    for (int x = 0; x < aw; x++) {
      float lump = 0.74f + 0.26f * sinf(x * 0.23f + t * 2.3f) * sinf(x * 0.061f - t * 1.1f);
      float h = reach * flame * lump + bump[x];           // not the full 36: flames to the robot's waist, never over its face
      if (flame < 0.1f && chance() < 0.5f) h *= 0.4f;       // embers flicker
      bump[x] *= 0.9f;
      fire[base + x] = h <= 0 ? 0 : h >= 36 ? 36 : (uint8_t)h;
    }
    for (int y = 1; y < FH; y++) {
      int row = y * aw;
      for (int x = 0; x < aw; x++) {
        int v = fire[row + x];
        uint32_t r = next();
        int dx = x - (int)(r % 3) + 1;
        if (dx < 0) dx = 0;
        else if (dx >= aw) dx = aw - 1;
        int cool = ((r >> 8) & 255) < 235 ? 1 : 0;
        fire[row - aw + dx] = (uint8_t)(v > cool ? v - cool : 0);
      }
    }
  }

  void burst(float x) {
    for (int d = -4; d <= 4; d++) {
      int i = (int)lroundf(x) + d;
      if (i >= 0 && i < aw) bump[i] += 16 - abs(d) * 3;
    }
    int made = 0;
    for (Ember &e : embers) {
      if (e.on || made >= 4) continue;
      e = {x + chance() * 4 - 2, ah - 3 - chance() * 5, (chance() - 0.5f) * 16, -(18 + chance() * 26), 1, 0.8f + chance() * 1.2f, true};
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
        d = {14 + chance() * (aw - 20), -6, 14 + chance() * 18, chance() * 4, true};
        break;
      }
    }
    float surface = ah - 5 - flame * 14 * (reach / 27);
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

    emberAcc += flame * aw * 0.22f * dt;
    while (emberAcc >= 1) {
      emberAcc -= 1;
      for (Ember &e : embers) {
        if (e.on) continue;
        e = {chance() * aw, ah - 2 - chance() * flame * 26 * (reach / 27), (chance() - 0.5f) * 6, -(7 + chance() * 16), 1, 1.4f + chance() * 2.4f, true};
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

  /** Draws the scene into fb, aw x ah. */
  void draw(Art fb, const State &s, bool waiting) {
    int look = waiting ? ASLEEP : s.look;
    uint16_t ground = GROUND[look];
    for (int i = 0; i < aw * ah; i++) fb.px[i] = ground;

    // stars come out when nothing is happening
    if (night > 0.02f) {
      uint32_t h = 0x9E3779B9;
      for (int k = 0; k < 26; k++) {
        h = h * 1664525u + 1013904223u;
        int x = (h >> 8) % aw, y = (h >> 20) % (ah * 6 / 10);
        float twinkle = 0.35f + 0.65f * fabsf(sinf(t * 0.7f + k));
        rect(fb, x, y, 1, 1, rgb(0xcfd8f0), (int)(255 * night * twinkle));
      }
    }

    // locked in: slow ripples spreading out from the robot
    if (look == LOCKED || look == OVERDRIVE) {
      const float reach = 60, speed = look == OVERDRIVE ? 22.0f : 12.0f;
      for (int k = 0; k < 3; k++) {
        float r = 22 + fmodf(t * speed + k * reach / 3, reach);
        int alpha = (int)(56 * (1 - r / (reach + 22)));
        int steps = (int)(r * 5);
        for (int i = 0; i < steps; i++) {
          float a = i * 6.2831853f / steps;
          rect(fb, cx + cosf(a) * r, gy - 28 + sinf(a) * r, 1, 1, ACCENT[look], alpha);
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
      rect(fb, 3, y, 7, 6, lit ? ACCENT[level] : rgb(0x232a36), 255);
      if (here) rect(fb, 5, y + 2, 3, 2, ground, 255);
      if (!waiting && s.usual == level) rect(fb, 12, y + 2, 3, 2, INK, 255);
    }
    if (!waiting && s.level < 0) rect(fb, 3, 53, 7, 2, ACCENT[AUTOPILOT], 255);   // off the ladder

    // Today's goal, opposite the ladder: a lamp per win to go (five at most), lit green as
    // wins come in, and the streak of days that made it, above them.
    if (!waiting && s.target > 0) {
      const uint16_t green = rgb(0x4fc9a4), off = rgb(0x232a36);
      int lamps = s.target < 5 ? s.target : 5;
      int lit = s.wins >= s.target ? lamps : s.wins * lamps / s.target;
      for (int k = 0; k < lamps; k++) {
        int y = 45 - k * 8;
        rect(fb, aw - 9, y, 7, 6, k < lit ? green : off, 255);
        if (k < lit && s.wins >= s.target) rect(fb, aw - 7, y + 2, 3, 2, ground, 255);
      }
      if (s.streak > 1) {
        static const uint8_t DIGIT[10][5] = {{7,5,5,5,7},{2,6,2,2,7},{7,1,7,4,7},{7,1,7,1,7},{5,5,7,1,1},
                                             {7,4,7,1,7},{7,4,7,5,7},{7,1,2,2,2},{7,5,7,5,7},{7,5,7,1,7}};
        char text[4];
        int n = snprintf(text, sizeof(text), "%d", s.streak > 99 ? 99 : s.streak);
        int x = aw - 2 - n * 4 + 1, top = 45 - (lamps - 1) * 8 - 7;
        for (int i = 0; i < n; i++, x += 4)
          for (int r = 0; r < 5; r++)
            for (int c = 0; c < 3; c++)
              if (DIGIT[text[i] - '0'][r] & (4 >> c)) rect(fb, x + c, top + r, 1, 1, green, 255);
      }
    }

    // platform
    rect(fb, cx - 19, gy + 3, 3, ah - gy, rgb(0x10141b));
    rect(fb, cx + 16, gy + 3, 3, ah - gy, rgb(0x10141b));
    rect(fb, cx - 24, gy, 48, 3, rgb(0x1d232d));
    rect(fb, cx - 24, gy, 48, 1, rgb(0x2f3846));

    robot(fb, cx, gy, look, t, waiting ? EX_NONE : s.expr);

    // tokens
    const uint16_t white = rgb(0xffffff);
    for (const Drop &d : drops) {
      if (!d.on) continue;
      static const int FRAME[4] = {0, 1, 2, 1};
      const char *const *rows = TOKEN[FRAME[(int)d.spin % 4]];
      int w = (int)strlen(rows[0]);
      for (int r = 0; r < 3; r++)
        for (int q = 0; q < w; q++) {
          char ch = rows[r][q];
          rect(fb, lroundf(d.x) + (3 - w) / 2 + q, lroundf(d.y) + r, 1, 1, ch == 'x' ? rgb(0xdbe3ee) : ch == 'h' ? white : rgb(0x9aa9be));
        }
    }

    // fire, over the robot's feet
    for (int y = 0; y < FH; y++) {
      int ay = ah - FH + y;
      if (ay < 0) continue;
      for (int x = 0; x < aw; x++) {
        int v = fire[y * aw + x];
        if (v) fb.px[ay * aw + x] = mix(fb.px[ay * aw + x], palette[v], soft[v]);
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
