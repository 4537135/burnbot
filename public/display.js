// The second screen: the robot, the fire, the level it is on, and the token burn.
// Add ?demo=locked (or any state, or ?demo=cycle) to preview a level.

import { Scene, pixelText, drawLogo, STATE_META, STATE_ORDER, LADDER } from './robot.js';
import { compact, ticker, clock, duration, subline, levelLine, nextLine } from './format.js';

const $ = (id) => document.getElementById(id);
const scene = new Scene($('scene'));
const fit = () => scene.resize(innerWidth, innerHeight);
window.burnbot = { scene }; // handle for poking at the scene from the console
addEventListener('resize', fit);
fit();

const demo = new URLSearchParams(location.search).get('demo');
let data = null;
let receivedAt = 0;
let shownRate = 0;
let shownToday = -1;
let lastFrame = 0;
let logoState = '';

pixelText($('brandText'), 'BURNBOT', '#f6ece3');

// The ladder, top level first, with autopilot set apart underneath.
$('ladder').innerHTML =
  [...LADDER]
    .reverse()
    .map((s) => {
      const m = STATE_META[s];
      return `<div class="rung" role="listitem" data-s="${s}" style="--c:${m.color}"><i></i><b>${m.level}</b><span>${m.label}</span><em>usual now</em></div>`;
    })
    .join('') +
  `<div class="rung off" role="listitem" data-s="autopilot" style="--c:${STATE_META.autopilot.color}"><i></i><b>A</b><span>AUTOPILOT</span></div>`;

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
const DEMO_NEXT = { warming: ['cruising', 35, 0], cruising: ['locked', 72, 35], locked: ['overdrive', 88, 72] };

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
      next: up ? { state: up[0], intensity: up[1], progress: Math.max(0, Math.min(1, (intensity - up[2]) / (up[1] - up[2]))), streakLeftMin: 0 } : null,
      usual: 'cruising',
      intensity,
      hotterThan: d.pct[0],
      tokensPerHour: d.rate,
      outputPerHour: d.rate * 0.012,
      flame: d.flame,
      idleMin: name === 'asleep' ? 95 : 8,
      humanIdleMin: 41,
      streakMin: 52,
      lockedRunMin: 34,
      lastCallMs: now - 95 * 60000,
    },
    today: { tokens: 186.4e6 + ((now - started) / 3600000) * d.rate, usualByNow: 131e6, typicalDay: 240e6 },
    baseline: { calibrated: true, activeMinutes: 3120, needMinutes: 120, windowDays: 30 },
  };
}

// ---------- live data ----------

if (demo) {
  const pick = () => (demo === 'cycle' ? STATE_ORDER[Math.floor(Date.now() / 7000) % STATE_ORDER.length] : demo);
  const tick = () => DEMO[pick()] && receive(demoState(pick(), Date.now()));
  tick();
  setInterval(tick, 1000);
} else {
  const stream = new EventSource('/api/events');
  stream.addEventListener('state', (e) => receive(JSON.parse(e.data)));
}

function receive(next) {
  data = next;
  receivedAt = performance.now();
  render();
}

function render() {
  const { live, today, scan, baseline } = data;
  const meta = STATE_META[live.state];
  // Say that the levels are fitted to this person, or how far along the fitting is.
  $('cal').innerHTML = baseline.calibrated
    ? `<b>Calibrated to you</b> · ${duration(baseline.activeMinutes)} of your work · last ${baseline.windowDays} days`
    : `<b>Calibrating to you</b> · ${baseline.activeMinutes} of ${baseline.needMinutes} min`;
  document.body.className = `s-${live.state}` + (document.body.classList.contains('quiet') ? ' quiet' : '');
  document.documentElement.style.setProperty('--state', meta.color);
  document.documentElement.style.setProperty('--glow', meta.glow);

  // which level, and why
  $('levelCap').textContent = levelLine(live);
  pixelText($('stateText'), meta.label, meta.color);
  const scanning = scan && scan.phase !== 'live';
  $('sub').textContent = scanning ? `Reading your Claude history… ${scan.done} of ${scan.total} sessions` : subline(live);

  // the ladder: everything up to the current level is lit, the usual level for this hour is tagged
  for (const rung of $('ladder').children) {
    const s = rung.dataset.s;
    const level = STATE_META[s].level;
    rung.classList.toggle('now', s === live.state);
    rung.classList.toggle('lit', live.level !== null && level !== null && level <= live.level);
    rung.classList.toggle('usual', s === live.usual && s !== live.state);
  }

  // the way up
  const up = live.next;
  $('nextCap').textContent = up ? `Next · ${STATE_META[up.state].label}` : live.level === live.topLevel ? 'Top level' : 'Next level';
  $('nextBar').style.width = `${up ? Math.max(2, up.progress * 100) : live.level === live.topLevel ? 100 : 0}%`;
  let note = nextLine(live, up ? STATE_META[up.state].label.toLowerCase() : '');
  if (live.usual && live.usual !== live.state) {
    const usual = STATE_META[live.usual];
    const below = live.level !== null && usual.level > live.level;
    note += `. Your usual level at ${clock(data.now)}: ${usual.label.toLowerCase()}${below ? ', so you are behind' : ''}`;
  }
  $('nextNote').textContent = note + '.';

  // tokens
  $('rateSub').textContent = `${compact(live.outputPerHour)} of them written by Claude`;
  const pace = today.usualByNow > 1000 ? Math.round((today.tokens / today.usualByNow) * 100) : null;
  $('pace').textContent = pace === null ? 'Still learning your usual day' : `${pace}% of your usual by ${clock(data.now)}`;

  // More burn, more tokens falling into the fire.
  scene.setLive({ state: live.state, flame: live.flame, dropRate: live.flame > 0.1 ? 0.25 + 4.5 * live.flame ** 2 : 0 });

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
}

// ---------- animation ----------

function frame(now) {
  const dt = Math.min(0.1, (now - lastFrame) / 1000 || 0.016);
  lastFrame = now;
  if (data) {
    const { live, today } = data;
    const ease = 1 - Math.exp(-dt * 2.5);

    shownRate += (live.tokensPerHour - shownRate) * ease;
    if (Math.abs(live.tokensPerHour - shownRate) < 500) shownRate = live.tokensPerHour;
    pixelText($('rateText'), compact(shownRate), '#f6ece3');

    // Keep the day's total creeping at the current rate between updates, so
    // the tokens are visibly burning rather than jumping every two seconds.
    const ahead = live.flame > 0.1 ? (live.tokensPerHour / 3600) * Math.min(6, (now - receivedAt) / 1000) : 0;
    const target = today.tokens + ahead;
    if (shownToday < 0 || Math.abs(target - shownToday) > Math.max(2e6, live.tokensPerHour / 60)) shownToday = target;
    else if (target > shownToday) shownToday += (target - shownToday) * ease;
    pixelText($('todayText'), ticker(shownToday), STATE_META[live.state].color);
  }
  $('clock').textContent = clock(Date.now());
  scene.frame(now);
  requestAnimationFrame(frame);
}
requestAnimationFrame(frame);

// ---------- being a good second screen ----------

const toast = (text, ms = 4000) => {
  $('toast').textContent = text;
  $('toast').classList.add('on');
  clearTimeout(toast.timer);
  toast.timer = setTimeout(() => $('toast').classList.remove('on'), ms);
};

// Inside Burnbot.app the window is native, so fullscreen is the app's job.
const native = window.webkit?.messageHandlers?.burnbot;
if (native) {
  addEventListener('dblclick', () => native.postMessage({ type: 'toggleFullscreen' }));
} else {
  addEventListener('click', () => {
    if (document.fullscreenElement) document.exitFullscreen();
    else document.documentElement.requestFullscreen?.().catch(() => {});
  });
}

// Hide the pointer once it stops moving.
let quietTimer;
addEventListener('mousemove', () => {
  document.body.classList.remove('quiet');
  clearTimeout(quietTimer);
  quietTimer = setTimeout(() => document.body.classList.add('quiet'), 2500);
});

// Stop the monitor from going to sleep while the robot is on it.
async function stayAwake() {
  try {
    const lock = await navigator.wakeLock.request('screen');
    lock.addEventListener('release', () => document.visibilityState === 'visible' && stayAwake());
  } catch {
    /* not supported, or the page is hidden */
  }
}
document.addEventListener('visibilitychange', () => document.visibilityState === 'visible' && stayAwake());
stayAwake();

if (!native && !document.fullscreenElement && !matchMedia('(display-mode: fullscreen)').matches) {
  setTimeout(() => !document.fullscreenElement && toast('Click anywhere for fullscreen'), 1500);
}

// Lost the tracker (it was stopped or restarted): say so instead of freezing.
setInterval(() => {
  if (!demo && data && performance.now() - receivedAt > 8000) toast('Reconnecting to Burnbot…', 3000);
}, 3000);
