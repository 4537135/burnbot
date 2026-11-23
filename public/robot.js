// The pixel-art side of Burnbot: the robot, the fire it stands over, and the
// tokens that fall into it. Everything is drawn on a low-resolution canvas and
// scaled up with hard pixels.
//
// The robot is Burnbot's own character: steel grey, with a face that glows in
// the colour of the level you are on.

// The levels. Rename one by editing its label; recolour it by editing its colour.
// The colours run from cold to hot, like a temperature scale.
export const STATE_META = {
  asleep: { level: 0, label: 'Asleep', color: '#6f83ad', blurb: 'Nothing happening for a while' },
  idle: { level: 1, label: 'Chilling', color: '#62a8f5', blurb: 'Quiet for a few minutes' },
  warming: { level: 2, label: 'Warming up', color: '#4fc9a4', blurb: 'Working, below your usual pace' },
  cruising: { level: 3, label: 'Cooking', color: '#f4c542', blurb: 'Working at your usual pace' },
  locked: { level: 4, label: 'Locked in', color: '#ff8030', blurb: 'Well above your normal, and sustained' },
  overdrive: { level: 5, label: 'On fire', color: '#f43f6b', blurb: 'Your top gear' },
  autopilot: { level: null, label: 'Autopilot', color: '#a78bfa', blurb: 'Agents are working without you' },
};
export const STATE_ORDER = ['asleep', 'idle', 'warming', 'cruising', 'locked', 'overdrive', 'autopilot'];
/** The ladder, bottom to top. Autopilot is off it: the AI works while you are away. */
export const LADDER = ['asleep', 'idle', 'warming', 'cruising', 'locked', 'overdrive'];
/** How lively each level is: how fast the robot bobs, and how fast its furnace flickers. */
export const PACE = { asleep: 1.1, idle: 1.7, autopilot: 2, warming: 3, cruising: 4.2, locked: 6, overdrive: 9 };

/** Mixes a hex colour toward white (amount 0..1). */
function lighten(hex, amount) {
  const n = parseInt(hex.slice(1), 16);
  const mix = (c) => Math.round(c + (255 - c) * amount);
  return `rgb(${mix(n >> 16)}, ${mix((n >> 8) & 255)}, ${mix(n & 255)})`;
}

// ---------------------------------------------------------------------- robot

const SMOKE = ['#d6dde8', '#a3adbd', '#6b7484']; // a puff of smoke, young to old

/**
 * On fire: smoke puffing out of the robot's ears. Each puff leaves the cup, drifts out and up and
 * grows as it fades; three to an ear, the ears out of step. drawRobot draws it unless told
 * {smoke: false}, and returns `ears` for a caller that draws it apart (the desktop robot, so its
 * outline does not ring each puff). desk/burnbot_screen/render.h does the same.
 */
export function drawSmoke(ctx, ears, t) {
  for (const side of [-1, 1]) {
    const ear = side < 0 ? ears.x - ears.hw - 5 : ears.x + ears.hw + 4; // just outside the cup
    for (let k = 0; k < 3; k++) {
      const p = (t / 1.4 + k / 3 + (side > 0 ? 1 / 6 : 0)) % 1;
      const size = 1 + Math.floor(p * 3);
      const x = ear + side * Math.round(1 + p * 4 + Math.sin(p * 6 + k)) - (side < 0 ? size - 1 : 0);
      ctx.fillStyle = SMOKE[size - 1];
      ctx.fillRect(Math.round(x), Math.round(ears.y - Math.round(p * 12) - size + 1), size, size);
    }
  }
}

// The chest's progress bar: a dark track, a lavender fill with a lighter top row. Paler than
// Autopilot's own purple (and its furnace), so on Autopilot it still reads as the bar, not the level.
const BAR = { track: '#2a3240', fill: '#cfc4ff', top: '#ebe6ff' };

/** The chest's lights as one bar (see opt.chest in drawRobot). The track spans the 10 columns the
 *  three lights stand in, three rows high in the middle of the chest screen. */
function chestBar(R, x0, gy, { fill, step }, light) {
  if (step <= 2) {
    // the lights stop bouncing: level at three high, then flat across the middle
    for (let k = 0; k < 3; k++) R(x0 - 5 + k * 4, step === 1 ? gy - 14 : gy - 13, 2, step === 1 ? 3 : 1, light);
    return;
  }
  const half = step === 3 ? 3 : 5;
  R(x0 - half, gy - 14, 2 * half, 3, BAR.track);
  if (step >= 5 && fill > 0) {
    const n = Math.min(10, Math.round(fill));
    R(x0 - 5, gy - 14, n, 1, BAR.top);
    R(x0 - 5, gy - 13, n, 2, BAR.fill);
  }
}

/**
 * Draws the robot standing with its feet at (cx, gy). `t` is seconds; the
 * state picks the face, the posture and how fast it moves.
 *
 * expr: a reaction drawn over the level's face for a few seconds, or '' for none.
 *   worried  a run just failed: raised brows, a wobbly mouth, a bead of sweat
 *   happy    it finally passed: arms up, a grin, sparks
 *   cheer    it passed after a long fight: happy, hopping, twice the sparks
 *   smile    it passed after one quick miss: happy eyes and a small grin, nothing more
 *   wave     you are back after a long while: one arm up, waving
 *   tired    a long stretch of work: heavy lids, a small slump
 *   waiting  Claude needs a yes from you: eyes on you, a "!" over its head
 *   puzzled  you are going round: one brow up, a lopsided mouth, a "?" over its head
 *   bored    Claude handed you the turn and you wandered off: half-shut eyes looking away, a slow sway
 *
 * opt, for the desktop robot whose face turns into a screen when you point at it:
 *   head   {w, h}: the head's size (32 × 22 as a face). A bigger head grows up from the neck,
 *          so the body never moves; the frame, ear bolts, antenna, headphones and flames go with it.
 *   bezel  the frame around the screen: 4, or 2 for a thin one.
 *   face   where the face is: 'face' (as always), 'edge' (full-size eyes riding the screen's left
 *          edge, no mouth) or 'corner' (a small pair of eyes in the screen's top-left corner).
 *          glance: pixels the eyes look aside first.
 *   chest  {fill, step}: the chest's lights turn into one progress bar, while the head is a screen
 *          and there is an estimate. step 1-2 the lights level off and flatten, 3-4 the track draws
 *          in from the middle, 5 the fill shows: `fill` of its 10 pixels. Absent, the lights as ever.
 * Returns the screen and the whole head (antenna included), in canvas pixels.
 */
export function drawRobot(ctx, cx, gy, state, t, expr = '', opt = {}) {
  const asleep = state === 'asleep' && !expr;
  const idle = state === 'idle';
  const locked = state === 'locked';
  const over = state === 'overdrive';
  const auto = state === 'autopilot';
  const working = state === 'warming' || state === 'cruising' || locked || over;
  const accent = STATE_META[state].color;
  const cheer = expr === 'cheer';
  const happy = expr === 'happy' || cheer;
  const smile = expr === 'smile';
  const wave = expr === 'wave';
  const tired = expr === 'tired';
  const bored = expr === 'bored';

  let body = '#a3b0c2';
  let hi = '#d2dae5';
  let sh = '#75839a';
  let dark = '#4d586b';
  if (asleep) [body, hi, sh, dark] = ['#5f6878', '#757f90', '#4a5261', '#353b47'];
  const screen = '#0e131b';
  const glow = asleep ? '#7c869b' : lighten(accent, over ? 0.75 : 0.45);

  const R = (x, y, w, h, c) => {
    ctx.fillStyle = c;
    ctx.fillRect(Math.round(x), Math.round(y), w, h);
  };
  const glowBox = (x, y, w, h, c, a) => {
    ctx.globalAlpha = a;
    R(x, y, w, h, c);
    ctx.globalAlpha = 1;
  };

  const hw = Math.round((opt.head?.w ?? 32) / 2); // half the head's width
  const hh = opt.head?.h ?? 22;
  const big = hw > 16 || hh > 22;
  const b = opt.bezel ?? 4;
  const mode = opt.face?.mode ?? 'face';

  if (cheer && Math.floor(t * 4) % 2) gy -= 2; // hopping
  const pace = asleep || state !== 'asleep' ? PACE[state] : PACE.overdrive; // asleep but pulling a face: full speed
  const bob = Math.sin(t * pace) > 0.35 ? 1 : 0;
  const x0 = cx + (over ? Math.round(Math.sin(t * 41)) : 0) + (auto || bored ? Math.round(Math.sin(t * (bored ? 0.8 : 1.3))) : 0);
  const hy = gy - 21 - hh + bob + (asleep ? 2 : 0) + (tired ? 1 : 0); // top of the head

  // legs and feet
  R(x0 - 9, gy - 5, 5, 5, sh);
  R(x0 + 4, gy - 5, 5, 5, sh);
  R(x0 - 10, gy - 2, 7, 2, dark);
  R(x0 + 3, gy - 2, 7, 2, dark);

  // arms: resting at the sides, or raised and tapping while working
  const tapHz = state === 'warming' ? 3 : state === 'cruising' ? 6 : locked ? 10 : 15;
  const beat = Math.floor(t * tapHz);
  const armUp = (side, lift) => {
    // an arm thrown up, on the left (-1) or the right (1)
    const x = side < 0 ? x0 - 15 : x0 + 11;
    R(x, gy - 20, 4, 3, sh);
    R(x + 3 * side, gy - 23, 4, 3, sh);
    R(x + 6 * side, gy - 26 - lift, 4, 3, body);
    R(x + 6 * side - (side < 0 ? 1 : 0), gy - 29 - lift, 5, 3, hi);
  };
  const armDown = (side) => {
    const x = side < 0 ? x0 - 15 : x0 + 11;
    R(x, gy - 18, 4, 11, sh);
    R(x, gy - 9, 4, 3, hi);
  };
  if (happy) {
    // both arms thrown up, waving out of step
    armUp(-1, Math.floor(t * 5) % 2);
    armUp(1, Math.floor(t * 5 + 1) % 2);
  } else if (wave) {
    armDown(-1);
    const swing = Math.floor(t * 6) % 2;
    R(x0 + 11, gy - 20, 4, 3, sh);
    R(x0 + 14, gy - 23, 4, 3, sh);
    R(x0 + 17 + swing, gy - 26, 4, 3, body);
    R(x0 + 17 + swing * 2, gy - 29, 5, 3, hi);
  } else if (working && !bored && !tired) {
    const l = beat % 2 ? 0 : 2;
    const r = beat % 2 ? 2 : 0;
    R(x0 - 15, gy - 18, 4, 6, sh);
    R(x0 + 11, gy - 18, 4, 6, sh);
    R(x0 - 17, gy - 13 + l, 5, 4, body);
    R(x0 + 12, gy - 13 + r, 5, 4, body);
    R(x0 - 17, gy - 10 + l, 5, 2, hi);
    R(x0 + 12, gy - 10 + r, 5, 2, hi);
    // key sparks under whichever hand just came down
    const sx = beat % 2 ? x0 + 13 : x0 - 16;
    R(sx + ((beat * 7) % 4), gy - 6, 1, 1, '#ffffff');
    if (locked || over) R(sx + ((beat * 5) % 4), gy - 4, 1, 1, accent);
  } else {
    armDown(-1);
    armDown(1);
  }

  // body with a chest meter
  R(x0 - 11, gy - 19, 22, 14, body);
  R(x0 - 11, gy - 19, 22, 1, hi);
  R(x0 - 11, gy - 6, 22, 1, sh);
  R(x0 + 10, gy - 18, 1, 12, sh);
  R(x0 - 6, gy - 16, 12, 7, screen);
  if (opt.chest) chestBar(R, x0, gy, opt.chest, asleep ? '#4f5868' : accent);
  else
    for (let k = 0; k < 3; k++) {
      const h = working ? 1 + Math.floor((Math.sin(t * (5 + k * 2.3) + k * 1.7) + 1) * 2.4) : asleep ? 1 : auto ? 3 : 2;
      R(x0 - 5 + k * 4, gy - 10 - h, 2, h, asleep ? '#4f5868' : accent);
    }

  // neck and head
  R(x0 - 3, gy - 21 + bob, 6, 2, sh);
  R(x0 - hw + 1, hy, 2 * hw - 2, hh, body);
  R(x0 - hw, hy + 1, 2 * hw, hh - 2, body);
  R(x0 - hw + 1, hy, 2 * hw - 2, 1, hi);
  R(x0 - hw, hy + 1, 1, hh - 2, hi);
  R(x0 + hw - 1, hy + 1, 1, hh - 2, sh);
  R(x0 - hw + 1, hy + hh - 1, 2 * hw - 2, 1, sh);
  const boltY = hy + Math.round(hh / 2) - 3;
  R(x0 - hw - 2, boltY, 2, 6, sh);
  R(x0 + hw, boltY, 2, 6, sh);
  // the screen: chamfered corners, a frame of `b` pixels, a little more below
  const sx = x0 - hw + b;
  const sy = hy + b;
  const sw = 2 * hw - 2 * b;
  const sH = hh - b - (b >= 4 ? 5 : 3);
  R(sx + 1, sy, sw - 2, sH, screen);
  R(sx, sy + 1, sw, sH - 2, screen);
  if (big && !asleep) {
    // a stretched face is lit from inside in the level's colour
    glowBox(sx + 1, sy, sw - 2, 1, accent, 0.35);
    glowBox(sx, sy + 1, 1, sH - 2, accent, 0.2);
    glowBox(sx + sw - 1, sy + 1, 1, sH - 2, accent, 0.2);
    glowBox(sx + 1, sy + sH - 1, sw - 2, 1, accent, 0.35);
  }

  // eyes
  const blink = !asleep && !over && !auto && t % (locked ? 6.3 : 3.7) < 0.13;
  const arcs = (ex, ey) => {
    R(ex, ey + 2, 1, 2, glow);
    R(ex + 1, ey + 1, 2, 1, glow);
    R(ex + 3, ey + 2, 1, 2, glow);
  };
  if (mode === 'corner') {
    // a small pair in the top-left corner, still pulling the face it would
    const ey = sy + 2;
    for (const [i, ex] of [sx + 2, sx + 7].entries()) {
      if (happy || smile || wave || auto) {
        R(ex, ey + 1, 1, 1, glow);
        R(ex + 1, ey, 1, 1, glow);
        R(ex + 2, ey + 1, 1, 1, glow);
      } else if (asleep || blink) R(ex, ey + 2, 3, 1, glow);
      else if (expr === 'worried') {
        R(ex + (i ? 0 : 1), ey - 1 + i, 2, 1, glow);
        R(ex + 1, ey + 1, 2, 2, glow);
      } else if (expr === 'waiting') {
        R(ex, ey, 3, 3, glow);
        R(ex + 1, ey + 1, 1, 1, screen);
      } else if (expr === 'puzzled') {
        if (i === 0) {
          R(ex, ey - 1, 3, 1, glow);
          R(ex, ey + 1, 3, 2, glow);
        } else R(ex, ey + 2, 3, 1, glow);
      } else if (bored || tired) {
        R(ex, ey + 1, 3, 1, sh);
        R(ex, ey + 2, 3, 1, glow);
      } else if (locked || over) {
        R(ex, ey + 1, 3, 2, glow);
        R(ex + (i ? 0 : 2), ey + 1, 1, 1, screen);
      } else R(ex, ey, 2, 3, glow);
    }
  } else {
    const edge = mode === 'edge';
    const glance = opt.face?.glance ?? 0;
    const ey = edge ? sy + 3 : hy + 7;
    const lx = (edge ? sx + 2 : x0 - 8) + glance;
    const rx = lx + 12;
    const look = idle && !edge ? [-1, 0, 0, 1, 0, 0][Math.floor(t / 1.3) % 6] : 0;
    if (expr === 'worried') {
      // brows up in the middle, small eyes
      R(lx, ey - 1, 2, 1, glow);
      R(lx + 2, ey - 2, 2, 1, glow);
      R(rx, ey - 2, 2, 1, glow);
      R(rx + 2, ey - 1, 2, 1, glow);
      R(lx + 1, ey + 1, 2, 3, glow);
      R(rx + 1, ey + 1, 2, 3, glow);
    } else if (happy || smile || wave) {
      arcs(lx, ey);
      arcs(rx, ey);
    } else if (expr === 'waiting') {
      // wide awake, looking out at you
      R(lx, ey - 1, 4, 6, glow);
      R(rx, ey - 1, 4, 6, glow);
      R(lx + 1, ey + 1, 2, 2, screen);
      R(rx + 1, ey + 1, 2, 2, screen);
      if (t % 2.9 < 0.12) {
        R(lx, ey - 1, 4, 6, screen);
        R(rx, ey - 1, 4, 6, screen);
        R(lx, ey + 3, 4, 1, glow);
        R(rx, ey + 3, 4, 1, glow);
      }
    } else if (expr === 'puzzled') {
      // left brow up, right eye narrowed
      R(lx, ey - 2, 4, 1, glow);
      R(lx, ey, 4, 5, glow);
      R(rx, ey + 1, 4, 1, glow);
      R(rx, ey + 2, 4, 2, glow);
    } else if (bored) {
      // half shut, looking off to the side, now and then the other way
      const away = Math.floor(t / 3.1) % 3 === 2 ? -1 : 1;
      R(lx + away, ey + 2, 4, 1, sh);
      R(rx + away, ey + 2, 4, 1, sh);
      R(lx + away, ey + 3, 4, 2, glow);
      R(rx + away, ey + 3, 4, 2, glow);
    } else if (tired) {
      // heavy lids, looking straight ahead, a slow blink now and then
      const shut = t % 5.3 < 0.5;
      R(lx, ey + 1, 4, shut ? 3 : 2, sh);
      R(rx, ey + 1, 4, shut ? 3 : 2, sh);
      R(lx, ey + (shut ? 4 : 3), 4, shut ? 1 : 2, glow);
      R(rx, ey + (shut ? 4 : 3), 4, shut ? 1 : 2, glow);
    } else if (asleep || blink) {
      R(lx, ey + 4, 4, 1, glow);
      R(rx, ey + 4, 4, 1, glow);
    } else if (auto) {
      arcs(lx, ey);
      arcs(rx, ey);
    } else if (locked || over) {
      glowBox(lx - 1, ey, 6, 5, accent, 0.3);
      glowBox(rx - 1, ey, 6, 5, accent, 0.3);
      R(lx, ey + 1, 4, 3, glow);
      R(rx, ey + 1, 4, 3, glow);
      R(lx + 3, ey + 1, 1, 1, screen); // slanted inner corners: the focused look
      R(rx, ey + 1, 1, 1, screen);
      if (over) {
        for (let k = 0; k < 3; k++) {
          const up = (Math.floor(t * 14) + k) % 3;
          R(lx + ((k * 7 + Math.floor(t * 20)) % 4), ey - 1 - up, 1, 2, '#ff9a3d');
          R(rx + ((k * 5 + Math.floor(t * 17)) % 4), ey - 1 - up, 1, 2, '#ff9a3d');
        }
      }
    } else {
      R(lx + look, ey, 4, 5, glow);
      R(rx + look, ey, 4, 5, glow);
      if (state === 'cruising') {
        R(lx + look, ey, 1, 1, '#ffffff');
        R(rx + look, ey, 1, 1, '#ffffff');
      }
    }

    // mouth: only on the face itself, not while the face is moving over for a screen
    const mx = x0 + glance;
    const my = ey + 7;
    if (edge) {
      // no mouth
    } else if (expr === 'worried') {
      for (let k = 0; k < 4; k++) R(mx - 4 + k * 2, my - (k % 2), 2, 1, glow);
    } else if (happy) {
      R(mx - 5, my - 2, 1, 1, glow);
      R(mx + 4, my - 2, 1, 1, glow);
      R(mx - 4, my - 1, 8, 1, '#ffffff');
      R(mx - 3, my, 6, 1, glow);
    } else if (smile || wave) {
      R(mx - 3, my - 1, 1, 1, glow);
      R(mx - 2, my, 4, 1, glow);
      R(mx + 2, my - 1, 1, 1, glow);
    } else if (expr === 'waiting') {
      R(mx - 1, my - 1, 2, 2, glow);
    } else if (expr === 'puzzled') {
      R(mx - 2, my, 4, 1, glow);
      R(mx + 2, my - 1, 2, 1, glow);
    } else if (bored) {
      R(mx - 3, my, 6, 1, glow);
    } else if (tired) {
      R(mx - 2, my, 4, 1, glow);
    } else if (asleep) R(mx - 1, my, 2, 1, glow);
    else if (auto) {
      R(mx - 4, my - 1, 1, 1, glow);
      R(mx - 3, my, 6, 1, glow);
      R(mx + 3, my - 1, 1, 1, glow);
    } else if (over) {
      R(mx - 4, my - 1, 8, 2, '#ffffff');
      for (let k = 0; k < 3; k++) R(mx - 2 + k * 2, my - 1, 1, 2, screen);
    } else if (locked) R(mx - 3, my, 6, 1, glow);
    else if (state === 'cruising') {
      R(mx - 3, my - 1, 1, 1, glow);
      R(mx - 2, my, 4, 1, glow);
      R(mx + 2, my - 1, 1, 1, glow);
    } else R(mx - 2, my, 4, 1, glow);
  }

  // antenna
  R(x0 - 1, hy - 5, 2, 5, sh);
  if (auto) {
    const w = [9, 6, 2, 6][Math.floor(t * 12) % 4];
    R(x0 - 1, hy - 8, 2, 3, accent);
    R(x0 - w / 2, hy - 8, w, 1, glow);
  } else {
    let bulb = '#4a5362';
    if (idle) bulb = Math.sin(t * 1.6) > 0.6 ? accent : '#4f5a6c';
    else if (working) bulb = locked || over || beat % 2 ? accent : '#566173';
    if (locked || over) glowBox(x0 - 4, hy - 11, 8, 8, accent, 0.25 + 0.15 * Math.sin(t * 5));
    R(x0 - 2, hy - 9, 4, 4, bulb);
    if (over) R(x0 - 1, hy - 8, 2, 2, '#fff6d2');
  }

  // headphones go on when it locks in
  if (locked || over) {
    const band = '#232a36';
    const cup = boltY - 2;
    R(x0 - hw - 1, hy - 2, 2 * hw + 2, 2, band);
    R(x0 - hw - 2, hy - 1, 2, cup - hy + 2, band);
    R(x0 + hw, hy - 1, 2, cup - hy + 2, band);
    R(x0 - hw - 4, cup, 4, 11, '#303a49');
    R(x0 + hw, cup, 4, 11, '#303a49');
    R(x0 - hw - 4, cup + 4, 1, 3, accent);
    R(x0 + hw + 3, cup + 4, 1, 3, accent);
  }

  // on fire: the head is burning, all the way along its top
  if (over) {
    const n = Math.max(6, Math.round((2 * hw) / 5.3));
    for (let k = 0; k < n; k++) {
      const fx = x0 - hw + 3 + k * 5 + Math.round(Math.sin(t * 9 + k));
      const fh = 3 + Math.floor((Math.sin(t * 13 + k * 2.1) + 1) * 2.4);
      R(fx, hy - fh, 2, fh, '#ff8a2e');
      if (fh > 4) R(fx, hy - fh + 2, 1, fh - 3, '#ffe08a');
    }
  }

  // on fire: smoke out of its ears (see drawSmoke)
  const ears = over ? { x: x0, hw, y: boltY + 3 } : null;
  if (ears && opt.smoke !== false) drawSmoke(ctx, ears, t);

  // reactions that reach past the face
  const out = hw - 16; // how much wider than usual the head is
  if (expr === 'worried') {
    // a bead of sweat sliding down the side of the head
    const s = Math.floor((t * 2.5) % 5);
    R(x0 + hw - 3, hy + 2 + s, 1, 1, '#bfe3ff');
    R(x0 + hw - 4, hy + 3 + s, 3, 2, '#8cc8f5');
  } else if (happy) {
    const n = cheer ? 8 : 4;
    for (let k = 0; k < n; k++) {
      if (Math.floor(t * 6 + k * 1.7) % 3 === 0) continue;
      const left = [-24, 21, -19, 25, -28, 29, -14, 15][k] < 0;
      const sx = x0 + [-24, 21, -19, 25, -28, 29, -14, 15][k] + (left ? -out : out);
      const sy = hy + [-6, -9, 4, 2, -13, -3, -12, -14][k];
      const c = k % 2 ? '#fff6d2' : accent;
      R(sx, sy - 1, 1, 3, c);
      R(sx - 1, sy, 3, 1, c);
    }
  } else if (expr === 'waiting') {
    // "!" over its head, pulsing
    if (t % 1.2 < 0.85) {
      const bx = x0 + hw + 3;
      const by = hy - 12;
      R(bx, by, 2, 5, '#ffd25e');
      R(bx, by + 6, 2, 2, '#ffd25e');
    }
  } else if (expr === 'puzzled') {
    // "?" over its head, bobbing
    const bx = x0 + hw + 2;
    const by = hy - 13 + (Math.floor(t * 1.6) % 2);
    const q = '#c5cde4';
    R(bx + 1, by, 2, 1, q);
    R(bx, by + 1, 1, 1, q);
    R(bx + 3, by + 1, 1, 2, q);
    R(bx + 2, by + 3, 1, 1, q);
    R(bx + 1, by + 4, 1, 1, q);
    R(bx + 1, by + 6, 1, 1, q);
  }

  // asleep: z z z
  if (asleep) {
    for (let k = 0; k < 3; k++) {
      const p = (t * 0.32 + k / 3) % 1;
      const zx = x0 + hw + p * 12;
      const zy = hy - 2 - p * 18;
      const large = p > 0.5;
      ctx.globalAlpha = Math.min(1, (1 - p) * 1.6);
      const w = large ? 4 : 3;
      R(zx, zy, w, 1, '#c5cde4');
      for (let d = 1; d < w - 1; d++) R(zx + w - 1 - d, zy + d, 1, 1, '#c5cde4');
      R(zx, zy + w - 1, w, 1, '#c5cde4');
      ctx.globalAlpha = 1;
    }
  }

  return {
    screen: { x: sx, y: sy, w: sw, h: sH },
    head: { x: x0 - hw - (locked || over ? 4 : 2), y: hy - 9, w: 2 * hw + (locked || over ? 8 : 4), h: hh + 9 },
    ears, // where smoke comes out, at On fire (for drawSmoke, when the caller draws it itself)
  };
}

/** The app's logo is the robot's head, so it changes with the level too. */
export function drawLogo(canvas, state, t = 0.5) {
  if (canvas.width !== 42) canvas.width = 42;
  if (canvas.height !== 36) canvas.height = 36;
  const ctx = canvas.getContext('2d');
  ctx.clearRect(0, 0, 42, 36);
  drawRobot(ctx, 21, 55, state, t, '', { smoke: false }); // too small for smoke
}

// ---------------------------------------------------------------------- scene

function firePalette() {
  // heat 0..36 -> rgba. 0 is empty; low heat is translucent so flame edges stay soft.
  const stops = [
    [0, 40, 6, 4],
    [6, 128, 22, 8],
    [14, 214, 70, 18],
    [22, 247, 138, 36],
    [30, 255, 204, 92],
    [36, 255, 247, 214],
  ];
  const pal = new Uint8ClampedArray(37 * 4);
  for (let i = 1; i <= 36; i++) {
    let k = 0;
    while (stops[k + 1][0] < i) k++;
    const [a, b] = [stops[k], stops[k + 1]];
    const f = (i - a[0]) / (b[0] - a[0]);
    for (let c = 0; c < 3; c++) pal[i * 4 + c] = a[c + 1] + (b[c + 1] - a[c + 1]) * f;
    pal[i * 4 + 3] = i < 4 ? i * 62 : 255;
  }
  return pal;
}

const PALETTE = firePalette();

/** A strip of pixel fire, burning up from its bottom row. The robot's scene has one across the
 *  whole screen; the desktop robot has a small one at its feet. */
export class Fire {
  constructor(W, H) {
    this.W = W;
    this.H = H;
    this.cells = new Uint8Array(W * H);
    this.bump = new Float32Array(W);
    this.canvas = document.createElement('canvas');
    this.canvas.width = W;
    this.canvas.height = H;
    this.ctx = this.canvas.getContext('2d');
    this.img = this.ctx.createImageData(W, H);
  }

  /** One step (they come 30 a second). level 0..1; room(x), if given, how high column x may burn (0..1). */
  step(level, t, room) {
    const { W, H, cells, bump } = this;
    const base = (H - 1) * W;
    for (let x = 0; x < W; x++) {
      const lump = 0.74 + 0.26 * Math.sin(x * 0.23 + t * 2.3) * Math.sin(x * 0.061 - t * 1.1);
      const r = room ? room(x) : 1;
      let h = 36 * level * lump * r + bump[x] * r;
      if (level < 0.1 && Math.random() < 0.5) h *= 0.4; // embers flicker
      bump[x] *= 0.9;
      cells[base + x] = h <= 0 ? 0 : h >= 36 ? 36 : h;
    }
    for (let y = 1; y < H; y++) {
      const row = y * W;
      for (let x = 0; x < W; x++) {
        const v = cells[row + x];
        const r = (Math.random() * 3) | 0;
        let dx = x - r + 1;
        if (dx < 0) dx = 0;
        else if (dx >= W) dx = W - 1;
        const cool = Math.random() < 0.85 ? 1 : 0;
        cells[row - W + dx] = v > cool ? v - cool : 0;
      }
    }
  }

  /** A flare-up around column x. */
  burst(x) {
    for (let d = -4; d <= 4; d++) {
      const i = Math.round(x) + d;
      if (i >= 0 && i < this.W) this.bump[i] += 16 - Math.abs(d) * 3;
    }
  }

  draw(ctx, x, y) {
    const { cells } = this;
    const data = this.img.data;
    for (let i = 0; i < cells.length; i++) {
      const p = cells[i] * 4;
      const o = i * 4;
      data[o] = PALETTE[p];
      data[o + 1] = PALETTE[p + 1];
      data[o + 2] = PALETTE[p + 2];
      data[o + 3] = PALETTE[p + 3];
    }
    this.ctx.putImageData(this.img, 0, 0);
    ctx.drawImage(this.canvas, x, y);
  }
}

// ---------------------------------------------------------------------- furnace

// The furnace in the head-as-a-screen: how hard you are going, as a fire. Dark stone, an arched
// opening, a grate, and a flame drawn a pixel at a time: at 6 to 8 pixels across, the Fire above
// is only noise. Autopilot burns purple: not a seventh rung, a fire of its own.
const STONE = {
  left: ['#565b6d', '#474b5b'], // the two tones of brick, on the side the light is
  right: ['#454959', '#383c49'], // and the side away from it
  arch: ['#5e6375', '#4b5062'],
  base: '#3c404e',
  foot: '#2a2d37',
  grate: '#666c7c',
  slot: '#101217',
  ash: ['#3c414d', '#4d525f'],
};
// Edge to core. Autopilot's tops out at its own colour, short of the chest bar's paler lavender.
const FLAMES = {
  warm: ['#8f2a17', '#d9502a', '#ff9a3d', '#ffd25e', '#fff3c4'],
  auto: ['#33236e', '#5233b8', '#7a58ea', '#a78bfa', '#a78bfa'],
};
const COALS = { warm: ['#6e2414', '#c24e1f', '#f08a30'], auto: ['#2e2163', '#5233b8', '#7a58ea'] };
// Each level: how high the flame stands in the chamber, how many coals glow, the air in there, and
// the extras: Chilling's one ember, embers rising, a white-hot core, the stone hot inside.
const HEAT = {
  asleep: { flame: 0, coals: 0 },
  idle: { flame: 0, coals: 0, ember: true },
  warming: { flame: 0.2, coals: 4, room: '#140c0b' },
  cruising: { flame: 0.55, coals: 4, room: '#1b0e0b' },
  locked: { flame: 0.78, coals: 8, room: '#23100b', embers: 1, wall: '#6b3a2a' },
  overdrive: { flame: 0.9, coals: 8, room: '#2c120b', embers: 2, core: true, wall: '#8a4630' },
  autopilot: { flame: 0.66, coals: 4, room: '#130e26', auto: true, wall: '#463a74' },
};

/** The same number for the same (a, b), 0..1: a flicker that is the same at the same moment. */
function noise(a, b) {
  let h = Math.imul(a ^ 0x9e3779b9, 0x85ebca6b) ^ Math.imul(b + 0x632be5ab, 0xc2b2ae35);
  h = Math.imul(h ^ (h >>> 15), 0x2c1b3c6d);
  h ^= h >>> 12;
  return (h >>> 0) / 4294967296;
}

/**
 * Draws the furnace in (x, y, w, h), robot pixels: 10 or 12 wide, 17 or more high. `t` is seconds.
 * lit: 0 cold (the head still opening), 1 the bed glows, 2 alight. still: Reduce Motion, one frame a level.
 */
export function drawFurnace(ctx, x, y, w, h, state, t, { lit = 2, still = false } = {}) {
  const R = (px, py, pw, ph, c) => {
    ctx.fillStyle = c;
    ctx.fillRect(px, py, pw, ph);
  };
  const heat = HEAT[state] || HEAT.asleep;
  const arch = w >= 12 ? [2, 4, 5] : [2, 4]; // half the width of each row, over the top
  const half = (r) => (r < arch.length ? arch[r] : w / 2);
  const open = (r) => (r >= 2 && r <= h - 4 ? Math.max(0, half(r - 2) - 2) : 0); // two in from the stone
  const top = 3; // the opening's first row
  const bed = h - 4; // the row the coals lie on
  const ox = x + 2;
  const ow = w - 4;
  const mid = w / 2;

  // the chamber
  const room = lit ? heat.room || '#08090c' : '#08090c';
  for (let r = top; r <= bed; r++) R(x + mid - open(r), y + r, 2 * open(r), 1, room);

  // the fire: four frames, flickering as fast as the robot bobs
  const f = still ? 2 : Math.floor(t * PACE[state] * 1.5) % 4;
  if (lit >= 2 && heat.flame > 0) flame(R, ox, y + top, ow, bed - top, heat, f);

  // the bed: ash, or coals
  const coals = heat.auto ? COALS.auto : COALS.warm;
  const n = lit ? heat.coals : 0;
  for (let c = 0; c < ow; c++) {
    const on = Math.abs(c - (ow - 1) / 2) < n / 2;
    R(ox + c, y + bed, 1, 1, on ? coals[c % 2 ? 1 : noise(f, c + 40) > 0.55 ? 2 : 0] : STONE.ash[(c + 1) % 2]);
  }
  if (!n) R(ox + ow / 2 - 1, y + bed - 1, 2, 1, STONE.ash[0]); // a little heap
  if (lit && heat.ember) R(ox + ow / 2 - 1, y + bed, 1, 1, still || Math.sin(t * PACE.idle) < 0.4 ? '#6a2715' : '#9a3a18');

  // embers rising off the flame, one or two at a time
  if (lit >= 2 && !still)
    for (let k = 0; k < (heat.embers || 0); k++) {
      const s = (t + k * 0.8) / (1.5 + k * 0.7);
      const p = s % 1;
      if (p > 0.45) continue;
      const ex = ox + 1 + Math.floor(noise(Math.floor(s), 7 + k) * (ow - 2));
      const from = bed - 1 - Math.round(heat.flame * (bed - top) * 0.7);
      R(ex, y + Math.round(from - (from - top - 1) * (p / 0.45)), 1, 1, p < 0.2 ? '#ffe7a3' : '#ff9a3d');
    }

  // the stone, last, so it trims the fire: an arch of two-tone bricks lit from the left, a grate
  // under the bed, a footing
  for (let r = 0; r < h; r++) {
    const hw = half(r);
    const o = open(r);
    for (let c = mid - hw; c < mid + hw; c++) {
      if (o && c >= mid - o && c < mid + o) continue; // the opening
      let colour;
      if (r >= h - 2) colour = r === h - 1 ? STONE.foot : STONE.base;
      else if (r === h - 3 && c >= 2 && c < w - 2) colour = c % 2 ? STONE.grate : lit && n ? coals[0] : STONE.slot;
      else if (r < arch.length) colour = STONE.arch[Math.floor(c / 2 + r) % 2];
      else {
        const course = Math.floor((r - arch.length) / 2) % 2;
        colour = (c < mid ? STONE.left : STONE.right)[course];
        // hot stone: the inside of the arch glows with the fire, every other course
        if (lit >= 2 && heat.wall && (c === 1 || c === w - 2) && r <= bed && course === 0) colour = heat.wall;
      }
      R(x + c, y + r, 1, 1, colour);
    }
  }
}

/** One frame of flame: a peak in the middle, edge to core in five colours, each column's height
 *  flickering frame to frame, and now and then a lick come loose over the top. */
function flame(R, ox, oy, ow, oh, heat, f) {
  const pal = heat.auto ? FLAMES.auto : FLAMES.warm;
  const tall = heat.flame * oh;
  const mid = (ow - 1) / 2 + (noise(f, 99) < 0.25 ? -0.5 : noise(f, 98) < 0.25 ? 0.5 : 0);
  for (let c = 0; c < ow; c++) {
    const shape = 1 - Math.min(1, Math.abs(c - mid) / (ow / 2)) * 0.85;
    const hc = Math.max(0, Math.min(oh, Math.round(tall * shape + (noise(f, c) - 0.5) * 2.4)));
    for (let r = 0; r < hc; r++) {
      const v = shape * (1 - r / (hc + 0.5));
      const i = v > 0.78 ? (heat.core ? 4 : 3) : v > 0.58 ? 3 : v > 0.38 ? 2 : v > 0.17 ? 1 : 0;
      R(ox + c, oy + oh - 1 - r, 1, 1, pal[i]);
    }
  }
  if (noise(f, 77) < 0.35) {
    const r = Math.round(tall) + 1;
    if (r < oh) R(ox + Math.round(mid + (noise(f, 78) - 0.5) * 2), oy + oh - 1 - r, 1, 1, pal[1]);
  }
}

// A token: a small chip that turns as it falls, so three widths of it.
const TOKEN = [
  ['xhx', 'xxs', 'sss'],
  ['hx', 'xs', 'ss'],
  ['h', 'x', 's'],
];
const TOKEN_COLORS = { x: '#dbe3ee', h: '#ffffff', s: '#9aa9be' };

export class Scene {
  /** `centered` puts the robot in the middle with the fire at full height all the way across. */
  constructor(canvas, { centered = false } = {}) {
    this.centered = centered;
    this.canvas = canvas;
    this.ctx = canvas.getContext('2d');
    this.state = 'asleep';
    this.expr = '';
    this.flame = 0;
    this.flameTarget = 0;
    this.dropRate = 0;
    this.night = 0;
    this.drops = [];
    this.embers = [];
    this.stars = [];
    this.t = 0;
    this.last = 0;
    this.fireAcc = 0;
    this.dropAcc = 0;
    this.emberAcc = 0;
  }

  resize(cssW, cssH) {
    const unit = Math.max(2, Math.round(Math.min(cssW, cssH) / 120));
    const W = Math.max(40, Math.ceil(cssW / unit));
    const H = Math.max(40, Math.ceil(cssH / unit));
    this.W = W;
    this.H = H;
    this.canvas.width = W;
    this.canvas.height = H;
    this.FH = Math.min(H, 60);
    this.fire = new Fire(W, this.FH);
    this.wide = !this.centered && W / H > 1.25;
    this.cx = this.wide ? Math.round(W * 0.26) : Math.round(W / 2);
    this.gy = H - 27; // high enough that the flames lick its legs without hiding it
    this.stars = [];
    for (let i = 0; i < (W * H) / 260; i++) {
      this.stars.push({ x: Math.floor(Math.random() * W), y: Math.floor(Math.random() * H * 0.62), p: Math.random() * 6.28 });
    }
    this.drops = [];
    this.embers = [];
  }

  /** state: one of STATE_ORDER; flame: 0..1 how hard tokens are burning; dropRate: tokens falling per second. */
  setLive({ state, flame, dropRate }) {
    if (!this.primed) {
      // First reading: start where things are instead of animating up from nothing.
      this.primed = true;
      this.flame = flame;
      this.night = state === 'asleep' ? 1 : state === 'idle' ? 0.45 : 0;
    }
    this.state = state;
    this.flameTarget = flame;
    this.dropRate = dropRate;
  }

  /** A reaction over the level's face ('worried', 'happy', 'waiting'), or '' for none. */
  setExpr(expr) {
    this.expr = expr || '';
  }

  /** Where the robot is, in CSS pixels: centre line, top of its antenna, top of its platform. */
  anchor() {
    if (!this.W) return null;
    const sx = this.canvas.clientWidth / this.W;
    const sy = this.canvas.clientHeight / this.H;
    return { x: (this.cx + 0.5) * sx, top: (this.gy - 54) * sy, feet: (this.gy + 3) * sy, unit: sy };
  }

  #stepFire() {
    const { W } = this;
    // On a wide screen the numbers sit on the right: keep the fire lower there.
    const room = (x) => {
      const f = x / W;
      return !this.wide || f < 0.42 ? 1 : f > 0.56 ? 0.46 : 1 - ((f - 0.42) / 0.14) * 0.54;
    };
    this.fire.step(this.flame, this.t, room);
  }

  #burst(x) {
    this.fire.burst(x);
    for (let k = 0; k < 5; k++) {
      this.embers.push({
        x: x + Math.random() * 4 - 2,
        y: this.H - 3 - Math.random() * 5,
        vx: (Math.random() - 0.5) * 16,
        vy: -(18 + Math.random() * 26),
        life: 1,
        ttl: 0.8 + Math.random() * 1.2,
      });
    }
  }

  frame(nowMs) {
    if (!this.fire) return; // not sized yet
    const dt = Math.min(0.05, this.last ? (nowMs - this.last) / 1000 : 0.016);
    this.last = nowMs;
    this.t += dt;
    const { ctx, W, H, cx, gy, state } = this;
    const t = this.t;
    const ease = (rate) => 1 - Math.exp(-dt * rate);
    this.flame += (this.flameTarget - this.flame) * ease(1.1);
    const nightTarget = state === 'asleep' ? 1 : state === 'idle' ? 0.45 : 0;
    this.night += (nightTarget - this.night) * ease(0.8);

    this.fireAcc += dt;
    for (let n = 0; this.fireAcc >= 1 / 30 && n < 3; n++) {
      this.fireAcc -= 1 / 30;
      this.#stepFire();
    }

    ctx.clearRect(0, 0, W, H);

    // stars come out when nothing is happening
    if (this.night > 0.02) {
      for (const s of this.stars) {
        ctx.globalAlpha = this.night * (0.35 + 0.65 * Math.abs(Math.sin(t * 0.7 + s.p)));
        ctx.fillStyle = '#cfd8f0';
        ctx.fillRect(s.x, s.y, 1, 1);
      }
      ctx.globalAlpha = 1;
    }

    // locked in: slow ripples spreading out from the robot
    if (state === 'locked' || state === 'overdrive') {
      const cy = gy - 28;
      const reach = Math.max(W, H) * 0.5;
      ctx.fillStyle = STATE_META[state].color;
      for (let k = 0; k < 3; k++) {
        const r = 24 + ((t * (state === 'overdrive' ? 22 : 12) + (k * reach) / 3) % reach);
        ctx.globalAlpha = 0.22 * (1 - r / (reach + 24));
        const steps = Math.ceil(r * 5);
        for (let i = 0; i < steps; i++) {
          const a = (i / steps) * Math.PI * 2;
          ctx.fillRect(Math.round(cx + Math.cos(a) * r), Math.round(cy + Math.sin(a) * r), 1, 1);
        }
      }
      ctx.globalAlpha = 1;
    }

    // platform
    ctx.fillStyle = '#10141b';
    ctx.fillRect(cx - 19, gy + 3, 3, H - gy);
    ctx.fillRect(cx + 16, gy + 3, 3, H - gy);
    ctx.fillStyle = '#1d232d';
    ctx.fillRect(cx - 24, gy, 48, 3);
    ctx.fillStyle = '#2f3846';
    ctx.fillRect(cx - 24, gy, 48, 1);

    drawRobot(ctx, cx, gy, state, t, this.expr);

    // tokens fall in and burn
    this.dropAcc += this.dropRate * dt;
    while (this.dropAcc >= 1) {
      this.dropAcc -= 1;
      if (this.drops.length < 90) {
        this.drops.push({ x: 3 + Math.random() * (W - 9), y: -6, vy: 14 + Math.random() * 18, spin: Math.random() * 4 });
      }
    }
    const surface = H - 5 - this.flame * 16;
    for (let i = this.drops.length - 1; i >= 0; i--) {
      const c = this.drops[i];
      c.vy += 110 * dt;
      c.y += c.vy * dt;
      c.spin += dt * 7;
      if (c.y >= surface) {
        this.#burst(c.x + 1);
        this.drops.splice(i, 1);
        continue;
      }
      const rows = TOKEN[[0, 1, 2, 1][Math.floor(c.spin) % 4]];
      const x = Math.round(c.x) + Math.floor((3 - rows[0].length) / 2);
      const y = Math.round(c.y);
      for (let r = 0; r < rows.length; r++)
        for (let q = 0; q < rows[r].length; q++) {
          ctx.fillStyle = TOKEN_COLORS[rows[r][q]];
          ctx.fillRect(x + q, y + r, 1, 1);
        }
    }

    this.fire.draw(ctx, 0, H - this.FH);

    // embers rise off the fire
    this.emberAcc += this.flame * W * 0.22 * dt;
    while (this.emberAcc >= 1) {
      this.emberAcc -= 1;
      if (this.embers.length > 400) break;
      this.embers.push({
        x: Math.random() * W,
        y: H - 2 - Math.random() * this.flame * 30,
        vx: (Math.random() - 0.5) * 6,
        vy: -(7 + Math.random() * 16),
        life: 1,
        ttl: 1.4 + Math.random() * 2.4,
      });
    }
    for (let i = this.embers.length - 1; i >= 0; i--) {
      const e = this.embers[i];
      e.life -= dt / e.ttl;
      if (e.life <= 0) {
        this.embers.splice(i, 1);
        continue;
      }
      e.x += (e.vx + Math.sin(t * 3 + e.y * 0.2) * 4) * dt;
      e.y += e.vy * dt;
      ctx.globalAlpha = Math.min(1, e.life * 1.5);
      ctx.fillStyle = e.life > 0.66 ? '#ffe7a3' : e.life > 0.33 ? '#ff9a3d' : '#b5431b';
      ctx.fillRect(Math.round(e.x), Math.round(e.y), 1, 1);
    }
    ctx.globalAlpha = 1;
  }
}
