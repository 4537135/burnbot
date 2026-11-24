// The desk screen without the board: the same drawing code as the firmware,
// written to a picture.
//
//   c++ -std=c++11 -O2 -I desk/burnbot_screen desk/tools/sim.cpp -o /tmp/burnbot-sim
//   /tmp/burnbot-sim out.bmp 'B|s=4|lv=4|tp=5|u=3|i=81|f=78|nm=LOCKED IN|cp=LEVEL 4 OF 5|rt=71.2M|tm=17:29' [seconds] ['M|...']
//   /tmp/burnbot-sim --perch out.bmp 'B|...' [seconds] ['M|...']
//   /tmp/burnbot-sim --pad out.bmp 'B|...|ky=DENY,TALK,SHOW,APPROVE|pr=BASH: NPM TEST|pp=SHOP' [seconds] ['M|...']
//   /tmp/burnbot-sim --pad out.bmp 'B|...|wk=42' --page=home|usage|today ['U|h=46|hr=IN 2H|...'] ['D|b=..|fm=..']
//
// The third argument is how long the scene has been running (default 6), so the
// fire has had time to rise. Pass 'wait' as the line for "Waiting for the Mac".
// A last 'M|...' line puts a speech bubble up, as the Mac's M line does; add
// ex=w, ex=h or ex=a to the B line for the robot's worried, happy or waiting face.
//
// --perch draws the Desk Buddy Perch's one-colour OLED instead (perch.h), four times
// the size, white on black, with the rows the case hides shown dimmed below.
// --pad draws the Claude Pad's 320 x 240 colour screen (pad.h), twice the size. Add k1 to k4
// after the line's seconds (as in 6k4) to show that key held down. It also takes, in any order
// after the B line:
//   'S|m=q|t=...'      a screen the Mac chooses (version 5)
//   --rec=LEVEL,SECS   listening, as loud as LEVEL (0 to 100), SECS seconds in
//   --cal=STEP[,NOTE]  touch setup at cross STEP (0 to 4, 5 done), with NOTE under it
//   --hits             the places a finger may tap, outlined in magenta

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
  float seconds = 6;
  const char *held = nullptr, *screenLine = nullptr, *rec = nullptr, *cal = nullptr, *usageLine = nullptr,
             *todayLine = nullptr, *pageName = "home";
  bool showHits = false;
  bb::Moment moment;
  for (int i = 3; i < argc; i++) {
    const char *a = argv[i];
    if (!strncmp(a, "M|", 2)) {
      if (!bb::parseMoment(a, moment)) {
        fprintf(stderr, "could not read the M line\n");
        return 1;
      }
    } else if (!strncmp(a, "S|", 2)) screenLine = a;
    else if (!strncmp(a, "U|", 2)) usageLine = a;
    else if (!strncmp(a, "D|", 2)) todayLine = a;
    else if (!strncmp(a, "--page=", 7)) pageName = a + 7;
    else if (!strncmp(a, "--rec=", 6)) rec = a + 6;
    else if (!strncmp(a, "--cal=", 6)) cal = a + 6;
    else if (!strcmp(a, "--hits")) showHits = true;
    else {
      seconds = (float)atof(a);
      held = strchr(a, 'k');
    }
  }

  if (pad) {
    pd::Pad keys;
    if (!waiting) pd::parsePad(argv[2], keys);
    else strcpy(keys.keys[0], "");
    bool down[4] = {false, false, false, false};
    if (held && held[1] >= '1' && held[1] <= '4') down[held[1] - '1'] = true;
    static pd::Screen screen;
    if (screenLine && !pd::parseScreen(screenLine, screen)) {
      fprintf(stderr, "could not read the S line\n");
      return 1;
    }
    static pd::Live live;
    live.ms = (uint32_t)(seconds * 1000);
    if (rec) {
      live.recording = true;
      int level = atoi(rec);
      const char *comma = strchr(rec, ',');
      live.seconds = comma ? atoi(comma + 1) : 3;
      for (int i = 0; i < 40; i++) {           // a voice: louder and quieter, a gap now and then
        int v = level * (40 + (i * 37 % 61)) / 100;
        live.level[i] = (uint8_t)(i % 13 < 2 ? v / 6 : v);
      }
    }
    if (cal) {
      live.calStep = atoi(cal);
      const char *comma = strchr(cal, ',');
      if (comma) snprintf(live.note, sizeof(live.note), "%s", comma + 1);
      const int t[5][2] = {{30, 30}, {290, 30}, {290, 210}, {30, 210}, {160, 120}};
      memcpy(live.targets, t, sizeof(t));
    }
    // Version 6 pages: home, usage, today
    int page = !strcmp(pageName, "usage") ? pd::USAGE : !strcmp(pageName, "today") ? pd::TODAY : pd::HOME;
    static pd::Usage usage;
    static pd::Today today;
    if ((usageLine && !pd::parseUsage(usageLine, usage)) || (todayLine && !pd::parseToday(todayLine, today))) {
      fprintf(stderr, "could not read the U or D line\n");
      return 1;
    }
    static pd::Hits hits;
    static bb::Scene scene(pd::AW, pd::AH, pd::LIFT);
    pd::homeScene(scene);
    static uint16_t art[pd::AW * pd::AH];
    static uint16_t frame[pd::W * pd::H];
    for (float t = 0; t < seconds; t += 1 / 15.0f) scene.step(1 / 15.0f, state, waiting);
    scene.draw({art, pd::AW, pd::AH}, state, waiting);
    pd::draw(frame, art, state, waiting, moment, keys, scene.cx, down, screenLine ? &screen : nullptr, &live, &hits,
             page, &usage, &today);
    if (showHits)
      for (int i = 0; i < hits.n; i++) {
        const pd::Hits::Zone &z = hits.zone[i];
        const uint16_t magenta = bb::rgb(0xff3df5);
        pd::fill(frame, z.x0, z.y0, z.x1 - z.x0, 1, magenta);
        pd::fill(frame, z.x0, z.y1 - 1, z.x1 - z.x0, 1, magenta);
        pd::fill(frame, z.x0, z.y0, 1, z.y1 - z.y0, magenta);
        pd::fill(frame, z.x1 - 1, z.y0, 1, z.y1 - z.y0, magenta);
      }
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
