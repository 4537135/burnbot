// The robot window: the robot, the fire, the level you are on, and the token burn,
// plus what the robot noticed: a face, a line under it, and now and then a speech bubble.
// Add ?demo=locked (or any state, or ?demo=cycle) to preview a level, and
// ?demo=moments (with &n=0..4 to hold one) to preview the reactions.

import { Scene, drawLogo, STATE_META, STATE_ORDER, LADDER } from './robot.js';
import { compact, ticker, clock, subline, levelLine, nextLine } from './format.js';
import { inApp, listen, tell } from './link.js';

const $ = (id) => document.getElementById(id);
const scene = new Scene($('scene'));
const fit = () => scene.resize(innerWidth, innerHeight);
window.burnbot = { scene, fit }; // handle for poking at the scene from the console
addEventListener('resize', fit);
fit();

// Outside the app (a browser, while working on the look) there is no tracker: cycle through the levels.
const demo = new URLSearchParams(location.search).get('demo') || (inApp ? null : 'cycle');
let data = null;
let receivedAt = 0;
let shownRate = 0;
let shownToday = -1;
let lastFrame = 0;
let logoState = '';
let momentId = null; // the speech bubble showing
const closed = new Set(); // bubbles closed here, before the app has heard about it

// The ladder, top level first. Autopilot only shows while you are on it.
$('ladder').innerHTML = [...LADDER]
  .reverse()
  .concat('autopilot')
  .map((s) => {
    const m = STATE_META[s];
    return `<div class="rung${m.level === null ? ' off' : ''}" role="listitem" data-s="${s}" style="--c:${m.color}"><i></i><span>${m.label}</span><em>usual</em></div>`;
  })
  .join('');

// ---------- demo levels, for previewing without waiting for real activity ----------

const DEMO = {
  asleep: { flame: 0, rate: 0, pct: [0, 0, 0] },
  idle: { flame: 0.04, rate: 0, pct: [8, 20, 5] },
  warming: { flame: 0.25, rate: 6.2e6, pct: [22, 30, 18] },
  cruising: { flame: 0.5, rate: 21.4e6, pct: [55, 48, 60] },
  locked: { flame: 0.78, rate: 48.5e6, pct: [82, 88, 71] },
  overdrive: { flame: 1, rate: 126e6, pct: [97, 94, 96] },
  autopilot: { flame: 0.6, rate: 33e6, pct: [70, 0, 66] },
};
const DEMO_NEXT = { warming: ['cruising', 30, 0], cruising: ['locked', 75, 30], locked: ['overdrive', 93, 75] };

// What the reactions look like, one after another. The app plays the real thing (Robot > Play Every Moment).
const card = (kind, title, lines, more = {}) => ({ id: kind, kind, title, lines, action: null, persistent: false, ...more });
const DEMO_MOMENTS = [
  { expr: 'worried', now: 'Claude running tests · 1m 40s', moment: null },
  { expr: 'happy', now: 'On: Fix checkout tax tests', moment: card('breakthrough', 'Finally. All green.', ['3 tries.', '5 min in the red.', 'Commit it.']) },
  {
    expr: 'waiting',
    now: 'Waiting on you · shop',
    moment: card('waiting', 'Your call', ['shop is stuck', 'until you say yes to', 'rm -rf dist && npm run build'], { action: 'focus', persistent: true }),
  },
  { expr: '', now: 'On: Fix checkout tax tests', moment: card('your-move', 'Your move', ['shop stopped', 'after 12 min.', 'It is waiting on you.']) },
  { expr: '', now: 'Last time: Fix checkout tax tests', moment: card('done', 'Session over', ['27 min on Fix checkout tax tests', 'Tests green after 3 tries', '1 commit']) },
];

function demoState(name, now) {
  const d = DEMO[name];
  const started = demoState.t0 || (demoState.t0 = now);
  const intensity = Math.round(0.4 * d.pct[0] + 0.35 * d.pct[1] + 0.25 * d.pct[2]);
  const up = DEMO_NEXT[name];
  return {
    now,
    scan: { phase: 'live' },
    live: {
      state: name,
      level: STATE_META[name].level,
      topLevel: 5,
      next: up ? { state: up[0], intensity: up[1], progress: 0.5, streakLeftMin: 0 } : null,
      usual: 'cruising',
      intensity,
      hotterThan: d.pct[0],
      tokensPerHour: d.rate,
      flame: d.flame,
      idleMin: name === 'asleep' ? 95 : 8,
      humanIdleMin: 41,
      streakMin: 52,
      lockedRunMin: 34,
      lastCallMs: now - 95 * 60000,
    },
    today: { tokens: 186.4e6 + ((now - started) / 3600000) * d.rate, usualByNow: 131e6 },
    baseline: { thresholds: { cruise: 30, lock: 75, overdrive: 93 } },
  };
}

// ---------- live data ----------

if (demo === 'moments') {
  const held = new URLSearchParams(location.search).get('n');
  const tick = () => {
    const now = Date.now();
    const n = held !== null ? Number(held) % DEMO_MOMENTS.length : Math.floor(now / 7000) % DEMO_MOMENTS.length;
    receive({ ...demoState('cruising', now), ...DEMO_MOMENTS[n] });
  };
  tick();
  setInterval(tick, 1000);
} else if (demo) {
  const pick = () => (demo === 'cycle' ? STATE_ORDER[Math.floor(Date.now() / 7000) % STATE_ORDER.length] : demo);
  const tick = () => DEMO[pick()] && receive(demoState(pick(), Date.now()));
  tick();
  setInterval(tick, 1000);
} else {
  listen(receive);
  // The app tells the desk screen what each level is called; the names live in robot.js.
  tell('levels', { names: Object.fromEntries(STATE_ORDER.map((s) => [s, STATE_META[s].label])) });
}

function receive(next) {
  data = next;
  receivedAt = performance.now();
  render();
}

function render() {
  const { live, today, scan, baseline } = data;
  const meta = STATE_META[live.state];
  const kept = ['quiet', 'speaking'].filter((c) => document.body.classList.contains(c));
  document.body.className = [`s-${live.state}`, ...kept].join(' ');
  document.documentElement.style.setProperty('--state', meta.color);

  // which level, and why
  $('levelCap').textContent = levelLine(live);
  $('levelName').textContent = meta.label;
  const scanning = scan && scan.phase !== 'live';
  $('sub').textContent = scanning ? `Reading your history… ${scan.done} of ${scan.total} sessions` : subline(live);

  // how far up the scale, and what the next level takes
  if (!$('track').querySelector('u')) {
    const cuts = baseline.thresholds;
    $('track').insertAdjacentHTML('beforeend', [cuts.cruise, cuts.lock, cuts.overdrive].map((v) => `<u style="left:${v}%"></u>`).join(''));
  }
  $('bar').style.width = `${Math.max(1, live.intensity)}%`;
  $('note').textContent = nextLine(live, live.next ? STATE_META[live.next.state].label : '');

  // the ladder: everything up to the current level is lit; the usual level for this hour is tagged
  for (const rung of $('ladder').children) {
    const s = rung.dataset.s;
    const level = STATE_META[s].level;
    rung.classList.toggle('now', s === live.state);
    rung.classList.toggle('lit', live.level !== null && level !== null && level <= live.level);
    rung.classList.toggle('usual', s === live.usual && s !== live.state);
  }

  const pace = today.usualByNow > 1000 ? Math.round((today.tokens / today.usualByNow) * 100) : null;
  $('pace').textContent = pace === null ? 'burned today' : `burned today · ${pace}% of your usual`;

  // More burn, more tokens falling into the fire.
  scene.setLive({ state: live.state, flame: live.flame, dropRate: live.flame > 0.1 ? 0.25 + 4.5 * live.flame ** 2 : 0 });

  // What the robot noticed.
  scene.setExpr(data.expr);
  const now = data.now || '';
  if ($('now').textContent !== now && now) $('now').textContent = now;
  $('now').classList.toggle('on', Boolean(now));
  showMoment(data.moment);
  place();

  if (logoState !== live.state) {
    logoState = live.state;
    drawLogo($('logo'), live.state);
    const icon = document.createElement('canvas');
    icon.width = icon.height = 64;
    const ictx = icon.getContext('2d');
    ictx.imageSmoothingEnabled = false;
    ictx.drawImage($('logo'), 0, 4, 64, 55);
    $('favicon').href = icon.toDataURL();
  }
  document.title = `${meta.label} · ${compact(live.tokensPerHour)} tokens/h · Burnbot`;
  paint(0);
}

// The numbers ease toward their values, and today's total keeps creeping at
// the current rate between updates, so the tokens are visibly burning.
function paint(dt) {
  if (!data) return;
  const { live, today } = data;
  const ease = dt ? 1 - Math.exp(-dt * 2.5) : 1;
  shownRate += (live.tokensPerHour - shownRate) * ease;
  if (Math.abs(live.tokensPerHour - shownRate) < 500) shownRate = live.tokensPerHour;
  $('rate').textContent = compact(shownRate);

  const ahead = live.flame > 0.1 ? (live.tokensPerHour / 3600) * Math.min(6, (performance.now() - receivedAt) / 1000) : 0;
  const target = today.tokens + ahead;
  if (shownToday < 0 || Math.abs(target - shownToday) > Math.max(2e6, live.tokensPerHour / 60)) shownToday = target;
  else if (target > shownToday) shownToday += (target - shownToday) * ease;
  $('today').textContent = ticker(shownToday);
}

function frame(now) {
  const dt = Math.min(0.1, (now - lastFrame) / 1000 || 0.016);
  lastFrame = now;
  paint(dt);
  $('clock').textContent = clock(Date.now());
  scene.frame(now);
  requestAnimationFrame(frame);
}
requestAnimationFrame(frame);

// ---------- the speech bubble and the line under the robot ----------

function showMoment(moment) {
  const bubble = $('bubble');
  const id = moment && !closed.has(moment.id) ? moment.id : null;
  if (id === momentId) return;
  momentId = id;
  if (!id) {
    bubble.classList.remove('on');
    document.body.classList.remove('speaking');
    return;
  }
  $('bubbleTitle').textContent = moment.title;
  $('bubbleLines').replaceChildren(
    ...moment.lines.map((text) => {
      const p = document.createElement('p');
      p.textContent = text;
      return p;
    }),
  );
  $('bubbleHint').textContent = moment.action === 'focus' ? 'Click to go to it' : '';
  bubble.classList.toggle('urgent', moment.kind === 'waiting');
  bubble.classList.toggle('happy', moment.kind === 'breakthrough');
  bubble.dataset.action = moment.action || '';
  bubble.classList.add('on');
  place();
}

$('bubble').addEventListener('click', (event) => {
  event.stopPropagation();
  if (!momentId) return;
  closed.add(momentId);
  // In Play Every Moment a click only skips ahead; it does not pull your terminal forward.
  tell('moment', { id: momentId, action: data?.demo ? null : $('bubble').dataset.action || null });
  momentId = null;
  $('bubble').classList.remove('on');
  document.body.classList.remove('speaking');
});
$('bubble').addEventListener('dblclick', (event) => event.stopPropagation());

/**
 * Puts the bubble over the robot's head when there is room, otherwise beside it, with its
 * tail pointing at the head; and the Now line just under the robot's platform.
 */
function place() {
  const a = scene.anchor();
  if (!a) return;
  const margin = 16;
  const W = innerWidth;
  const H = innerHeight;

  const line = $('now');
  const reach = Math.min(a.x, W - a.x) * 2 - 2 * margin;
  line.style.maxWidth = `${Math.max(160, reach)}px`;
  line.style.left = `${Math.min(Math.max(a.x, margin + line.offsetWidth / 2), W - margin - line.offsetWidth / 2)}px`;
  line.style.top = `${Math.min(a.feet + 5 * a.unit, H - margin - line.offsetHeight)}px`;

  const bubble = $('bubble');
  if (!bubble.classList.contains('on')) {
    document.body.classList.remove('speaking');
    return;
  }
  const p = parseFloat(getComputedStyle(bubble).getPropertyValue('--p')) || 4;
  const tail = bubble.querySelector('.tail');
  bubble.style.maxWidth = '';
  let bw = bubble.offsetWidth;
  let bh = bubble.offsetHeight;
  let x;
  let y;
  const side = a.top - 4 * p - bh < margin;
  if (!side) {
    x = Math.min(Math.max(a.x - bw * 0.3, margin), W - margin - bw);
    y = a.top - 4 * p - bh;
    tail.style.left = `${Math.min(Math.max(a.x - x - p / 2, p), bw - 4 * p)}px`;
    tail.style.top = `${bh + p}px`;
  } else {
    // No room above (a small window): to the right of the head instead.
    x = a.x + 26 * a.unit;
    bubble.style.maxWidth = `${Math.max(140, W - margin - x)}px`;
    bw = bubble.offsetWidth;
    bh = bubble.offsetHeight;
    x = Math.min(x, W - margin - bw);
    const headMiddle = a.top + 22 * a.unit;
    y = Math.min(Math.max(headMiddle - bh * 0.35, margin), H - margin - bh);
    tail.style.left = `${-2 * p}px`;
    tail.style.top = `${Math.min(Math.max(headMiddle - y - p, p), bh - 4 * p)}px`;
  }
  bubble.classList.toggle('side', side);
  // Beside the robot the bubble sits where the level is: the level steps back until it goes.
  document.body.classList.toggle('speaking', side);
  bubble.style.left = `${Math.round(x)}px`;
  bubble.style.top = `${Math.round(y)}px`;
}
addEventListener('resize', place);
document.fonts?.ready.then(place);

// ---------- window manners ----------

const toast = (text, ms = 4000) => {
  $('toast').textContent = text;
  $('toast').classList.add('on');
  clearTimeout(toast.timer);
  toast.timer = setTimeout(() => $('toast').classList.remove('on'), ms);
};

// Inside Burnbot.app the window is native, so fullscreen is the app's job.
if (inApp) {
  addEventListener('dblclick', () => tell('toggleFullscreen'));
} else {
  addEventListener('click', () => {
    if (document.fullscreenElement) document.exitFullscreen();
    else document.documentElement.requestFullscreen?.().catch(() => {});
  });
  setTimeout(() => !document.fullscreenElement && toast('Click anywhere for fullscreen'), 1500);
}

// Hide the pointer once it stops moving.
let quietTimer;
addEventListener('mousemove', () => {
  document.body.classList.remove('quiet');
  clearTimeout(quietTimer);
  quietTimer = setTimeout(() => document.body.classList.add('quiet'), 2500);
});
