// The Claude Pad's screen: a 2.8" ILI9341V turned on its side, 320 x 240, in colour, with the
// pad's four keys just below it.
//
// Plain C++ like render.h, which it builds on: the firmware sends these pixels to the display,
// and the simulator (tools/sim.cpp --pad) writes them to a picture.
//
// The top 62 rows are the words: the level, the clock, the level's name, the token burn and the
// intensity bar. Below them is the same scene as on the other screens (robot, ladder, fire,
// falling tokens), each art pixel two display pixels across and two down. The bottom 28 rows
// say what each key does right now, over the key it belongs to.
//
// While Claude waits for a yes, a yellow card takes the place of the words: who is asking and
// what it wants to do, and the keys read DENY and APPROVE. What the robot is saying (the M line)
// is the same kind of card, in its own colour.
#pragma once
#include "render.h"

namespace pd {

const int W = 320, H = 240;
const int TOP = 62;                         // rows of words
const int KEYS = 28;                        // the strip of key labels at the bottom
const int KY = H - KEYS;                    // where it starts
const int PX = 2;                           // display pixels per art pixel
const int AW = W / PX, AH = (KY - TOP) / PX;   // the scene: 160 x 75
const int LIFT = 8;                         // the robot's feet, rows above the bottom of the scene
const int COLS = 25;                        // letters across a card, at twice the size

// The pad's own fields of the B line, which other boards ignore:
//   ky=DENY,TALK,SHOW,APPROVE   what each key does now, left to right ("" for a key that does nothing)
//   pr=BASH: NPM TEST           what Claude is waiting for a yes to (absent when nothing waits); the
//                               whole request, which the Mac sends only when it fits a card; a "|" in
//                               it comes as the byte 0x7F, since "|" ends a field
//   pp=SHOP                     the project asking
struct Pad {
  char keys[4][10] = {{0}, {0}, {0}, {0}};
  char ask[112] = "";                       // four rows of COLS letters and the spaces between
  char who[20] = "";
};

inline bool parsePad(const char *line, Pad &out) {
  if (line[0] != 'B' || line[1] != '|') return false;
  Pad p;
  const char *at = line + 2;
  while (*at) {
    const char *eq = strchr(at, '=');
    if (!eq) return false;
    const char *end = strchr(eq, '|');
    if (!end) end = eq + strlen(eq);
    size_t klen = (size_t)(eq - at), vlen = (size_t)(end - eq - 1);
    const char *v = eq + 1;
    if (klen == 2 && !strncmp(at, "ky", 2)) {
      int k = 0;
      const char *from = v;
      for (const char *c = v; c <= end && k < 4; c++)
        if (c == end || *c == ',') {
          bb::copyText(p.keys[k++], sizeof(p.keys[0]), from, (size_t)(c - from));
          from = c + 1;
        }
    } else if (klen == 2 && !strncmp(at, "pr", 2)) {
      bb::copyText(p.ask, sizeof(p.ask), v, vlen);
      for (char *c = p.ask; *c; c++)
        if (*c == 0x7F) *c = '|';
    }
    else if (klen == 2 && !strncmp(at, "pp", 2)) bb::copyText(p.who, sizeof(p.who), v, vlen);
    at = *end ? end + 1 : end;
  }
  out = p;
  return true;
}

inline bool samePad(const Pad &a, const Pad &b) { return !memcmp(&a, &b, sizeof(Pad)); }

// ---------------------------------------------------------------- drawing
// A frame is W x H colours, row after row.

inline void fill(uint16_t *f, int x, int y, int w, int h, uint16_t c) {
  int x1 = x + w > W ? W : x + w, y1 = y + h > H ? H : y + h;
  if (x < 0) x = 0;
  if (y < 0) y = 0;
  for (int yy = y; yy < y1; yy++)
    for (int xx = x; xx < x1; xx++) f[yy * W + xx] = c;
}

// The 5 x 7 letters of render.h; `gap` is the space between them (one font pixel unless squeezed).
inline void text(uint16_t *f, int x, int y, const char *s, int scale, uint16_t c, int gap = -1) {
  if (gap < 0) gap = scale;
  for (int i = 0; s[i]; i++) {
    const uint8_t *rows = bb::glyph(s[i]);
    if (!rows) continue;
    for (int r = 0; r < 7; r++)
      for (int k = 0; k < 5; k++)
        if (rows[r] & (16 >> k)) fill(f, x + i * (5 * scale + gap) + k * scale, y + r * scale, scale, scale, c);
  }
}

/** Centred across x .. x + w, as large as fits: `scale`, then with the letters closer, then a size down. */
inline void fitted(uint16_t *f, int x, int w, int y, const char *s, int scale, uint16_t c) {
  int gap = scale;
  if (bb::textWidth(s, scale) > w) gap = scale > 1 ? scale / 2 : 0;
  if (bb::textWidth(s, scale, gap) > w && scale > 1) {
    scale--;
    y += 3;
    gap = bb::textWidth(s, scale) <= w ? scale : 1;
  }
  text(f, x + (w - bb::textWidth(s, scale, gap)) / 2, y, s, scale, c, gap);
}

/** Words wrapped to COLS letters, at most four rows; a word too long for a row is cut. */
inline int wrap(const char *s, char rows[4][COLS + 1]) {
  int n = 0, len = 0;
  rows[0][0] = 0;
  while (*s && n < 4) {
    while (*s == ' ') s++;
    if (!*s) break;
    int wl = 0;
    while (s[wl] && s[wl] != ' ') wl++;
    int take = wl > COLS ? COLS : wl;
    if (len && len + 1 + take > COLS) {             // the next row
      if (++n == 4) break;
      len = 0;
      rows[n][0] = 0;
    }
    if (len) rows[n][len++] = ' ';
    memcpy(rows[n] + len, s, (size_t)take);
    len += take;
    rows[n][len] = 0;
    s += wl;
  }
  return len ? n + 1 : n;
}

/** A card across the top: a border in its colour with notched corners, the title, up to four
 *  lines below it (the first `head` brighter), and a tail down to the robot's antenna at `tip`.
 *  Four lines reach row 90 and the tail row 94, just over the antenna's top. */
inline void card(uint16_t *f, const char *title, const char (*lines)[COLS + 1], int n, int head, uint16_t line, int tip) {
  const uint16_t paper = bb::rgb(0x0b0f15), ink2 = bb::rgb(0xaab3c1);
  const int x = 2, y = 0, w = W - 4, k = 3;
  n = n < 0 ? 0 : n > 4 ? 4 : n;
  const int pitch = n < 4 ? 18 : 15;            // four lines only just fit above the antenna
  int h = 2 * k + 6 + 14 + (n ? 5 + n * pitch - (pitch - 14) : 0);
  fill(f, x + k, y, w - 2 * k, k, line);
  fill(f, x + k, y + h - k, w - 2 * k, k, line);
  fill(f, x, y + k, k, h - 2 * k, line);
  fill(f, x + w - k, y + k, k, h - 2 * k, line);
  fill(f, x + k, y + k, w - 2 * k, h - 2 * k, paper);
  fill(f, tip - 6, y + h, 12, 2, line);
  fill(f, tip - 3, y + h + 2, 6, 2, line);

  const int tx = x + k + 5, room = w - 2 * k - 10;
  text(f, tx, y + k + 3, title, 2, line, bb::textWidth(title, 2) <= room ? 2 : 1);
  for (int i = 0; i < n; i++)
    text(f, tx, y + k + 3 + 14 + 5 + i * pitch, lines[i], 2, i < head ? bb::INK : ink2, bb::textWidth(lines[i], 2) <= room ? 2 : 1);
}

/** Which level, the clock, the level's name, the token burn, and the intensity bar. */
inline void words(uint16_t *f, const bb::State &s, bool waiting) {
  int look = waiting ? bb::ASLEEP : s.look;
  uint16_t ground = bb::GROUND[look], accent = bb::ACCENT[look];
  fill(f, 0, 0, W, TOP, ground);
  if (waiting) {
    fitted(f, 0, W, 24, "WAITING FOR THE MAC", 2, bb::DIM);
    return;
  }
  text(f, 8, 6, s.caption, 2, accent);
  int cw = bb::textWidth(s.clock, 2);
  if (8 + bb::textWidth(s.caption, 2) + 14 + cw + 8 <= W) text(f, W - 8 - cw, 6, s.clock, 2, bb::DIM);

  // The name on the left, as large as fits beside the burn on the right.
  const char *unit = "TOKENS/H";
  int rw = bb::textWidth(s.rate, 3), uw = bb::textWidth(unit, 1);
  int right = (rw > uw ? rw : uw), rx = W - 8 - right;
  text(f, rx + right - rw, 24, s.rate, 3, bb::INK);
  text(f, rx + right - uw, 24 + 21 + 2, unit, 1, bb::DIM);
  int room = rx - 8 - 12;
  if (bb::textWidth(s.name, 3) <= room) text(f, 8, 26, s.name, 3, accent);
  else if (bb::textWidth(s.name, 3, 1) <= room) text(f, 8, 26, s.name, 3, accent, 1);
  else text(f, 8, 30, s.name, 2, accent, bb::textWidth(s.name, 2) <= room ? 2 : 1);

  // Intensity, with a notch where each level above warming up begins.
  const int bx = 8, bw = W - 16, by = 56, bh = 3;
  fill(f, bx, by, bw, bh, bb::mix(ground, accent, 46));
  fill(f, bx, by, bw * s.intensity / 100, bh, accent);
  for (int k = 0; k < 3; k++) fill(f, bx + bw * s.cuts[k] / 100 - 1, by - 2, 2, bh + 4, ground);
}

/** What each key does, over the key: lit while it is held down. */
inline void keys(uint16_t *f, const Pad &p, const bb::State &s, bool waiting, bool asking, const bool *down) {
  const uint16_t under = bb::rgb(0x0b0f15);
  fill(f, 0, KY, W, KEYS, under);
  const int cw = W / 4;
  for (int i = 0; i < 4; i++) {
    int x = i * cw + 1, w = cw - 2, y = KY + 3, h = KEYS - 6;
    uint16_t c = waiting ? bb::DIM : bb::ACCENT[s.look];
    if (asking && i == 0) c = bb::rgb(0xff6b5e);
    if (asking && i == 3) c = bb::rgb(0x4fc9a4);
    bool held = down && down[i];
    if (!p.keys[i][0]) {                            // a key that does nothing now: a dim slot
      fill(f, x, y + h - 3, w, 2, held ? bb::DIM : bb::mix(under, bb::DIM, 70));
      continue;
    }
    fill(f, x, y, w, h, held ? c : bb::mix(under, c, 36));
    fitted(f, x + 1, w - 2, y + (h - 14) / 2, p.keys[i], 2, held ? under : c);
  }
}

/** The whole frame: the scene (already drawn by render.h into `art`), then the words or a card,
 *  then the keys. `tip`: the robot's column in the scene, for a card's tail. `down`: which keys
 *  are held (or null). */
inline void draw(uint16_t *f, const uint16_t *art, const bb::State &s, bool waiting, const bb::Moment &m, const Pad &p,
                 int tip, const bool *down) {
  for (int y = 0; y < AH; y++) {
    uint16_t *row = f + (TOP + y * PX) * W;
    const uint16_t *from = art + y * AW;
    for (int x = 0; x < AW; x++) row[2 * x] = row[2 * x + 1] = from[x];
    memcpy(row + W, row, W * sizeof(uint16_t));
  }
  bool asking = !waiting && p.ask[0];
  words(f, s, waiting);
  tip = tip * PX + 1;
  if (asking) {
    char rows[4][COLS + 1];
    int n = wrap(p.ask, rows);
    char title[32];
    snprintf(title, sizeof(title), "%s ASKS", p.who[0] ? p.who : "CLAUDE");
    card(f, title, rows, n, n, bb::rgb(0xffd25e), tip);
  } else if (!waiting && m.on) {
    char rows[4][COLS + 1];
    int n = m.count < 0 ? 0 : m.count > 4 ? 4 : m.count;
    for (int i = 0; i < n; i++) bb::copyText(rows[i], sizeof(rows[i]), m.lines[i], strlen(m.lines[i]));
    uint16_t line = m.kind == 'w' ? bb::rgb(0xffd25e) : m.kind == 'b' ? bb::rgb(0x4fc9a4) : bb::ACCENT[s.look];
    card(f, m.title, rows, n, m.head, line, tip);
  }
  keys(f, p, s, waiting, asking, down);
}

}  // namespace pd
