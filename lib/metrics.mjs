// Turns minute buckets into what the screens show: live token burn, today's
// totals, a personal baseline, and the level the person is at.
//
// It calibrates itself. Nothing here is an absolute number of tokens or
// keystrokes: every tick it re-reads the person's last 30 days and
//   1. ranks each signal against their own active time,
//   2. ranks the blend of those against their own active time again, which is
//      the 0-100 intensity, so 75 always means "hotter than 75% of your time",
//   3. cuts the levels at fixed points of that personal scale, and
//   4. times autopilot from the gaps they usually leave between prompts.
// So "locked in" is always "your own top quarter, sustained", whoever you are,
// and it drifts with you as your habits change.

import { F, FAMILIES, totalTokens } from './collector.mjs';

// Internal state names. The screens show them as levels (see STATE_META in
// public/robot.js): chilling, warming up, cooking, locked in, on fire.
export const STATES = ['asleep', 'idle', 'warming', 'cruising', 'locked', 'overdrive', 'autopilot'];
const S = { asleep: 0, idle: 1, warming: 2, cruising: 3, locked: 4, overdrive: 5, autopilot: 6 };
// The first six are the ladder, in order; a state's number is its level.
// Autopilot sits off the ladder: Claude is working but the person is away.
const TOP_LEVEL = S.overdrive;

export const CONFIG = {
  days: 30, // history used for calibration
  burnWindow: 15, // minutes of tokens behind the burn signal
  typeWindow: 30, // minutes of typing behind the typing signal
  actWindow: 15, // minutes of prompts + tool calls behind the activity signal
  weights: { burn: 0.4, typing: 0.35, actions: 0.25 },
  idleAfter: 5, // minutes without an API call -> chilling
  asleepAfter: 30, // -> asleep
  streakGap: 10, // a gap this long ends a streak
  // Autopilot: Claude still working, no prompt from the person for longer than
  // they usually leave between prompts. Learned from their own gaps, within limits.
  autopilotAfter: 25, // used until enough gaps have been seen
  autopilotQuantile: 0.85,
  autopilotRange: [15, 60],
  // Level cut-offs on the personal intensity scale: cooking is everything above
  // your quietest 30%, locked in is your top quarter, on fire your top 7%.
  cruiseAt: 30,
  lockAt: 75,
  lockHold: 62, // once locked in, stay locked down to here
  lockMinStreak: 20, // minutes of continuous work before lock-in can start
  overdriveAt: 93,
  overdriveHold: 88,
  minWindows: 120, // active minutes of history needed before the baseline is trusted
  // Used until there is enough history: the value that counts as "typical".
  defaults: { burn: 3e6, typing: 400, actions: 20 },
};

function dayStart(ms, deltaDays = 0) {
  const d = new Date(ms);
  return new Date(d.getFullYear(), d.getMonth(), d.getDate() + deltaDays).getTime();
}

function prefix(a) {
  const p = new Float64Array(a.length + 1);
  for (let i = 0; i < a.length; i++) p[i + 1] = p[i] + a[i];
  return p;
}
const win = (p, i, w) => p[i + 1] - p[i + 1 - w > 0 ? i + 1 - w : 0];

/** Share of sorted samples strictly below v, 0-100. */
function rank(sorted, n, v) {
  let lo = 0;
  let hi = n;
  while (lo < hi) {
    const mid = (lo + hi) >> 1;
    if (sorted[mid] < v) lo = mid + 1;
    else hi = mid;
  }
  return n ? (lo / n) * 100 : 0;
}
const quantile = (sorted, n, q) => (n ? sorted[Math.min(n - 1, Math.floor(q * n))] : 0);
function median(xs) {
  if (!xs.length) return 0;
  const s = [...xs].sort((a, b) => a - b);
  const m = s.length >> 1;
  return s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2;
}

let projectCache = { at: 0, rev: -1, value: null };

function projects(col, now, weekStartMin, todayStartMin) {
  if (projectCache.value && projectCache.rev === col.rev && now - projectCache.at < 60_000) return projectCache.value;
  if (projectCache.value && now - projectCache.at < 10_000) return projectCache.value;
  const week = new Map();
  const today = new Map();
  const weekStartMs = weekStartMin * 60000;
  for (const rec of col.files.values()) {
    if (rec.mtimeMs < weekStartMs) continue;
    const name = rec.project || 'unknown';
    for (const [minute, f] of rec.mins) {
      if (minute < weekStartMin) continue;
      const t = totalTokens(f);
      week.set(name, (week.get(name) || 0) + t);
      if (minute >= todayStartMin) today.set(name, (today.get(name) || 0) + t);
    }
  }
  const top = (m) =>
    [...m]
      .filter(([, t]) => t > 0)
      .sort((a, b) => b[1] - a[1])
      .map(([name, tokens]) => ({ name, tokens }));
  projectCache = { at: now, rev: col.rev, value: { week: top(week), today: top(today) } };
  return projectCache.value;
}

export function analyze(col, now = Date.now(), cfg = CONFIG) {
  const nowMin = Math.floor(now / 60000);
  const today0 = dayStart(now);
  const start0 = dayStart(now, -(cfg.days - 1));
  const startMin = Math.floor(start0 / 60000);
  const todayIdx = Math.floor(today0 / 60000) - startMin;
  const weekStartMin = Math.floor(dayStart(now, -6) / 60000);
  const N = nowMin - startMin + 1;

  // ---- dense per-minute series over the calibration window ----
  const tok = new Float64Array(N);
  const out = new Float64Array(N);
  const chars = new Float64Array(N);
  const acts = new Float64Array(N);
  const prompts = new Float64Array(N);
  const tools = new Float64Array(N);
  const lines = new Float64Array(N);
  const pasted = new Float64Array(N);
  const active = new Float64Array(N);
  const human = new Uint8Array(N);
  const split = { input: 0, output: 0, cacheWrite: 0, cacheRead: 0, thinking: 0, calls: 0 };
  const famToday = new Float64Array(FAMILIES.length);
  const famWeek = new Float64Array(FAMILIES.length);

  for (const [minute, g] of col.minutes) {
    const i = minute - startMin;
    if (i < 0 || i >= N) continue;
    const v = g.v;
    tok[i] = totalTokens(v);
    out[i] = v[F.output];
    chars[i] = v[F.chars];
    pasted[i] = v[F.pasted];
    prompts[i] = v[F.prompts];
    tools[i] = v[F.tools];
    lines[i] = v[F.lines];
    acts[i] = v[F.prompts] + v[F.tools];
    if (v[F.calls] > 0 || v[F.prompts] > 0) active[i] = 1;
    if (v[F.prompts] > 0) human[i] = 1;
    if (minute >= weekStartMin) for (let k = 0; k < famWeek.length; k++) famWeek[k] += v[F.tokFable + k];
    if (i >= todayIdx) {
      for (let k = 0; k < famToday.length; k++) famToday[k] += v[F.tokFable + k];
      split.input += v[F.input];
      split.output += v[F.output];
      split.cacheWrite += v[F.cacheWrite];
      split.cacheRead += v[F.cacheRead];
      split.thinking += v[F.thinking];
      split.calls += v[F.calls];
    }
  }

  const pTok = prefix(tok);
  const pOut = prefix(out);
  const pChars = prefix(chars);
  const pActs = prefix(acts);
  const pActive = prefix(active);
  const pPrompts = prefix(prompts);
  const pTools = prefix(tools);
  const pLines = prefix(lines);
  const pPasted = prefix(pasted);

  // ---- autopilot timing: how long this person usually goes between prompts ----
  const gaps = [];
  {
    let lastPrompt = -1;
    let lastSeen = -1e9;
    let broken = true; // a break long enough to fall asleep sits between the two prompts
    for (let i = 0; i < N; i++) {
      if (!active[i]) continue;
      if (i - lastSeen >= cfg.asleepAfter) broken = true;
      lastSeen = i;
      if (!human[i]) continue;
      if (!broken && lastPrompt >= 0) gaps.push(i - lastPrompt);
      lastPrompt = i;
      broken = false;
    }
  }
  gaps.sort((a, b) => a - b);
  const autopilotLearned = gaps.length >= 20;
  const autopilotAfter = autopilotLearned
    ? Math.max(cfg.autopilotRange[0], Math.min(cfg.autopilotRange[1], quantile(gaps, gaps.length, cfg.autopilotQuantile)))
    : cfg.autopilotAfter;

  // ---- personal baseline: how each signal is distributed over this person's
  // hands-on time (working, and prompted recently enough not to be on autopilot) ----
  const sb = new Float64Array(N);
  const st = new Float64Array(N);
  const sa = new Float64Array(N);
  const qualified = new Uint8Array(N);
  let n = 0;
  for (let i = 0, lastPrompt = -1e9; i < N; i++) {
    if (human[i]) lastPrompt = i;
    if (win(pActive, i, 15) < 3 || i - lastPrompt > autopilotAfter) continue;
    qualified[i] = 1;
    sb[n] = win(pTok, i, cfg.burnWindow);
    st[n] = win(pChars, i, cfg.typeWindow);
    sa[n] = win(pActs, i, cfg.actWindow);
    n++;
  }
  const bS = sb.subarray(0, n).slice().sort();
  const tS = st.subarray(0, n).slice().sort();
  const aS = sa.subarray(0, n).slice().sort();
  const calibrated = n >= cfg.minWindows;
  const soft = (v, ref) => 100 * (1 - Math.pow(2, -v / ref));
  const pBurn = (v) => (calibrated ? rank(bS, n, v) : soft(v, cfg.defaults.burn));
  const pType = (v) => (calibrated ? rank(tS, n, v) : soft(v, cfg.defaults.typing));
  const pActn = (v) => (calibrated ? rank(aS, n, v) : soft(v, cfg.defaults.actions));
  const W = cfg.weights;

  // ---- intensity: the blend of the three ranks, ranked against yourself again ----
  const raw = new Float32Array(N);
  const rS = new Float64Array(n);
  let nr = 0;
  for (let i = 0; i < N; i++) {
    if (win(pActive, i, cfg.idleAfter) === 0) continue; // asleep or chilling: no intensity
    raw[i] =
      W.burn * pBurn(win(pTok, i, cfg.burnWindow)) +
      W.typing * pType(win(pChars, i, cfg.typeWindow)) +
      W.actions * pActn(win(pActs, i, cfg.actWindow));
    if (qualified[i]) rS[nr++] = raw[i];
  }
  const rSorted = rS.subarray(0, nr).slice().sort();
  const score = (i) => (calibrated ? rank(rSorted, nr, raw[i]) : raw[i]);

  // ---- state per minute ----
  const state = new Uint8Array(N);
  const intensity = new Float32Array(N);
  let lastActive = -1e9;
  let lastHuman = -1e9;
  let streakStart = 0;
  let prev = S.asleep;
  for (let i = 0; i < N; i++) {
    if (active[i]) {
      if (i - lastActive >= cfg.streakGap) streakStart = i;
      lastActive = i;
    }
    if (human[i]) lastHuman = i;
    const idle = i - lastActive;
    let s;
    if (idle >= cfg.asleepAfter) s = S.asleep;
    else if (idle >= cfg.idleAfter) s = S.idle;
    else {
      const I = score(i);
      intensity[i] = I;
      const streak = i - streakStart;
      if (i - lastHuman > autopilotAfter) s = S.autopilot;
      else if ((I >= cfg.overdriveAt && streak >= cfg.lockMinStreak) || (prev === S.overdrive && I >= cfg.overdriveHold))
        s = S.overdrive;
      else if (
        (I >= cfg.lockAt && streak >= cfg.lockMinStreak) ||
        ((prev === S.locked || prev === S.overdrive) && I >= cfg.lockHold)
      )
        s = S.locked;
      else if (I >= cfg.cruiseAt) s = S.cruising;
      else s = S.warming;
    }
    state[i] = s;
    prev = s;
  }

  // ---- days ----
  const days = [];
  for (let d = 0; d < cfg.days; d++) {
    const a = Math.floor(dayStart(now, d - (cfg.days - 1)) / 60000) - startMin;
    const b = Math.min(N, Math.floor(dayStart(now, d - (cfg.days - 2)) / 60000) - startMin);
    let locked = 0;
    let engaged = 0;
    let autopilot = 0;
    let peak = 0;
    for (let i = a; i < b; i++) {
      const s = state[i];
      if (s === S.locked || s === S.overdrive) locked++;
      if (s >= S.warming && s <= S.overdrive) engaged++;
      if (s === S.autopilot) autopilot++;
      const rate = win(pTok, i, cfg.burnWindow);
      if (rate > peak) peak = rate;
    }
    days.push({
      t: dayStart(now, d - (cfg.days - 1)),
      a,
      b,
      tokens: pTok[b] - pTok[a],
      output: pOut[b] - pOut[a],
      prompts: pPrompts[b] - pPrompts[a],
      chars: pChars[b] - pChars[a],
      pasted: pPasted[b] - pPasted[a],
      tools: pTools[b] - pTools[a],
      lines: pLines[b] - pLines[a],
      activeMin: pActive[b] - pActive[a],
      engagedMin: engaged,
      lockedMin: locked,
      autopilotMin: autopilot,
      peakPerHour: Math.round((peak * 60) / cfg.burnWindow),
    });
  }
  const todayRow = days[days.length - 1];
  const past = days.slice(0, -1).filter((d) => d.activeMin >= 20);
  const minuteOfDay = N - 1 - todayIdx;
  const typicalDay = median(past.map((d) => d.tokens));
  const usualByNow = median(past.map((d) => pTok[Math.min(d.b, d.a + minuteOfDay + 1)] - pTok[d.a]));
  const typicalEngaged = median(past.map((d) => d.engagedMin));

  // The level this person usually reaches around this time of day: the middle
  // of the best level hit within half an hour either side, over their working days.
  const reached = [];
  for (const d of past) {
    let best = 0;
    const from = Math.max(d.a, d.a + minuteOfDay - 30);
    const to = Math.min(d.b, d.a + minuteOfDay + 31);
    for (let i = from; i < to; i++) {
      const level = state[i] === S.autopilot ? S.idle : state[i];
      if (level > best) best = level;
    }
    reached.push(best);
  }
  const usual = reached.length >= 3 ? STATES[Math.floor(median(reached))] : null;

  // ---- weekday x hour heatmap, averaged over the weeks on record ----
  const heat = Array.from({ length: 7 }, () => new Array(24).fill(0));
  const heatDays = new Array(7).fill(0);
  const firstDay = days.findIndex((d) => d.activeMin > 0);
  if (firstDay !== -1) {
    for (let d = firstDay; d < days.length - 1; d++) {
      const wd = new Date(days[d].t).getDay();
      heatDays[wd]++;
      for (let h = 0; h < 24; h++) {
        const a = Math.min(days[d].b, days[d].a + h * 60);
        const b = Math.min(days[d].b, a + 60);
        heat[wd][h] += pTok[b] - pTok[a];
      }
    }
    for (let wd = 0; wd < 7; wd++)
      for (let h = 0; h < 24; h++) heat[wd][h] = heatDays[wd] ? Math.round(heat[wd][h] / heatDays[wd]) : 0;
  }

  // ---- today in 5-minute bins ----
  const STEP = 5;
  const nb = Math.ceil((minuteOfDay + 1) / STEP);
  const bins = { start: today0, step: STEP, tokens: [], chars: [], prompts: [], tools: [], state: [] };
  for (let k = 0; k < nb; k++) {
    const a = todayIdx + k * STEP;
    const b = Math.min(N, a + STEP);
    bins.tokens.push(pTok[b] - pTok[a]);
    bins.chars.push(pChars[b] - pChars[a]);
    bins.prompts.push(pPrompts[b] - pPrompts[a]);
    bins.tools.push(pTools[b] - pTools[a]);
    const tally = new Uint8Array(STATES.length);
    for (let i = a; i < b; i++) tally[state[i]]++;
    let best = 0;
    for (let s = 1; s < tally.length; s++) if (tally[s] >= tally[best] && tally[s] > 0) best = s;
    bins.state.push(best);
  }

  // ---- right now ----
  const i = N - 1;
  // Rates come from the minute buckets, so they are right from the first
  // second after a restart. The current minute is only partly over, so the
  // window is that fraction plus the full minutes before it.
  const part = (now % 60000) / 60000;
  const rate = (p, w) => (win(p, i, w) * 60) / (w - 1 + part);
  const burnNow = win(pTok, i, cfg.burnWindow);
  const typeNow = win(pChars, i, cfg.typeWindow);
  const actNow = win(pActs, i, cfg.actWindow);
  const s = state[i];
  const I = intensity[i];
  let lockedRun = 0;
  for (let k = i; k >= 0 && (state[k] === S.locked || state[k] === S.overdrive); k--) lockedRun++;
  let sessions = 0;
  let agents = 0;
  for (let m = nowMin - 2; m <= nowMin; m++) {
    const g = col.minutes.get(m);
    if (!g) continue;
    if (g.ns > sessions) sessions = g.ns;
    if (g.na > agents) agents = g.na;
  }
  const idleMin = Math.min(i - lastActive, 1e6);
  const streakMin = active[i] || idleMin < cfg.streakGap ? i - streakStart : 0;

  // How hard the fire burns: the last five minutes of tokens against the baseline.
  const flamePct = pBurn((rate(pTok, 5) / 60) * cfg.burnWindow);
  const flame = win(pTok, i, 3) > 0 ? 0.12 + 0.88 * Math.pow(flamePct / 100, 1.3) : idleMin < cfg.asleepAfter ? 0.04 : 0;

  // What it takes to climb one level from here.
  const floors = { [S.warming]: 0, [S.cruising]: cfg.cruiseAt, [S.locked]: cfg.lockAt, [S.overdrive]: cfg.overdriveAt };
  let next = null;
  if (s >= S.warming && s < TOP_LEVEL) {
    const target = s + 1;
    const from = floors[s];
    const to = floors[target];
    next = {
      state: STATES[target],
      intensity: to,
      progress: Math.max(0, Math.min(1, (I - from) / (to - from))),
      // Lock-in also needs unbroken work; say how much is still missing.
      streakLeftMin: target >= S.locked ? Math.max(0, cfg.lockMinStreak - streakMin) : 0,
    };
  }

  const proj = projects(col, now, weekStartMin, startMin + todayIdx);
  const perHour = (v, w) => Math.round((v * 60) / w);
  const fam = (arr) => FAMILIES.map((name, k) => ({ name, tokens: arr[k] })).filter((m) => m.tokens > 0);

  return {
    now,
    scan: col.scan,
    live: {
      state: STATES[s],
      level: s === S.autopilot ? null : s,
      topLevel: TOP_LEVEL,
      next,
      usual,
      intensity: Math.round(I),
      hotterThan: calibrated ? Math.round(I) : null,
      tokensPerHour: Math.round(rate(pTok, 10)),
      outputPerHour: Math.round(rate(pOut, 10)),
      lastHourTokens: win(pTok, i, 60),
      flame: Math.round(flame * 1e4) / 1e4,
      idleMin,
      humanIdleMin: Math.min(i - lastHuman, 1e6),
      streakMin,
      lockedRunMin: lockedRun,
      sessions,
      agents,
      lastCallMs: col.lastCallMs,
      lastPromptMs: col.lastPromptMs,
      signals: {
        burn: { perHour: perHour(burnNow, cfg.burnWindow), pct: Math.round(pBurn(burnNow)) },
        typing: { perHour: perHour(typeNow, cfg.typeWindow), pct: Math.round(pType(typeNow)) },
        actions: { perHour: perHour(actNow, cfg.actWindow), pct: Math.round(pActn(actNow)) },
      },
    },
    today: {
      ...todayRow,
      a: undefined,
      b: undefined,
      split,
      typicalDay,
      usualByNow,
      typicalEngaged: Math.round(typicalEngaged),
      bins,
      models: fam(famToday),
      projects: proj.today,
    },
    baseline: {
      calibrated,
      activeMinutes: n,
      needMinutes: cfg.minWindows,
      daysOnRecord: days.filter((d) => d.activeMin > 0).length,
      windowDays: cfg.days,
      burn: [0.5, 0.75, 0.9].map((q) => perHour(quantile(bS, n, q), cfg.burnWindow)),
      typing: [0.5, 0.75, 0.9].map((q) => perHour(quantile(tS, n, q), cfg.typeWindow)),
      actions: [0.5, 0.75, 0.9].map((q) => perHour(quantile(aS, n, q), cfg.actWindow)),
      thresholds: { cruise: cfg.cruiseAt, lock: cfg.lockAt, overdrive: cfg.overdriveAt },
      lockMinStreak: cfg.lockMinStreak,
      autopilotAfter,
      autopilotLearned,
      promptGapsSeen: gaps.length,
      weights: cfg.weights,
    },
    history: {
      days: days.map(({ a, b, ...d }) => d),
      heat,
      models: fam(famWeek),
      projects: proj.week,
    },
  };
}
