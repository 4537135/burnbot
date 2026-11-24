// The desk screen without the board: the same drawing code as the firmware,
// written to a picture.
//
//   c++ -std=c++11 -O2 -I desk/burnbot_screen desk/tools/sim.cpp -o /tmp/burnbot-sim
//   /tmp/burnbot-sim out.bmp 'B|s=4|lv=4|tp=5|u=3|i=81|f=78|nm=LOCKED IN|cp=LEVEL 4 OF 5|rt=71.2M|tm=17:29' [seconds] ['M|...']
//   /tmp/burnbot-sim --perch out.bmp 'B|...' [seconds] ['M|...']
//   /tmp/burnbot-sim --pad out.bmp 'B|...|ky=DENY,TALK,SHOW,APPROVE|pr=BASH: NPM TEST|pp=SHOP' [seconds] ['M|...']
//
// The third argument is how long the scene has been running (default 6), so the
// fire has had time to rise. Pass 'wait' as the line for "Waiting for the Mac".
// A last 'M|...' line puts a speech bubble up, as the Mac's M line does; add
// ex=w, ex=h or ex=a to the B line for the robot's worried, happy or waiting face.
//
// --perch draws the Desk Buddy Perch's one-colour OLED instead (perch.h), four times
// the size, white on black, with the rows the case hides shown dimmed below.
// --pad draws the Claude Pad's 320 x 240 colour screen (pad.h), twice the size. Add k1 to k4
// after the line's seconds (as in 6k4) to show that key held down.

#include <stdio.h>

#include "perch.h"
#include "pad.h"

static bool writeBmp(const char *path, const uint16_t *px, int w, int h) {
  FILE *out = fopen(path, "wb");
  if (!out) return false;
  const int row = (w * 3 + 3) & ~3, size = 54 + row * h;
  unsigned char head[54] = {'B', 'M'};
  auto put = [&](int at, int v) { for (int i = 0; i < 4; i++) head[at + i] = (unsigned char)(v >> (8 * i)); };
  put(2, size);
  put(10, 54);
  put(14, 40);
  put(18, w);
  put(22, h);
  head[26] = 1;
  head[28] = 24;
  put(34, row * h);
  fwrite(head, 1, 54, out);
  unsigned char pad[3] = {0, 0, 0};
  for (int y = h - 1; y >= 0; y--) {
    for (int x = 0; x < w; x++) {
      uint16_t c = px[y * w + x];
      unsigned char bgr[3] = {(unsigned char)((c & 31) * 255 / 31), (unsigned char)(((c >> 5) & 63) * 255 / 63), (unsigned char)((c >> 11) * 255 / 31)};
      fwrite(bgr, 1, 3, out);
    }
    fwrite(pad, 1, row - w * 3, out);
  }
  fclose(out);
  return true;
}

int main(int argc, char **argv) {
  bool perch = argc > 1 && !strcmp(argv[1], "--perch");
  bool pad = argc > 1 && !strcmp(argv[1], "--pad");
  if (perch || pad) {
    argv++;
    argc--;
  }
  if (argc < 3) {
    fprintf(stderr, "usage: sim [--perch|--pad] out.bmp 'B|...' [seconds] ['M|...']\n");
    return 2;
  }
  bb::State state;
  bool waiting = !strcmp(argv[2], "wait");
  if (!waiting && !bb::parse(argv[2], state)) {
    fprintf(stderr, "could not read the line\n");
    return 1;
  }
  float seconds = argc > 3 ? (float)atof(argv[3]) : 6;
  bb::Moment moment;
  if (argc > 4 && !bb::parseMoment(argv[4], moment)) {
    fprintf(stderr, "could not read the M line\n");
    return 1;
  }

  if (pad) {
    pd::Pad keys;
    if (!waiting) pd::parsePad(argv[2], keys);
    else strcpy(keys.keys[0], "");
    bool down[4] = {false, false, false, false};
    const char *k = argc > 3 ? strchr(argv[3], 'k') : nullptr;
    if (k && k[1] >= '1' && k[1] <= '4') down[k[1] - '1'] = true;
    static bb::Scene scene(pd::AW, pd::AH, pd::LIFT);
    static uint16_t art[pd::AW * pd::AH];
    static uint16_t frame[pd::W * pd::H];
    for (float t = 0; t < seconds; t += 1 / 15.0f) scene.step(1 / 15.0f, state, waiting);
    scene.draw({art, pd::AW, pd::AH}, state, waiting);
    pd::draw(frame, art, state, waiting, moment, keys, scene.cx, down);
    // twice the size, as it looks on the glass
    const int S = 2, w = pd::W * S, h = pd::H * S;
    static uint16_t big[pd::W * 2 * pd::H * 2];
    for (int y = 0; y < h; y++)
      for (int x = 0; x < w; x++) big[y * w + x] = frame[(y / S) * pd::W + x / S];
    return writeBmp(argv[1], big, w, h) ? 0 : 1;
  }

  if (perch) {
    static bb::Scene scene(pp::AW, pp::AH, pp::LIFT);
    static uint16_t art[pp::AW * pp::AH];
    static uint8_t frame[pp::W * pp::H];
    for (float t = 0; t < seconds; t += 1 / 12.0f) scene.step(1 / 12.0f, state, waiting);
    scene.draw({art, pp::AW, pp::AH}, state, waiting);
    pp::draw(frame, art, state, waiting, moment, scene.cx);
    // four times the size, a dark line between pixels as on the glass; the hidden rows dimmed
    const int S = 4, w = pp::W * S, h = pp::OLED_H * S;
    static uint16_t big[pp::W * 4 * pp::OLED_H * 4];
    for (int y = 0; y < h; y++)
      for (int x = 0; x < w; x++) {
        int fx = x / S, fy = y / S;
        bool lit = fy < pp::H && frame[fy * pp::W + fx];
        bool edge = x % S == S - 1 || y % S == S - 1;
        big[y * w + x] = fy >= pp::H ? bb::rgb(0x101216) : lit ? (edge ? bb::rgb(0x9aa0a8) : bb::rgb(0xf2f4f7)) : bb::rgb(0x050607);
      }
    return writeBmp(argv[1], big, w, h) ? 0 : 1;
  }

  static bb::Scene scene;
  static uint16_t art[bb::AW * bb::AH];
  static uint16_t screen[bb::W * bb::H];
  for (float t = 0; t < seconds; t += 1 / 15.0f) scene.step(1 / 15.0f, state, waiting);
  scene.draw({art, bb::AW, bb::AH}, state, waiting);

  // the words, a band at a time as the board does it
  for (int y = 0; y < bb::HUD_H; y += 36) {
    bb::Band band = {screen + y * bb::W, y, 36};
    bb::drawHud(band, state, waiting, moment);
  }
  // the scene, three times the size
  for (int y = bb::HUD_H; y < bb::H; y++)
    for (int x = 0; x < bb::W; x++) screen[y * bb::W + x] = art[((y - bb::HUD_H) / bb::PX) * bb::AW + x / bb::PX];

  return writeBmp(argv[1], screen, bb::W, bb::H) ? 0 : 1;
}
