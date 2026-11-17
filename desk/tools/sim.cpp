// The desk screen without the board: the same drawing code as the firmware,
// written to a picture.
//
//   c++ -std=c++11 -O2 -I desk/burnbot_screen desk/tools/sim.cpp -o /tmp/burnbot-sim
//   /tmp/burnbot-sim out.bmp 'B|s=4|lv=4|tp=5|u=3|i=81|f=78|nm=LOCKED IN|cp=LEVEL 4 OF 5|rt=71.2M|tm=17:29' [seconds] ['M|...']
//
// The third argument is how long the scene has been running (default 6), so the
// fire has had time to rise. Pass 'wait' as the line for "Waiting for the Mac".
// A last 'M|...' line puts a speech bubble up, as the Mac's M line does; add
// ex=w, ex=h or ex=a to the B line for the robot's worried, happy or waiting face.

#include <stdio.h>

#include "render.h"

int main(int argc, char **argv) {
  if (argc < 3) {
    fprintf(stderr, "usage: sim out.bmp 'B|...' [seconds] ['M|...']\n");
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

  static bb::Scene scene;
  static uint16_t art[bb::AW * bb::AH];
  static uint16_t screen[bb::W * bb::H];
  for (float t = 0; t < seconds; t += 1 / 15.0f) scene.step(1 / 15.0f, state, waiting);
  scene.draw(art, state, waiting);

  // the words, a band at a time as the board does it
  for (int y = 0; y < bb::HUD_H; y += 36) {
    bb::Band band = {screen + y * bb::W, y, 36};
    bb::drawHud(band, state, waiting, moment);
  }
  // the scene, three times the size
  for (int y = bb::HUD_H; y < bb::H; y++)
    for (int x = 0; x < bb::W; x++) screen[y * bb::W + x] = art[((y - bb::HUD_H) / bb::PX) * bb::AW + x / bb::PX];

  FILE *out = fopen(argv[1], "wb");
  if (!out) return 1;
  const int row = bb::W * 3, size = 54 + row * bb::H;
  unsigned char head[54] = {'B', 'M'};
  auto put = [&](int at, int v) { for (int i = 0; i < 4; i++) head[at + i] = (unsigned char)(v >> (8 * i)); };
  put(2, size);
  put(10, 54);
  put(14, 40);
  put(18, bb::W);
  put(22, bb::H);
  head[26] = 1;
  head[28] = 24;
  put(34, row * bb::H);
  fwrite(head, 1, 54, out);
  for (int y = bb::H - 1; y >= 0; y--)
    for (int x = 0; x < bb::W; x++) {
      uint16_t c = screen[y * bb::W + x];
      unsigned char bgr[3] = {(unsigned char)((c & 31) * 255 / 31), (unsigned char)(((c >> 5) & 63) * 255 / 63), (unsigned char)((c >> 11) * 255 / 31)};
      fwrite(bgr, 1, 3, out);
    }
  fclose(out);
  return 0;
}
