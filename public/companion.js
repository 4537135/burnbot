// The desktop robot: Burnbot standing on your desktop with nothing around it.
//
// At rest it is only the robot, and what it is doing shows in its face, its arms and a little
// fire or a few embers around it. Point at it and its head stretches into a small screen that
// says what is going on; click it for a short panel; its reactions speak in the same bubbles as
// the big scene.
//
// The app (app/Companion.swift) owns the window: it says where the robot stands and where the
// pointer is (burnbotPlace, burnbotPointer); this page draws, and says which of its parts catch
// the mouse ('hit') and whether you are looking at it ('busy': a bubble that is not urgent waits).
//
// In a browser: ?demo=cycle | <level> | moments[&n=..] as the big scene, or none (fed by message
// from the board that frames it, companion-board.html), plus &style=1..3, &scale=2..4, &right=0 (opens to the left), &down=1
// (opens downward), &hover=1 (head open), &panel=1 (panel open).

import { drawRobot, drawSmoke, Fire, STATE_META, STATE_ORDER } from './robot.js';
import { compact, duration } from './format.js';
import { inApp, listen, tell } from './link.js';
import { runDemo } from './demo.js';

const $ = (id) => document.getElementById(id);
const params = new URLSearchParams(location.search);
const demo = params.get('demo') || (inApp ? null : 'cycle');
const still = matchMedia('(prefers-reduced-motion: reduce)');

/**
 * The ways the head turns into a screen (you pick one: Big, Wide, Compact; Companion.styleNames).
 * w × h: the head as a screen; bezel: its frame;
 * face: where the eyes go; title/now: where the text starts, in robot pixels from the screen's
 * left; foot: intensity blocks along the bottom (otherwise top right); rate: tokens/h beside them.
 */
const STYLES = {
  1: { w: 70, h: 40, bezel: 4, face: 'corner', title: 12, nowAt: 2, nowTop: 8, foot: true, rate: true },
  2: { w: 88, h: 28, bezel: 4, face: 'edge', title: 20, nowAt: 20, nowTop: 6.5, foot: false, rate: false },
  3: { w: 48, h: 34, bezel: 2, face: 'corner', title: 12, nowAt: 2, nowTop: 8, foot: true, rate: false },
};
const REST = { w: 32, h: 22 };
// Where the app puts the robot's feet in the window (Companion.swift): from the near side, from the bottom.
const FEET_IN = { x: 52, y: 10 };
const HEADROOM = 82;

// ---------------------------------------------------------------- the window

const canvas = $('robot');
const ctx = canvas.getContext('2d');
const off = document.createElement('canvas'); // the robot alone
const octx = off.getContext('2d');
const sil = document.createElement('canvas'); // its outline
const sctx = sil.getContext('2d');

let place = null; // {scale, style, x, y, right, down, shown: [x, y, w, h]}, from the app
let s = 3; // one robot pixel, in CSS pixels
let W = 0;
let H = 0;
let fx = 0; // the robot's feet, in robot pixels
let gy = 0;

function browserPlace() {
  const scale = Number(params.get('scale')) || 3;
  const right = params.get('right') !== '0';
  const down = params.get('down') === '1';
  return {
    scale,
    style: Number(params.get('style')) || 1,
    right,
    down,
    x: right ? FEET_IN.x * scale : innerWidth - FEET_IN.x * scale,
    y: down ? HEADROOM * scale : innerHeight - FEET_IN.y * scale,
    shown: null,
  };
}

function fit() {
  if (!inApp) place = { ...browserPlace(), ...(window.burnbotStyle ? { style: window.burnbotStyle } : {}) };
  if (!place) return;
  s = place.scale;
  W = Math.ceil(innerWidth / s);
  H = Math.ceil(innerHeight / s);
  for (const c of [canvas, off, sil]) {
    c.width = W;
    c.height = H;
  }
  canvas.style.width = `${W * s}px`;
  canvas.style.height = `${H * s}px`;
  document.documentElement.style.setProperty('--s', `${s}px`);
  fx = Math.round(place.x / s);
  gy = Math.round(place.y / s);
}

window.burnbotPlace = (next) => {
  place = next;
  fit();
};
addEventListener('resize', fit);
fit();
tell('where'); // the app answers with burnbotPlace

/** The part of the window that is on screen, in CSS pixels. */
function shownArea() {
  const v = place?.shown;
  return v ? { x: v[0], y: v[1], w: v[2], h: v[3] } : { x: 0, y: 0, w: innerWidth, h: innerHeight };
}

// ---------------------------------------------------------------- readings

let data = null;
const closed = new Set(); // bubbles closed here, before the app has heard about it

function receive(next) {
  data = next;
  const state = data?.live?.state || 'asleep';
  document.documentElement.style.setProperty('--state', STATE_META[state].color);
  document.title = `${STATE_META[state].label} · Burnbot`;
  fillScreen();
  fillPanel();
}

if (demo === 'none') {
  // fed by hand (the comparison board)
} else if (demo) runDemo(demo, receive);
else {
  listen(receive);
  tell('levels', { names: Object.fromEntries(STATE_ORDER.map((n) => [n, STATE_META[n].label])) });
}

// ---------------------------------------------------------------- the pointer

let pointer = null; // CSS pixels in the window, or null when it is elsewhere
window.burnbotPointer = (x, y) => {
  pointer = x === null || x === undefined ? null : { x, y };
};
addEventListener('mousemove', (e) => (pointer = { x: e.clientX, y: e.clientY }));
document.addEventListener('mouseleave', () => (pointer = null));

const inside = (r, p) => Boolean(r && p && p.x >= r.x && p.x < r.x + r.w && p.y >= r.y && p.y < r.y + r.h);

// The head as a screen opens in steps: 1 the eyes glance aside, 2-4 the head grows,
// 5-7 a line of text at a time. Closing clears the text at once, then shrinks back.
let stage = 0;
let target = 0;
let nextStep = 0;
let overSince = 0;
let awaySince = 0;
let panelOpen = params.get('panel') === '1';
let panelAwaySince = 0;
let dragging = false;
let busySent = null;
let robotBox = null; // the robot, head to feet, in CSS pixels
let headNow = null; // the head as drawn, in robot pixels

const forcedOpen = () => params.get('hover') === '1' || Boolean(data?.knockTest);
const bubbleOn = () => $('bubble').classList.contains('on');

function follow(now) {
  const over = !dragging && inside(robotBox, pointer);
  if (forcedOpen() && !panelOpen && !dragging) {
    target = 7;
  } else if (over && !panelOpen && !bubbleOn()) {
    awaySince = 0;
    if (!overSince) overSince = now;
    if (target === 0 && now - overSince >= 120) target = 7; // resting on it, not passing over
  } else {
    overSince = 0;
    if (target === 7) {
      if (!awaySince) awaySince = now;
      if (now - awaySince >= 300 || dragging || panelOpen) {
        target = 0;
        awaySince = 0;
      }
    }
  }
  if (stage !== target && now >= nextStep) {
    if (still.matches) stage = target;
    else if (target > stage) {
      stage++;
      nextStep = now + (stage === 1 ? 90 : 65);
    } else {
      stage = stage > 4 ? 4 : stage - 1;
      nextStep = now + 55;
    }
  }

  // The panel closes when you leave it alone for 20 s.
  if (panelOpen) {
    if (inside(robotBox, pointer) || inside(box($('panel')), pointer)) panelAwaySince = 0;
    else if (!panelAwaySince) panelAwaySince = now;
    else if (now - panelAwaySince > 20_000) setPanel(false);
  }

  const busy = stage > 0 || panelOpen;
  if (busy !== busySent) {
    busySent = busy;
    tell('busy', { on: busy });
  }
}

// The app hid the robot (or sent it to the second screen): back at rest, panel shut. The app has
// already let go of what was held back while you pointed at it.
window.burnbotHidden = () => {
  setPanel(false);
  stage = target = overSince = awaySince = 0;
  pointer = null;
  busySent = false;
};

// ---------------------------------------------------------------- drawing

const fire = new Fire(64, 30);
const embers = [];
let t = 0;
let last = 0;
let fireAcc = 0;
let emberAcc = 0;

function shownExpr() {
  const knock = data?.knockTest;
  if (knock) return knock.felt ? 'happy' : '';
  return data?.expr || '';
}

/** One frame. `now` in ms. */
function tick(now) {
  const dt = Math.min(0.1, last ? (now - last) / 1000 : 0.033);
  last = now;
  t += dt;
  follow(now);
  if (!place || !W) return;

  const live = data?.live;
  const state = live?.state || 'asleep';
  const expr = shownExpr();
  const style = STYLES[place.style] || STYLES[1];
  const k = Math.max(0, Math.min(3, stage - 1)); // how far the head has grown, 0 to 3
  const head = { w: Math.round(REST.w + ((style.w - REST.w) * k) / 3), h: Math.round(REST.h + ((style.h - REST.h) * k) / 3) };
  const glance = stage >= 1 && stage < 3 ? -2 : panelOpen ? (place.right ? 2 : -2) : 0;
  // smoke is drawn after the outline: outlined, each puff would be a ring
  const opt = { head, bezel: k >= 2 ? style.bezel : 4, face: { mode: stage >= 3 ? style.face : 'face', glance }, smoke: false };

  octx.clearRect(0, 0, W, H);
  const drawn = drawRobot(octx, fx, gy, state, t, expr, opt);
  headNow = drawn.head;

  // A dark outline, so it reads on a white window as well as a dark one.
  sctx.globalCompositeOperation = 'source-over';
  sctx.clearRect(0, 0, W, H);
  for (const [dx, dy] of [[-1, 0], [1, 0], [0, -1], [0, 1]]) sctx.drawImage(off, dx, dy);
  sctx.globalCompositeOperation = 'source-in';
  sctx.fillStyle = 'rgba(9, 11, 16, 0.85)';
  sctx.fillRect(0, 0, W, H);
  sctx.globalCompositeOperation = 'source-over';

  ctx.clearRect(0, 0, W, H);
  // a little shadow on the ground
  ctx.fillStyle = 'rgba(0, 0, 0, 0.26)';
  ctx.fillRect(fx - 11, gy, 22, 1);
  ctx.fillStyle = 'rgba(0, 0, 0, 0.14)';
  ctx.fillRect(fx - 8, gy + 1, 16, 1);
  behind(state, dt);
  ctx.drawImage(sil, 0, 0);
  ctx.drawImage(off, 0, 0);
  if (drawn.ears) drawSmoke(ctx, drawn.ears, t);
  inFront(state, dt);
  if (stage >= 7) blocks(drawn.screen, style, live, state);

  const hw = Math.round(head.w / 2);
  const reach = Math.max(hw + 4, 18);
  robotBox = { x: (fx - reach) * s, y: (gy - 21 - head.h - 10) * s, w: 2 * reach * s, h: (head.h + 31) * s };
  layoutScreen(drawn.screen, style);
  syncBubble();
  if (bubbleOn()) placeBubble();
  if (panelOpen) placePanel();
  lightGo();
  reportHits();
}

/** Fire, ripples, and what goes round the back. */
function behind(state, dt) {
  const quiet = still.matches;
  const level = state === 'overdrive' ? 0.62 : state === 'locked' ? 0.3 : 0;
  fireAcc += dt;
  const every = quiet ? 1 / 8 : 1 / 30;
  for (let n = 0; fireAcc >= every && n < 3; n++) {
    fireAcc -= every;
    fire.step(level, t, (x) => Math.max(0, 1 - ((x - 32) / 27) ** 2 * 1.3));
  }
  fire.draw(ctx, fx - 32, gy + 2 - 30);

  if (!quiet && (state === 'locked' || state === 'overdrive')) {
    // slow rings spreading out from it
    const period = state === 'overdrive' ? 1.6 : 2.6;
    const p = (t % period) / period;
    const r = 20 + 18 * p;
    ctx.globalAlpha = 0.32 * (1 - p);
    ctx.fillStyle = STATE_META[state].color;
    const n = Math.ceil(r * 5);
    for (let i = 0; i < n; i++) {
      const a = (i / n) * Math.PI * 2;
      ctx.fillRect(Math.round(fx + Math.cos(a) * r), Math.round(gy - 26 + Math.sin(a) * r * 0.72), 1, 1);
    }
    ctx.globalAlpha = 1;
  }
  // With the head open its screen is in front: the whole orbit goes behind it, nothing crosses the text.
  if (!quiet && state === 'autopilot') {
    orbit(false);
    if (stage > 0) orbit(true);
  }
}

function inFront(state, dt) {
  if (still.matches) return;
  if (state === 'autopilot' && stage === 0) orbit(true);
  // embers drifting up off it
  const rate = state === 'overdrive' ? 8 : state === 'locked' ? 4 : state === 'cruising' ? 1.5 : 0;
  emberAcc += rate * dt;
  while (emberAcc >= 1) {
    emberAcc -= 1;
    embers.push({ x: fx + (Math.random() * 32 - 16), y: gy - Math.random() * 6, vx: Math.random() * 6 - 3, vy: -(8 + Math.random() * 10), life: 1, ttl: 1 + Math.random() });
  }
  for (let i = embers.length - 1; i >= 0; i--) {
    const e = embers[i];
    e.life -= dt / e.ttl;
    if (e.life <= 0) {
      embers.splice(i, 1);
      continue;
    }
    e.x += (e.vx + Math.sin(t * 3 + e.y * 0.3) * 3) * dt;
    e.y += e.vy * dt;
    ctx.globalAlpha = Math.min(1, e.life * 1.5);
    ctx.fillStyle = e.life > 0.66 ? '#ffe7a3' : e.life > 0.33 ? '#ff9a3d' : '#b5431b';
    ctx.fillRect(Math.round(e.x), Math.round(e.y), 1, 1);
  }
  ctx.globalAlpha = 1;
}

/** Autopilot: three purple specks circling its head, the near half drawn in front. */
function orbit(front) {
  for (let k = 0; k < 3; k++) {
    const a = t * 1.6 + (k * Math.PI * 2) / 3;
    if (Math.sin(a) > 0 !== front) continue;
    const x = Math.round(fx + Math.cos(a) * 22);
    const y = Math.round(gy - 34 + Math.sin(a) * 8);
    ctx.fillStyle = '#c4b5fd';
    ctx.fillRect(x, y, 1, 1);
    ctx.globalAlpha = 0.4;
    ctx.fillRect(x - Math.sign(Math.cos(a + 0.4)), y, 1, 1);
    ctx.globalAlpha = 1;
  }
}

/** How hard it is going: five blocks on the screen, lit in the level's colour. */
function blocks(sc, style, live, state) {
  const lit = state === 'asleep' ? 0 : Math.max(state === 'idle' ? 0 : 1, Math.ceil((live?.intensity || 0) / 20));
  const x = style.foot ? sc.x + 2 : sc.x + sc.w - 21;
  const y = style.foot ? sc.y + sc.h - 5 : sc.y + 2;
  for (let i = 0; i < 5; i++) {
    ctx.fillStyle = i < lit ? STATE_META[state].color : '#2a3240';
    ctx.fillRect(x + i * 4, y, 3, 3);
  }
}

// ---------------------------------------------------------------- the head as a screen

let screenKey = '';
function fillScreen() {
  const live = data?.live;
  const state = live?.state || 'asleep';
  const meta = STATE_META[state];
  const knock = data?.knockTest;
  let title = meta.label.toUpperCase();
  let now = data?.nowLine || data?.glance?.claude?.text || meta.blurb;
  let ask = data?.glance?.claude?.kind === 'needs';
  if (data?.scan && data.scan.phase !== 'live') [now, ask] = ['Reading your history…', false];
  if (knock) {
    title = 'KNOCK TEST';
    now = knock.felt ? 'Felt it!' : `Knock twice on the desk screen · ${knock.left} s`;
    ask = false;
  }
  $('sTitle').textContent = title;
  $('sNow').textContent = now;
  $('sNow').classList.toggle('ask', ask);
  $('sRate').textContent = live?.tokensPerHour > 0 ? `${compact(live.tokensPerHour)}/h` : '';
}

function layoutScreen(sc, style) {
  const el = $('screen');
  const lines = stage - 4; // how many lines are showing
  const key = `${sc.x},${sc.y},${sc.w},${sc.h},${lines},${place.style},${s}`;
  if (key === screenKey) return;
  screenKey = key;
  el.style.left = `${sc.x * s}px`;
  el.style.top = `${sc.y * s}px`;
  const set = (id, x, y, w, on) => {
    const e = $(id);
    e.style.left = `${x * s}px`;
    e.style.top = `${y * s}px`;
    e.style.width = `${Math.max(0, w) * s}px`;
    e.classList.toggle('on', on);
  };
  const blocksW = style.foot ? 0 : 22;
  set('sTitle', style.title, style.foot ? 1 : 0.5, sc.w - style.title - 1 - blocksW, lines >= 1);
  set('sNow', style.nowAt, style.nowTop, sc.w - style.nowAt - 2, lines >= 2);
  set('sRate', 24, sc.h - 6.5, sc.w - 26, lines >= 3 && style.rate);
}

// ---------------------------------------------------------------- the bubble

let momentId = null;

function syncBubble() {
  const moment = data?.moment;
  const id = moment && !closed.has(moment.id) ? moment.id : null;
  const bubble = $('bubble');
  if (id !== momentId) {
    momentId = id;
    if (id) {
      $('bubbleTitle').textContent = moment.title;
      $('bubbleLines').replaceChildren(
        ...moment.lines.map((text) => {
          const p = document.createElement('p');
          p.textContent = text;
          return p;
        }),
      );
      $('bubbleGo').hidden = moment.action !== 'focus';
      bubble.classList.toggle('urgent', moment.kind === 'waiting');
      bubble.classList.toggle('happy', moment.kind === 'breakthrough');
      bubble.dataset.action = moment.action || '';
      bubble.dataset.session = moment.session || '';
    }
  }
  // It waits while you are reading the head or the panel, and comes back when you are done.
  const show = Boolean(momentId) && stage === 0 && !panelOpen && !dragging;
  if (show !== bubbleOn()) bubble.classList.toggle('on', show);
}

$('bubble').addEventListener('click', (event) => {
  event.stopPropagation();
  if (!momentId) return;
  closed.add(momentId);
  // In Play Every Moment a click only skips ahead; it does not pull your terminal forward.
  tell('moment', { id: momentId, action: data?.demo ? null : $('bubble').dataset.action || null, session: $('bubble').dataset.session || null });
  momentId = null;
  $('bubble').classList.remove('on');
});

/** The window never takes the focus, so CSS :hover does not fire in it while you work elsewhere:
 *  the Go to it button under the pointer is lit by hand. */
function lightGo() {
  for (const [go, open] of [[$('bubbleGo'), bubbleOn()], [$('pGo'), panelOpen]]) {
    if (!open || go.hidden || !pointer) {
      go.classList.remove('hot');
      continue;
    }
    const r = go.getBoundingClientRect();
    go.classList.toggle('hot', inside({ x: r.left, y: r.top, w: r.width, h: r.height }, pointer));
  }
}

/** Beside the head, toward the middle of the screen, tail pointing at it; kept on screen. */
/**
 * Puts a bubble or the panel beside the robot's head, on the side toward the middle of the screen,
 * its tail pointing at the head: the robot is saying it. Kept inside the part of the window on screen.
 */
function besideHead(el) {
  const area = shownArea();
  const bw = el.offsetWidth;
  const bh = el.offsetHeight;
  const head = headNow;
  const mid = (head.y + 9 + head.h * 0.45) * s;
  let x = place.right ? (head.x + head.w + 5) * s : (head.x - 5) * s - bw;
  let y = place.down ? mid - bh * 0.25 : mid - bh * 0.75;
  x = Math.min(Math.max(x, area.x + 3 * s), area.x + area.w - bw - 3 * s);
  y = Math.min(Math.max(y, area.y + 3 * s), area.y + area.h - bh - 3 * s);
  el.style.left = `${Math.round(x)}px`;
  el.style.top = `${Math.round(y)}px`;
  el.classList.toggle('flip', !place.right);
  const tail = el.querySelector('.tail');
  tail.style.left = place.right ? `${-2 * s}px` : `${bw + s}px`;
  tail.style.top = `${Math.round(Math.min(Math.max(mid - y - s, s), bh - 4 * s))}px`;
}

function placeBubble() {
  besideHead($('bubble'));
}

// ---------------------------------------------------------------- the panel

function setPanel(on) {
  if (on === panelOpen) return;
  panelOpen = on;
  panelAwaySince = 0;
  $('panel').classList.toggle('on', on);
  tell('panel', { open: on });
  if (on) {
    target = 0;
    fillPanel();
  }
}

function fillPanel() {
  const live = data?.live;
  const state = live?.state || 'asleep';
  const g = data?.glance || {};
  $('pTitle').textContent = g.title || 'Burnbot';
  $('pWhere').textContent = g.where || '';
  $('pWhere').hidden = !g.where;
  $('pClaude').textContent = g.claude?.text || 'Claude is idle';
  $('pClaude').classList.toggle('ask', g.claude?.kind === 'needs');
  const minutes = live?.streakMin || 0;
  $('pLevel').textContent = STATE_META[state].label + (minutes >= 1 && state !== 'asleep' && state !== 'idle' ? ` · ${duration(minutes)}` : '');
  $('pRate').textContent = live?.tokensPerHour > 0 ? `${compact(live.tokensPerHour)} tokens/h` : '';
  $('pRate').hidden = !(live?.tokensPerHour > 0);
  $('pNext').hidden = !g.next;
  $('pNextText').textContent = g.next?.text || '';
  $('pGo').hidden = g.next?.action !== 'focus';
}

function placePanel() {
  besideHead($('panel')); // the robot says it too, like a bubble
}

$('pGo').addEventListener('click', (event) => {
  event.stopPropagation();
  // To the session the panel is about; if the bubble is asking for you too, it closes as well.
  const session = data?.glance?.session || $('bubble').dataset.session || null;
  if (momentId && $('bubble').dataset.action === 'focus') {
    closed.add(momentId);
    tell('moment', { id: momentId, action: data?.demo ? null : 'focus', session });
    momentId = null;
  } else if (!data?.demo) tell('focus', { session });
  setPanel(false);
});
$('pDash').addEventListener('click', (event) => {
  event.stopPropagation();
  tell('dashboard');
  setPanel(false);
});

window.burnbotOutside = () => setPanel(false);
addEventListener('keydown', (e) => e.key === 'Escape' && setPanel(false));

// ---------------------------------------------------------------- clicks and drags

let downAt = null;
addEventListener('mousedown', (e) => (downAt = { x: e.screenX, y: e.screenY }));
addEventListener('click', (e) => {
  // The app moves the window under the pointer while you drag the robot: a click that ends a drag is no click.
  const moved = downAt && Math.hypot(e.screenX - downAt.x, e.screenY - downAt.y) > 3;
  downAt = null;
  if (moved || e.target.closest('#panel, #bubble')) return;
  if (inside(robotBox, { x: e.clientX, y: e.clientY })) setPanel(!panelOpen);
});
addEventListener('contextmenu', (e) => e.preventDefault());

window.burnbotDrag = (on) => {
  dragging = on;
  if (on) {
    setPanel(false);
    target = 0;
    stage = 0;
  }
};

// ---------------------------------------------------------------- what catches the mouse

function box(el) {
  const r = el.getBoundingClientRect();
  // the frame and the tail sit outside the box
  return { x: r.left - 4 * s, y: r.top - 2 * s, w: r.width + 8 * s, h: r.height + 4 * s };
}

let sentHits = '';
function reportHits() {
  const round = (b) => [Math.floor(b.x), Math.floor(b.y), Math.ceil(b.w), Math.ceil(b.h)];
  const rects = [];
  if (robotBox) rects.push(round(robotBox));
  if (bubbleOn()) rects.push(round(box($('bubble'))));
  if (panelOpen) rects.push(round(box($('panel'))));
  const message = JSON.stringify(rects);
  if (message === sentHits) return;
  sentHits = message;
  tell('hit', { rects, robot: robotBox ? round(robotBox) : [] });
  if (framed) parent.postMessage({ burnbot: 'robot', box: robotBox }, '*'); // the board aims its pointer at the head
}

// ---------------------------------------------------------------- running

if (panelOpen) $('panel').classList.add('on');

// A timer, not the display's refresh: waking 60 times a second to draw 30 or fewer frames costs more
// than the drawing. 30 frames a second is plenty for pixel art; asleep or chilling, at rest with
// nothing flying about, 12 or so (it only moves a couple of times a second then). Hidden, nothing.
let frameTimer = 0;
function loop() {
  frameTimer = 0;
  if (document.hidden) return; // picks up again when shown
  const calm = ['asleep', 'idle'].includes(data?.live?.state) && stage === 0 && !panelOpen && embers.length === 0;
  tick(performance.now());
  frameTimer = setTimeout(loop, calm ? 80 : 33);
}
document.addEventListener('visibilitychange', () => {
  if (!document.hidden && !frameTimer) loop();
});
frameTimer = setTimeout(loop); // once the rest of this file has run

// For the app's self-check (--snapshot) and the comparison board.
window.burnbot = {
  fit,
  scene: { frame: (ms) => tick(ms) },
  setPanel,
  robotBox: () => robotBox,
  setStyle: (n) => {
    window.burnbotStyle = n;
    if (place) place.style = n;
    screenKey = '';
  },
};

// The comparison board frames this page and talks to it by message, which works whichever
// origin each page is served from (a page viewer may serve the board and its frames apart).
const framed = !inApp && parent !== window;
if (framed) {
  addEventListener('message', (e) => {
    const m = e.data;
    if (e.source !== parent || !m || typeof m !== 'object') return;
    if (m.burnbot === 'feed') receive(m.state);
    else if (m.burnbot === 'pointer') window.burnbotPointer(m.x, m.y);
    else if (m.burnbot === 'style') window.burnbot.setStyle(m.n);
  });
  parent.postMessage({ burnbot: 'ready' }, '*');
}
