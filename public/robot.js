// The pixel-art side of Burnbot: the orange robot, the fire it stands over, the
// tokens that fall into it, and a small bitmap font. Everything is drawn on a
// low-resolution canvas and scaled up with hard pixels.

// The states, shown to the person as levels. Rename a level by editing its label.
export const STATE_META = {
  asleep: { level: 0, label: 'ASLEEP', color: '#8493b8', blurb: 'No Claude activity for a while' },
  idle: { level: 1, label: 'CHILLING', color: '#9d968e', blurb: 'Quiet for a few minutes' },
  warming: { level: 2, label: 'WARMING UP', color: '#b8774c', blurb: 'Working, below your usual pace' },
  cruising: { level: 3, label: 'COOKING', color: '#f58d4d', blurb: 'Working at your usual pace' },
  locked: { level: 4, label: 'LOCKED IN', color: '#ffc74f', blurb: 'Well above your normal, and sustained' },
  overdrive: { level: 5, label: 'ON FIRE', color: '#fff0c4', glow: '#ff5a36', blurb: 'Your top gear' },
  autopilot: { level: null, label: 'AUTOPILOT', color: '#72b4f8', blurb: 'Agents are working without you' },
};
for (const m of Object.values(STATE_META)) m.glow ??= m.color;
/** The ladder, bottom to top. Autopilot is off it: Claude works while you are away. */
export const LADDER = ['asleep', 'idle', 'warming', 'cruising', 'locked', 'overdrive'];
export const STATE_ORDER = ['asleep', 'idle', 'warming', 'cruising', 'locked', 'overdrive', 'autopilot'];

// ---------------------------------------------------------------- bitmap font

const GLYPHS = {
  A: [14, 17, 17, 31, 17, 17, 17], B: [30, 17, 17, 30, 17, 17, 30], C: [14, 17, 16, 16, 16, 17, 14],
  D: [30, 17, 17, 17, 17, 17, 30], E: [31, 16, 16, 30, 16, 16, 31], F: [31, 16, 16, 30, 16, 16, 16],
  G: [14, 17, 16, 23, 17, 17, 15], H: [17, 17, 17, 31, 17, 17, 17], I: [14, 4, 4, 4, 4, 4, 14],
  J: [7, 2, 2, 2, 2, 18, 12], K: [17, 18, 20, 24, 20, 18, 17], L: [16, 16, 16, 16, 16, 16, 31],
  M: [17, 27, 21, 21, 17, 17, 17], N: [17, 17, 25, 21, 19, 17, 17], O: [14, 17, 17, 17, 17, 17, 14],
  P: [30, 17, 17, 30, 16, 16, 16], Q: [14, 17, 17, 17, 21, 18, 13], R: [30, 17, 17, 30, 20, 18, 17],
  S: [15, 16, 16, 14, 1, 1, 30], T: [31, 4, 4, 4, 4, 4, 4], U: [17, 17, 17, 17, 17, 17, 14],
  V: [17, 17, 17, 17, 17, 10, 4], W: [17, 17, 17, 21, 21, 21, 10], X: [17, 17, 10, 4, 10, 17, 17],
  Y: [17, 17, 17, 10, 4, 4, 4], Z: [31, 1, 2, 4, 8, 16, 31],
  0: [14, 17, 19, 21, 25, 17, 14], 1: [4, 12, 4, 4, 4, 4, 14], 2: [14, 17, 1, 2, 4, 8, 31],
  3: [31, 2, 4, 2, 1, 17, 14], 4: [2, 6, 10, 18, 31, 2, 2], 5: [31, 16, 30, 1, 1, 17, 14],
  6: [6, 8, 16, 30, 17, 17, 14], 7: [31, 1, 2, 4, 8, 8, 8], 8: [14, 17, 17, 14, 17, 17, 14],
  9: [14, 17, 17, 15, 1, 2, 12],
  ' ': [0, 0, 0, 0, 0, 0, 0], '-': [0, 0, 0, 31, 0, 0, 0], '.': [0, 0, 0, 0, 0, 12, 12],
  ',': [0, 0, 0, 0, 12, 4, 8], '!': [4, 4, 4, 4, 4, 0, 4], '%': [24, 25, 2, 4, 8, 19, 3],
  $: [4, 15, 20, 14, 5, 30, 4], '/': [0, 1, 2, 4, 8, 16, 0], ':': [0, 12, 12, 0, 12, 12, 0],
  '+': [0, 4, 4, 31, 4, 4, 0],
};

/** Renders text into a canvas at one canvas pixel per font pixel; size it with CSS. */
export function pixelText(canvas, text, color) {
  const s = String(text).toUpperCase();
  const key = s + '|' + color;
  if (canvas.dataset.key === key) return;
  canvas.dataset.key = key;
  const w = Math.max(1, s.length * 6 - 1);
  canvas.width = w;
  canvas.height = 7;
  const ctx = canvas.getContext('2d');
  ctx.fillStyle = color;
  for (let i = 0; i < s.length; i++) {
    const g = GLYPHS[s[i]] || GLYPHS[' '];
    for (let r = 0; r < 7; r++) for (let c = 0; c < 5; c++) if (g[r] & (16 >> c)) ctx.fillRect(i * 6 + c, r, 1, 1);
  }
  canvas.setAttribute('aria-label', text);
}

// ---------------------------------------------------------------------- robot

/**
 * Draws the robot standing with its feet at (cx, gy). `t` is seconds; the
 * state picks the face, the posture and how fast it moves.
 */
export function drawRobot(ctx, cx, gy, state, t) {
  const asleep = state === 'asleep';
  const idle = state === 'idle';
  const locked = state === 'locked';
  const over = state === 'overdrive';
  const auto = state === 'autopilot';
  const working = state === 'warming' || state === 'cruising' || locked || over;
  const accent = STATE_META[state].color;

  let body = '#d9774f';
  let hi = '#f3a57f';
  let sh = '#ad5330';
  let dark = '#7a391e';
  if (asleep) [body, hi, sh, dark] = ['#80554a', '#96685b', '#664238', '#4a2f27'];
  if (over) [body, hi, sh] = ['#ea6a3a', '#ffb489', '#b8481f'];
  const screen = '#1e110c';

  const R = (x, y, w, h, c) => {
    ctx.fillStyle = c;
    ctx.fillRect(Math.round(x), Math.round(y), w, h);
  };
  const glowBox = (x, y, w, h, c, a) => {
    ctx.globalAlpha = a;
    R(x, y, w, h, c);
    ctx.globalAlpha = 1;
  };

  const pace = asleep ? 1.1 : idle ? 1.7 : auto ? 2 : state === 'warming' ? 3 : state === 'cruising' ? 4.2 : locked ? 6 : 9;
  const bob = Math.sin(t * pace) > 0.35 ? 1 : 0;
  const x0 = cx + (over ? Math.round(Math.sin(t * 41)) : 0) + (auto ? Math.round(Math.sin(t * 1.3)) : 0);
  const hy = gy - 43 + bob + (asleep ? 2 : 0); // top of the head

  // legs and feet
  R(x0 - 9, gy - 5, 5, 5, sh);
  R(x0 + 4, gy - 5, 5, 5, sh);
  R(x0 - 10, gy - 2, 7, 2, dark);
  R(x0 + 3, gy - 2, 7, 2, dark);

  // arms: resting at the sides, or raised and tapping while working
  const tapHz = state === 'warming' ? 3 : state === 'cruising' ? 6 : locked ? 10 : 15;
  const beat = Math.floor(t * tapHz);
  if (working) {
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
    R(sx + ((beat * 7) % 4), gy - 6, 1, 1, '#ffe9c7');
    if (locked || over) R(sx + ((beat * 5) % 4), gy - 4, 1, 1, accent);
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
  for (let k = 0; k < 3; k++) {
    const h = working ? 1 + Math.floor((Math.sin(t * (5 + k * 2.3) + k * 1.7) + 1) * 2.4) : asleep ? 1 : auto ? 3 : 2;
    R(x0 - 5 + k * 4, gy - 10 - h, 2, h, asleep ? '#5d4a44' : accent);
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
  const glow = asleep ? '#8a90a6' : auto ? '#a9d4ff' : locked ? '#ffd87c' : over ? '#ffffff' : '#ffe9c7';
  const ey = hy + 7;
  const lx = x0 - 8;
  const rx = x0 + 4;
  const look = idle ? [-1, 0, 0, 1, 0, 0][Math.floor(t / 1.3) % 6] : 0;
  const blink = !asleep && !over && !auto && t % (locked ? 6.3 : 3.7) < 0.13;
  if (asleep || blink) {
    R(lx, ey + 4, 4, 1, glow);
    R(rx, ey + 4, 4, 1, glow);
  } else if (auto) {
    for (const ex of [lx, rx]) {
      R(ex, ey + 2, 1, 2, glow);
      R(ex + 1, ey + 1, 2, 1, glow);
      R(ex + 3, ey + 2, 1, 2, glow);
    }
  } else if (locked || over) {
    glowBox(lx - 1, ey, 6, 5, accent, 0.28);
    glowBox(rx - 1, ey, 6, 5, accent, 0.28);
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

  // mouth
  const my = hy + 14;
  if (asleep) R(x0 - 1, my, 2, 1, glow);
  else if (auto) {
    R(x0 - 4, my - 1, 1, 1, glow);
    R(x0 - 3, my, 6, 1, glow);
    R(x0 + 3, my - 1, 1, 1, glow);
  } else if (over) {
    R(x0 - 4, my - 1, 8, 2, '#ffffff');
    for (let k = 0; k < 3; k++) R(x0 - 2 + k * 2, my - 1, 1, 2, screen);
  } else if (locked) R(x0 - 3, my, 6, 1, glow);
  else if (state === 'cruising') {
    R(x0 - 3, my - 1, 1, 1, glow);
    R(x0 - 2, my, 4, 1, glow);
    R(x0 + 2, my - 1, 1, 1, glow);
  } else R(x0 - 2, my, 4, 1, glow);

  // antenna
  R(x0 - 1, hy - 5, 2, 5, sh);
  if (auto) {
    const w = [9, 6, 2, 6][Math.floor(t * 12) % 4];
    R(x0 - 1, hy - 8, 2, 3, '#9fd0ff');
    R(x0 - w / 2, hy - 8, w, 1, '#d6ebff');
  } else {
    let bulb = '#5a4640';
    if (idle) bulb = Math.sin(t * 1.6) > 0.6 ? '#e6ab62' : '#7a5a3a';
    else if (working) bulb = locked || over || beat % 2 ? accent : '#8a5a3a';
    if (locked || over) glowBox(x0 - 4, hy - 11, 8, 8, accent, 0.25 + 0.15 * Math.sin(t * 5));
    R(x0 - 2, hy - 9, 4, 4, bulb);
    if (over) R(x0 - 1, hy - 8, 2, 2, '#fff6d2');
  }

  // headphones go on when it locks in
  if (locked || over) {
    const band = '#2c2832';
    R(x0 - 17, hy - 2, 34, 2, band);
    R(x0 - 18, hy - 1, 2, 8, band);
    R(x0 + 16, hy - 1, 2, 8, band);
    R(x0 - 20, hy + 6, 4, 11, '#3b3542');
    R(x0 + 16, hy + 6, 4, 11, '#3b3542');
    R(x0 - 20, hy + 10, 1, 3, accent);
    R(x0 + 19, hy + 10, 1, 3, accent);
  }

  // overdrive: the head is on fire
  if (over) {
    for (let k = 0; k < 6; k++) {
      const fx = x0 - 13 + k * 5 + Math.round(Math.sin(t * 9 + k));
      const fh = 3 + Math.floor((Math.sin(t * 13 + k * 2.1) + 1) * 2.4);
      R(fx, hy - fh, 2, fh, '#ff8a2e');
      if (fh > 4) R(fx, hy - fh + 2, 1, fh - 3, '#ffe08a');
    }
  }

  // asleep: z z z
  if (asleep) {
    for (let k = 0; k < 3; k++) {
      const p = (t * 0.32 + k / 3) % 1;
      const zx = x0 + 16 + p * 12;
      const zy = hy - 2 - p * 18;
      const big = p > 0.5;
      ctx.globalAlpha = Math.min(1, (1 - p) * 1.6);
      const w = big ? 4 : 3;
      R(zx, zy, w, 1, '#c5cde4');
      for (let d = 1; d < w - 1; d++) R(zx + w - 1 - d, zy + d, 1, 1, '#c5cde4');
      R(zx, zy + w - 1, w, 1, '#c5cde4');
      ctx.globalAlpha = 1;
    }
  }
}

/** The app's logo is the robot's head, so it changes with the state too. */
export function drawLogo(canvas, state, t = 0.5) {
  if (canvas.width !== 42) canvas.width = 42;
  if (canvas.height !== 36) canvas.height = 36;
  const ctx = canvas.getContext('2d');
  ctx.clearRect(0, 0, 42, 36);
  drawRobot(ctx, 21, 55, state, t);
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

// A token: a small diamond that spins as it falls, so three widths of it.
const TOKEN = [
  ['..x..', '.xhx.', 'xhxxs', '.xxs.', '..s..'],
  ['.x.', 'xhx', 'xhs', 'xxs', '.s.'],
  ['x', 'h', 'x', 's', 's'],
];
const TOKEN_COLORS = { x: '#ffd2ac', h: '#ffffff', s: '#dd8552' };

export class Scene {
  /** `centered` puts the robot in the middle with the fire at full height all the way across. */
  constructor(canvas, { centered = false } = {}) {
    this.centered = centered;
    this.canvas = canvas;
    this.ctx = canvas.getContext('2d');
    this.fireCanvas = document.createElement('canvas');
    this.fctx = this.fireCanvas.getContext('2d');
    this.palette = firePalette();
    this.state = 'asleep';
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
    this.fire = new Uint8Array(W * this.FH);
    this.bump = new Float32Array(W);
    this.fireCanvas.width = W;
    this.fireCanvas.height = this.FH;
    this.img = this.fctx.createImageData(W, this.FH);
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

  #stepFire() {
    const { W, FH, fire, bump } = this;
    const base = (FH - 1) * W;
    const lvl = this.flame;
    for (let x = 0; x < W; x++) {
      const lump = 0.74 + 0.26 * Math.sin(x * 0.23 + this.t * 2.3) * Math.sin(x * 0.061 - this.t * 1.1);
      // On a wide screen the numbers sit on the right: keep the fire lower there.
      const f = x / W;
      const room = !this.wide || f < 0.42 ? 1 : f > 0.56 ? 0.46 : 1 - ((f - 0.42) / 0.14) * 0.54;
      let h = 36 * lvl * lump * room + bump[x] * room;
      if (lvl < 0.1 && Math.random() < 0.5) h *= 0.4; // embers flicker
      bump[x] *= 0.9;
      fire[base + x] = h <= 0 ? 0 : h >= 36 ? 36 : h;
    }
    for (let y = 1; y < FH; y++) {
      const row = y * W;
      for (let x = 0; x < W; x++) {
        const v = fire[row + x];
        const r = (Math.random() * 3) | 0;
        let dx = x - r + 1;
        if (dx < 0) dx = 0;
        else if (dx >= W) dx = W - 1;
        const cool = Math.random() < 0.85 ? 1 : 0;
        fire[row - W + dx] = v > cool ? v - cool : 0;
      }
    }
  }

  #drawFire() {
    const { fire, palette } = this;
    const data = this.img.data;
    for (let i = 0; i < fire.length; i++) {
      const p = fire[i] * 4;
      const o = i * 4;
      data[o] = palette[p];
      data[o + 1] = palette[p + 1];
      data[o + 2] = palette[p + 2];
      data[o + 3] = palette[p + 3];
    }
    this.fctx.putImageData(this.img, 0, 0);
    this.ctx.drawImage(this.fireCanvas, 0, this.H - this.FH);
  }

  #burst(x) {
    const { W, bump } = this;
    for (let d = -4; d <= 4; d++) {
      const i = Math.round(x) + d;
      if (i >= 0 && i < W) bump[i] += 16 - Math.abs(d) * 3;
    }
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

    // locked in: a slow sunburst behind the robot
    if (state === 'locked' || state === 'overdrive') {
      const color = STATE_META[state].glow;
      const rays = 12;
      const reach = Math.max(W, H) * 0.55;
      const cy = gy - 30;
      ctx.fillStyle = color;
      for (let k = 0; k < rays; k++) {
        const a = (k / rays) * Math.PI * 2 + t * (state === 'overdrive' ? 0.5 : 0.18);
        const ca = Math.cos(a);
        const sa = Math.sin(a);
        ctx.globalAlpha = (state === 'overdrive' ? 0.085 : 0.06) * (0.75 + 0.25 * Math.sin(t * 2 + k));
        for (let r = 34; r < reach; r += 2) {
          const w = Math.max(1, Math.round(r * 0.1));
          ctx.fillRect(Math.round(cx + ca * r - w / 2), Math.round(cy + sa * r - w / 2), w, w);
        }
      }
      ctx.globalAlpha = 1;
    }

    // platform
    ctx.fillStyle = '#17110e';
    ctx.fillRect(cx - 19, gy + 3, 3, H - gy);
    ctx.fillRect(cx + 16, gy + 3, 3, H - gy);
    ctx.fillStyle = '#2b211c';
    ctx.fillRect(cx - 24, gy, 48, 3);
    ctx.fillStyle = '#46362c';
    ctx.fillRect(cx - 24, gy, 48, 1);

    drawRobot(ctx, cx, gy, state, t);

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
        this.#burst(c.x + 2);
        this.drops.splice(i, 1);
        continue;
      }
      const rows = TOKEN[[0, 1, 2, 1][Math.floor(c.spin) % 4]];
      const x = Math.round(c.x) + (5 - rows[0].length) / 2;
      const y = Math.round(c.y);
      for (let r = 0; r < rows.length; r++)
        for (let q = 0; q < rows[r].length; q++) {
          const ch = rows[r][q];
          if (ch === '.') continue;
          ctx.fillStyle = TOKEN_COLORS[ch];
          ctx.fillRect(x + q, y + r, 1, 1);
        }
    }

    this.#drawFire();

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
