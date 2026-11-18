// Made-up readings, for looking at the robot without waiting for real activity: in a browser,
// or from the app (Robot > Preview Every Level). ?demo=cycle, ?demo=<level>, ?demo=moments[&n=0..].

import { STATE_META, STATE_ORDER } from './robot.js';

export const DEMO = {
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
// glance: what the desktop robot's panel says (the app builds it from your sessions).
const g = (claude, kind, next = null) => ({
  title: 'Fix checkout tax tests',
  where: 'shop · feature/checkout',
  claude: { kind, text: claude },
  next,
});
export const DEMO_MOMENTS = [
  { expr: 'worried', nowLine: 'Claude running tests · 1m 40s', moment: null, glance: g('Claude is running tests', 'running', { text: 'Tests are failing in shop' }) },
  {
    expr: 'happy',
    nowLine: 'On: Fix checkout tax tests',
    moment: card('breakthrough', 'Finally. All green.', ['3 tries.', '5 min in the red.', 'Commit it.']),
    glance: g('Claude is working', 'working'),
  },
  {
    expr: 'waiting',
    nowLine: 'Waiting on you · shop',
    moment: card('waiting', 'Your call', ['shop is stuck', 'until you say yes to', 'rm -rf dist && npm run build'], { action: 'focus', persistent: true }),
    glance: g('Claude needs a yes: rm -rf dist && npm run build', 'needs', { text: 'Approve the build in shop', action: 'focus' }),
  },
  {
    expr: '',
    nowLine: 'On: Fix checkout tax tests',
    moment: card('your-move', 'Your move', ['shop stopped', 'after 12 min.', 'It is waiting on you.'], { action: 'focus' }),
    glance: g('Claude handed it back 1 min ago', 'handed', { text: 'Reply to Claude in shop', action: 'focus' }),
  },
  {
    expr: '',
    nowLine: 'Last time: Fix checkout tax tests',
    moment: card('done', 'Session over', ['27 min on Fix checkout tax tests', 'Tests green after 3 tries', '1 commit']),
    glance: g('Claude finished 2 min ago', 'finished', { text: 'Add the VAT edge cases' }),
  },
  {
    expr: 'puzzled',
    nowLine: 'Going round · 4 retries, no progress',
    moment: card('loop', 'Same ask again', ['4 retries, no edits.', 'Split it, or ask why', 'it keeps missing.']),
    glance: g('Claude is working', 'working'),
  },
  {
    expr: 'bored',
    nowLine: 'Drifted · 6 min · shop is waiting',
    moment: card('drift', 'Still there?', ['shop has waited', '12 min on you.'], { action: 'focus' }),
    glance: g('Claude handed it back 12 min ago', 'handed', { text: 'Reply to Claude in shop', action: 'focus' }),
  },
  { expr: 'happy', nowLine: 'Goal hit · 4 of 4 wins', moment: null, goal: { wins: 4, target: 4, streak: 6, hitToday: true }, glance: g('Claude is idle', 'idle') },
  { expr: 'smile', nowLine: 'Claude running tests · 40s', moment: null, glance: g('Claude is running tests', 'running') },
  {
    expr: 'cheer',
    nowLine: 'On: Fix checkout tax tests',
    moment: card('breakthrough', 'Finally. All green.', ['6 tries.', '14 min in the red.', 'Commit it.']),
    glance: g('Claude is working', 'working'),
  },
  { expr: 'wave', nowLine: 'Back to: Fix checkout tax tests', moment: null, glance: g('Claude finished 48 min ago', 'finished', { text: 'Add the VAT edge cases' }) },
  {
    expr: 'tired',
    nowLine: 'On: Fix checkout tax tests',
    moment: card('stretch', 'Big session', ['2 h 40 min with Claude.', 'Good place to stop', 'for ten.']),
    glance: g('Claude handed it back 1 min ago', 'handed', { text: 'Reply to Claude in shop', action: 'focus' }),
  },
];

export function demoState(name, now) {
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
    goal: { wins: 3, target: 4, streak: 5, hitToday: false },
    // What Claude is up to, to go with the level (asleep or chilling, nothing).
    glance: name === 'asleep' || name === 'idle' ? g('Claude is idle', 'idle')
      : name === 'autopilot' ? g('Claude is working', 'working') : g('Claude is running tests', 'running'),
    baseline: { thresholds: { cruise: 30, lock: 75, overdrive: 93 } },
  };
}

/** Feeds `receive` made-up readings once a second. */
export function runDemo(demo, receive) {
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
  }
}
