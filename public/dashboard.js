// The dashboard: the level you are on, four numbers, today and the last 30
// days. Everything else is folded away. Burn is shown in tokens, never money.

import { STATE_META, STATE_ORDER, LADDER, drawLogo, Scene } from './robot.js';
import { compact, duration, clock, subline, levelLine, nextLine } from './format.js';
import { listen, tell } from './link.js';

const $ = (id) => document.getElementById(id);
const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]);
const pad = (n) => String(n).padStart(2, '0');
const lower = (s) => STATE_META[s].label.toLowerCase();

let data = null;
let dayMetric = 'tokens';
let state = 'asleep';

// One hue, dark to bright, for "how much".
const HEAT = ['#1c2533', '#27364d', '#34507a', '#4470ad', '#5c93dd', '#8fbcff'];

const SIGNALS = [
  { key: 'burn', name: 'Burn', what: 'tokens, last 15 min' },
  { key: 'typing', name: 'Typing', what: 'characters you typed, last 30 min' },
  { key: 'actions', name: 'Actions', what: 'prompts + tool calls, last 15 min' },
];

const DAY_METRICS = {
  tokens: { title: 'tokens per day', scale: 1, axis: compact },
  engagedMin: { title: 'hands-on time per day', scale: 1 / 60, axis: hours, nice: niceHours },
  lockedMin: { title: 'time locked in or higher, per day', scale: 1 / 60, axis: hours, nice: niceHours },
};
function hours(v) {
  if (!v) return '0';
  return v < 1 ? `${Math.round(v * 60)}m` : `${+v.toFixed(1)}h`;
}
// Axis tops for hours, chosen so the halfway gridline is a round time too.
function niceHours(v) {
  return [0.5, 1, 2, 3, 4, 6, 8, 10, 12, 16, 20, 24].find((m) => v <= m) ?? 24;
}

// ---------------------------------------------------------------- tooltip

const tip = $('tip');
function showTip(html, x, y) {
  tip.innerHTML = html;
  tip.hidden = false;
  const r = tip.getBoundingClientRect();
  let left = x + 14;
  let top = y - r.height - 12;
  if (left + r.width > innerWidth - 8) left = x - r.width - 14;
  if (top < 8) top = y + 18;
  tip.style.left = `${Math.max(8, left)}px`;
  tip.style.top = `${top}px`;
}
const hideTip = () => (tip.hidden = true);
const row = (k, v) => `<div><span class="k">${esc(k)}</span> ${esc(v)}</div>`;

// ---------------------------------------------------------------- bar chart

function niceMax(v) {
  if (!(v > 0)) return 1;
  const p = Math.pow(10, Math.floor(Math.log10(v)));
  for (const m of [1, 2, 2.5, 4, 5, 8, 10]) if (v <= m * p) return m * p;
  return 10 * p;
}

/** Thin single-series bars with a hairline grid, an optional level strip, and a hover readout. */
function barChart(el, cfg) {
  const W = Math.max(320, Math.floor(el.clientWidth));
  const H = cfg.height;
  el._cfg = cfg;
  const key = JSON.stringify([W, cfg.values, cfg.strip, cfg.xTicks, cfg.label]);
  if (el._key === key) return;
  el._key = key;

  const m = { l: 46, r: 4, t: 8, b: cfg.strip ? 36 : 24 };
  const pw = W - m.l - m.r;
  const ph = H - m.t - m.b;
  const n = cfg.values.length;
  const band = pw / n;
  const bw = Math.min(24, Math.max(1, band - (band >= 8 ? 2 : band >= 4 ? 1 : 0.5)));
  const max = (cfg.nice || niceMax)(Math.max(0, ...cfg.values));
  const base = m.t + ph;
  const y = (v) => base - (v / max) * ph;

  let s = `<svg viewBox="0 0 ${W} ${H}" role="img" aria-label="${esc(cfg.label)}">`;
  for (const v of [max, max / 2, 0]) {
    if (v) s += `<line x1="${m.l}" x2="${W - m.r}" y1="${y(v)}" y2="${y(v)}" stroke="var(--line)"/>`;
    s += `<text x="${m.l - 8}" y="${y(v) + 4}" text-anchor="end">${esc(cfg.axis(v))}</text>`;
  }
  s += `<rect class="hl" y="${m.t}" width="${band}" height="${ph}" fill="rgba(255,255,255,.07)" visibility="hidden"/>`;
  for (let i = 0; i < n; i++) {
    const v = cfg.values[i];
    if (!(v > 0)) continue;
    const h = Math.max(1.5, (v / max) * ph);
    const x = m.l + i * band + (band - bw) / 2;
    const top = base - h;
    const r = Math.min(4, bw / 2, h);
    s += `<path d="M${x},${base}V${top + r}Q${x},${top} ${x + r},${top}H${x + bw - r}Q${x + bw},${top} ${x + bw},${top + r}V${base}Z" fill="var(--series)"/>`;
  }
  s += `<line x1="${m.l}" x2="${W - m.r}" y1="${base}" y2="${base}" stroke="var(--line)"/>`;
  if (cfg.strip) {
    for (let i = 0; i < n; i++) {
      const st = cfg.strip[i];
      if (!st) continue; // asleep leaves the strip empty
      s += `<rect x="${m.l + i * band}" y="${base + 5}" width="${band + 0.4}" height="6" fill="${STATE_META[STATE_ORDER[st]].color}"/>`;
    }
  }
  for (const t of cfg.xTicks) {
    s += `<text x="${m.l + t.at * band}" y="${H - 6}" text-anchor="${t.anchor || 'middle'}">${esc(t.text)}</text>`;
  }
  el.innerHTML = s + '</svg>';
  el._geom = { m, band, n };

  if (el._wired) return;
  el._wired = true;
  el.addEventListener('mousemove', (e) => {
    const g = el._geom;
    const box = el.getBoundingClientRect();
    const i = Math.floor((e.clientX - box.left - g.m.l) / g.band);
    const hl = el.querySelector('.hl');
    if (i < 0 || i >= g.n) {
      hl.setAttribute('visibility', 'hidden');
      return hideTip();
    }
    hl.setAttribute('x', g.m.l + i * g.band);
    hl.setAttribute('visibility', 'visible');
    showTip(el._cfg.tip(i), e.clientX, e.clientY);
  });
  el.addEventListener('mouseleave', () => {
    el.querySelector('.hl')?.setAttribute('visibility', 'hidden');
    hideTip();
  });
}

// ---------------------------------------------------------------- the level

// The robot lives on the dashboard too.
const mini = new Scene($('mini'), { centered: true });
let miniSize = '';
function fitMini() {
  const box = $('mini').getBoundingClientRect();
  const size = `${Math.round(box.width)}x${Math.round(box.height)}`;
  if (!box.width || size === miniSize) return;
  miniSize = size;
  mini.resize(box.width, box.height);
}
window.burnbot = { mini, fit: fitMini }; // handle for poking at the scene from the console
function animate(now) {
  fitMini();
  mini.frame(now);
  requestAnimationFrame(animate);
}
requestAnimationFrame(animate);

function renderLevel() {
  const { live, scan, baseline, meta } = data;
  const info = STATE_META[live.state];
  state = live.state;
  document.documentElement.style.setProperty('--state', info.color);
  document.title = `${info.label} · ${compact(live.tokensPerHour)} tokens/h · Burnbot`;

  $('levelCap').textContent = levelLine(live);
  $('levelName').textContent = info.label;
  const scanning = scan.phase !== 'live';
  $('sub').textContent = scanning ? `Reading your history: ${scan.done} of ${scan.total} sessions` : `${info.blurb} · ${subline(live)}`;
  $('scan').hidden = !scanning;
  if (scanning) $('scan').firstElementChild.style.width = `${scan.total ? (scan.done / scan.total) * 100 : 5}%`;
  // Nothing to show yet: say why, instead of a page of zeros.
  $('empty').hidden = scanning || meta.foundLogs !== false;

  // how far up the scale, with a notch where each level begins
  const track = $('intTrack');
  if (!track.querySelector('u')) {
    const t = baseline.thresholds;
    track.insertAdjacentHTML('beforeend', [t.cruise, t.lock, t.overdrive].map((v) => `<u style="left:${v}%"></u>`).join(''));
  }
  track.firstElementChild.style.width = `${Math.max(1, live.intensity)}%`;
  let note = nextLine(live, live.next ? STATE_META[live.next.state].label : '');
  if (live.usual && live.usual !== live.state) note += ` · usually ${lower(live.usual)} around ${clock(data.now)}`;
  $('note').textContent = note;

  // the ladder: every level, lit up to the one you are on
  const ladder = $('ladder');
  if (!ladder.childElementCount) {
    ladder.innerHTML = [...LADDER, 'autopilot']
      .map((s) => `<span class="chip" role="listitem" data-s="${s}" style="--c:${STATE_META[s].color}" title="${esc(STATE_META[s].blurb)}"><i></i>${esc(STATE_META[s].label)}<em>usual</em></span>`)
      .join('');
  }
  for (const chip of ladder.children) {
    const s = chip.dataset.s;
    const level = STATE_META[s].level;
    chip.classList.toggle('now', s === live.state);
    chip.classList.toggle('lit', live.level !== null && level !== null && level <= live.level);
    chip.classList.toggle('usual', s === live.usual && s !== live.state);
    chip.hidden = s === 'autopilot' && live.state !== 'autopilot';
  }

  mini.setLive({ state: live.state, flame: live.flame, dropRate: live.flame > 0.1 ? 0.2 + 2.5 * live.flame ** 2 : 0 });

  if (renderLevel.icon !== live.state) {
    renderLevel.icon = live.state;
    drawLogo($('logo'), live.state);
    const icon = document.createElement('canvas');
    icon.width = icon.height = 64;
    const c = icon.getContext('2d');
    c.imageSmoothingEnabled = false;
    c.drawImage($('logo'), 0, 4, 64, 55);
    $('favicon').href = icon.toDataURL();
  }

  // The desk screen (a USB board with the robot on it), when one is plugged in.
  const desk = meta.desk;
  $('desk').hidden = !desk || desk.state === 'absent';
  if (desk && desk.state !== 'absent') {
    $('desk').classList.toggle('on', desk.state === 'connected' && desk.answering);
    $('deskFlip').hidden = desk.state !== 'connected';
    $('deskText').textContent =
      desk.state === 'connected'
        ? desk.answering ? 'Desk screen on' : 'Desk screen not answering'
        : desk.state === 'other'
          ? `Desk screen runs ${desk.program}, not Burnbot's program`
          : 'A board is plugged in but does not answer';
  }
}

function renderStats() {
  const { live, today: t } = data;
  const pace = t.usualByNow > 1000 ? `${Math.round((t.tokens / t.usualByNow) * 100)}% of your usual by ${clock(data.now)}` : 'no usual day to compare yet';
  const stats = [
    [compact(live.tokensPerHour), 'tokens per hour', 'right now'],
    [compact(t.tokens), 'burned today', pace],
    [duration(t.engagedMin), 'hands-on today', t.typicalEngaged ? `usually ${duration(t.typicalEngaged)} a day` : 'you prompting, the AI working'],
    [duration(t.lockedMin), 'locked in or higher', t.engagedMin ? `${Math.round((t.lockedMin / t.engagedMin) * 100)}% of hands-on time` : 'not yet today'],
  ];
  $('stats').innerHTML = stats.map(([value, label, sub]) => `<div><b>${esc(value)}</b><span>${esc(label)}</span><small>${esc(sub)}</small></div>`).join('');
}

// ---------------------------------------------------------------- charts

function renderToday() {
  const b = data.today.bins;
  const perHour = 60 / b.step;
  const last = b.tokens.length - 1;
  let first = b.state.findIndex((s, i) => s > 0 || b.tokens[i] > 0);
  if (first === -1) first = last;
  // Show from the hour work started to the end of the current hour, at least six hours wide.
  let from = Math.floor(first / perHour) * perHour;
  let to = Math.min(24 * perHour, (Math.floor(last / perHour) + 1) * perHour);
  if (to - from < 6 * perHour) to = Math.min(24 * perHour, from + 6 * perHour);
  if (to - from < 6 * perHour) from = Math.max(0, to - 6 * perHour);

  const slice = (a) => Array.from({ length: to - from }, (_, k) => a[from + k] ?? 0);
  const spanH = (to - from) / perHour;
  const every = spanH <= 8 ? 1 : spanH <= 16 ? 2 : 3;
  const xTicks = [];
  for (let h = from / perHour; h <= to / perHour; h += every) {
    xTicks.push({ at: h * perHour - from, text: `${pad(h)}:00`, anchor: h * perHour === to ? 'end' : h * perHour === from ? 'start' : 'middle' });
  }
  const time = (i) => {
    const mins = (from + i) * b.step;
    return `${pad(Math.floor(mins / 60))}:${pad(mins % 60)}`;
  };
  barChart($('todayChart'), {
    height: 200,
    label: 'Tokens per five minutes today',
    values: slice(b.tokens),
    strip: slice(b.state),
    axis: compact,
    xTicks,
    tip: (i) => {
      const k = from + i;
      if (k > last) return `<b>${time(i)}</b><div class="k">not yet</div>`;
      return (
        `<b>${time(i)} to ${time(i + 1)}</b>` +
        row('Level', lower(STATE_ORDER[b.state[k]])) +
        row('Tokens', compact(b.tokens[k])) +
        row('You typed', `${b.chars[k]} chars in ${b.prompts[k]} prompts`) +
        row('Tool calls', b.tools[k])
      );
    },
  });

  if (!$('stateLegend').childElementCount) {
    $('stateLegend').innerHTML = STATE_ORDER.slice(1)
      .map((s) => `<span title="${esc(STATE_META[s].blurb)}"><i style="background:${STATE_META[s].color}"></i>${lower(s)}</span>`)
      .join('');
  }
}

function renderDays() {
  const days = data.history.days;
  const metric = DAY_METRICS[dayMetric];
  const date = (d, opts = { month: 'short', day: 'numeric' }) => new Date(d.t).toLocaleDateString([], opts);
  $('daysTitle').textContent = `Last ${days.length} days`;
  const xTicks = days
    .map((d, i) => ({ d, i }))
    .filter(({ i }) => (days.length - 1 - i) % 5 === 0)
    .map(({ d, i }) => (i === days.length - 1 ? { at: i + 1, text: date(d), anchor: 'end' } : { at: i + 0.5, text: date(d) }));
  barChart($('daysChart'), {
    height: 190,
    label: `${metric.title}, last ${days.length} days`,
    values: days.map((d) => d[dayMetric] * metric.scale),
    axis: metric.axis,
    nice: metric.nice,
    xTicks,
    tip: (i) => {
      const d = days[i];
      return (
        `<b>${date(d, { weekday: 'short', month: 'short', day: 'numeric' })}</b>` +
        row('Tokens', compact(d.tokens)) +
        row('Hands-on', duration(d.engagedMin)) +
        row('Locked in or higher', duration(d.lockedMin)) +
        row('On autopilot', duration(d.autopilotMin)) +
        row('You typed', `${compact(d.chars)} chars in ${d.prompts} prompts`)
      );
    },
  });
}

// ---------------------------------------------------------------- folded away

function renderWhy() {
  const { live, baseline } = data;
  const box = $('meters');
  if (!box.childElementCount) {
    box.innerHTML = SIGNALS.map(
      (s) => `<div class="meter" data-k="${s.key}">
        <div class="top"><span><b>${s.name}</b><small>${s.what}</small></span><span><b class="v"></b><small class="p"></small></span></div>
        <div class="track"><i></i><u style="left:50%"></u><u style="left:75%"></u><u style="left:90%"></u></div>
        <div class="marks"><span style="left:50%"></span><span style="left:75%"></span><span style="left:90%"></span></div>
      </div>`,
    ).join('');
  }
  for (const s of SIGNALS) {
    const el = box.querySelector(`[data-k="${s.key}"]`);
    const sig = live.signals[s.key];
    el.querySelector('.track i').style.width = `${Math.max(1, sig.pct)}%`;
    el.querySelector('.v').textContent = `${compact(sig.perHour)}/h`;
    el.querySelector('.p').textContent = `above ${sig.pct}% of your time`;
    // The ticks are your own median, 75th and 90th percentile, in real units.
    const marks = el.querySelectorAll('.marks span');
    const names = ['your median ', '', ''];
    baseline[s.key].forEach((v, i) => (marks[i].textContent = baseline.calibrated ? names[i] + compact(v) : ''));
  }
  const t = baseline.thresholds;
  $('calNote').textContent = baseline.calibrated
    ? `Calibrated to you: ${duration(baseline.activeMinutes)} of your hands-on time over the last ${baseline.windowDays} days, updated as you work.`
    : `Still calibrating to you: ${baseline.activeMinutes} of ${baseline.needMinutes} hands-on minutes seen so far. Until then the levels use starter values.`;
  $('intNote').textContent =
    `These three are blended into one intensity (now ${live.intensity} of 100) and ranked against your own time again. ` +
    `${STATE_META.cruising.label} is anything above your quietest ${t.cruise}%, ${lower('locked')} is your top ${100 - t.lock}%, ` +
    `${lower('overdrive')} your top ${100 - t.overdrive}%. Locking in also takes ${baseline.lockMinStreak} minutes of unbroken work. ` +
    `Autopilot starts after ${baseline.autopilotAfter} minutes without a prompt` +
    (baseline.autopilotLearned ? ', learned from the gaps you usually leave.' : '.');
}

const WEEK = [1, 2, 3, 4, 5, 6, 0]; // Monday first
const WEEKDAY = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];

function renderMore() {
  const { live, today: t, history } = data;
  $('facts').innerHTML = [
    ['You typed', `${compact(t.chars)} chars in ${t.prompts} prompts`],
    ['You pasted', `${compact(t.pasted)} chars`],
    ['Output tokens', compact(t.split.output)],
    ['Code written', `${compact(t.lines)} lines`],
    ['Tool calls', compact(t.tools)],
    ['Sessions / agents now', `${live.sessions} / ${live.agents}`],
  ]
    .map(([k, v]) => `<div><dt>${esc(k)}</dt><dd>${esc(v)}</dd></div>`)
    .join('');

  // weekday x hour
  const el = $('heat');
  const heat = history.heat;
  const W = Math.max(320, Math.floor(el.clientWidth));
  const key = JSON.stringify([W, heat]);
  if (W > 320 || el.clientWidth) {
    if (el._key !== key) {
      el._key = key;
      const m = { l: 36, t: 2, b: 20 };
      const cw = (W - m.l) / 24;
      const ch = Math.max(12, Math.min(20, cw * 0.6));
      const H = m.t + 7 * (ch + 2) + m.b;
      const max = Math.max(...heat.flat());
      const level = (v) => (v > 0 && max > 0 ? Math.min(HEAT.length - 1, Math.floor((v / max) * HEAT.length)) : -1);
      let s = `<svg viewBox="0 0 ${W} ${H}" role="img" aria-label="Average tokens by weekday and hour">`;
      WEEK.forEach((wd, r) => {
        const y = m.t + r * (ch + 2);
        s += `<text x="0" y="${y + ch / 2 + 4}">${WEEKDAY[wd]}</text>`;
        for (let h = 0; h < 24; h++) {
          const l = level(heat[wd][h]);
          s += `<rect x="${m.l + h * cw + 1}" y="${y}" width="${cw - 2}" height="${ch}" rx="3" fill="${l < 0 ? 'var(--surface-2)' : HEAT[l]}"/>`;
        }
      });
      for (const h of [0, 6, 12, 18]) s += `<text x="${m.l + h * cw + 1}" y="${H - 5}">${pad(h)}:00</text>`;
      el.innerHTML = s + '</svg>';
      el._geom = { m, cw, ch };
      $('heatLegend').innerHTML = `<span>less</span><span>${HEAT.map((c) => `<i style="background:${c}"></i>`).join('')}</span><span>more · busiest hour averages ${compact(max)} tokens</span>`;
    }
    if (!el._wired) {
      el._wired = true;
      el.addEventListener('mousemove', (e) => {
        const g = el._geom;
        const box = el.getBoundingClientRect();
        const h = Math.floor((e.clientX - box.left - g.m.l) / g.cw);
        const r = Math.floor((e.clientY - box.top - g.m.t) / (g.ch + 2));
        if (h < 0 || h > 23 || r < 0 || r > 6) return hideTip();
        const wd = WEEK[r];
        showTip(`<b>${WEEKDAY[wd]} ${pad(h)}:00 to ${pad((h + 1) % 24)}:00</b>` + row('Average', `${compact(data.history.heat[wd][h])} tokens`), e.clientX, e.clientY);
      });
      el.addEventListener('mouseleave', hideTip);
    }
  }

  let rows = history.projects;
  if (rows.length > 6) {
    const rest = rows.slice(5).reduce((a, p) => a + p.tokens, 0);
    rows = [...rows.slice(0, 5), { name: `${rows.length - 5} others`, tokens: rest }];
  }
  const max = Math.max(1, ...rows.map((p) => p.tokens));
  $('projects').innerHTML = rows.length
    ? rows.map((p) => `<span class="name" title="${esc(p.name)}">${esc(p.name)}</span><span class="row"><i style="width:${(p.tokens / max) * 78}%"></i><span>${compact(p.tokens)}</span></span>`).join('')
    : '<span class="hint">Nothing in the last 7 days</span>';

  const days = history.days;
  const dayKey = JSON.stringify(days);
  if (renderMore.days !== dayKey) {
    renderMore.days = dayKey;
    const date = (d) => new Date(d.t).toLocaleDateString([], { weekday: 'short', month: 'short', day: 'numeric' });
    $('daysTable').innerHTML =
      '<thead><tr><th>Day</th><th>Tokens</th><th>Output</th><th>Prompts</th><th>Chars typed</th><th>Lines of code</th><th>Hands-on</th><th>Locked in+</th><th>Autopilot</th></tr></thead><tbody>' +
      [...days]
        .reverse()
        .map(
          (d) =>
            `<tr><td>${esc(date(d))}</td><td>${compact(d.tokens)}</td><td>${compact(d.output)}</td><td>${d.prompts}</td><td>${compact(d.chars)}</td>` +
            `<td>${compact(d.lines)}</td><td>${duration(d.engagedMin)}</td><td>${duration(d.lockedMin)}</td><td>${duration(d.autopilotMin)}</td></tr>`,
        )
        .join('') +
      '</tbody>';
  }
}

function renderFoot() {
  if (renderFoot.done) return;
  renderFoot.done = true;
  $('foot').innerHTML =
    `Burnbot reads the Claude Code session logs in <code>${esc(data.meta.source)}</code> and keeps its own history, so nothing is lost when old logs are cleared. ` +
    'Nothing leaves this Mac. Tokens count everything read and written, cached context included. ' +
    '<a href="/display?demo=cycle" target="_blank" rel="noopener">Preview every level</a>.<br>' +
    'Burnbot is an independent project. It is not made by, affiliated with, or endorsed by Anthropic. Claude and Claude Code are trademarks of Anthropic, PBC.';
}

function render() {
  renderLevel();
  renderStats();
  renderToday();
  renderDays();
  renderWhy();
  renderMore();
  renderFoot();
}

// ---------------------------------------------------------------- wiring

listen((next) => {
  data = next;
  render();
  welcome();
});
// The app tells the desk screen what each level is called; the names live in robot.js.
tell('levels', { names: Object.fromEntries(STATE_ORDER.map((s) => [s, STATE_META[s].label])) });

let resizeTimer;
addEventListener('resize', () => {
  clearTimeout(resizeTimer);
  resizeTimer = setTimeout(() => data && render(), 120);
});
// The heatmap is measured when its section opens.
for (const fold of document.querySelectorAll('details.fold')) fold.addEventListener('toggle', () => data && render());

setInterval(() => drawLogo($('logo'), state, performance.now() / 1000), 125);

$('daysSeg').addEventListener('click', (e) => {
  const btn = e.target.closest('button');
  if (!btn) return;
  dayMetric = btn.dataset.k;
  for (const b of $('daysSeg').children) b.setAttribute('aria-pressed', String(b === btn));
  if (data) renderDays();
});

$('deskFlip').addEventListener('click', () => tell('flipDesk'));

// ---- where the robot shows ----

const menu = $('screenMenu');
const screenBtn = $('screenBtn');

function closeMenu() {
  menu.hidden = true;
  screenBtn.setAttribute('aria-expanded', 'false');
}

function openMenu() {
  const screens = data?.meta?.screens ?? [];
  const item = (act, title, sub) => `<button data-act="${act}">${esc(title)}<small>${esc(sub)}</small></button>`;
  let html = item('robot:0:0', 'Robot in a small window', 'Floats in the corner; move and resize it');
  for (const d of [...screens.filter((d) => !d.primary), ...screens.filter((d) => d.primary)]) {
    html += item(`robot:${d.index}:1`, `Robot fullscreen on ${d.name}`, `${Math.round(d.width)} × ${Math.round(d.height)}${d.primary ? ' · your main screen' : ''}`);
  }
  html += '<hr>' + item('hide', 'Hide the robot', 'Bring it back from the Robot menu');
  menu.innerHTML = html;
  menu.hidden = false;
  screenBtn.setAttribute('aria-expanded', 'true');
}

screenBtn.addEventListener('click', () => (menu.hidden ? openMenu() : closeMenu()));
document.addEventListener('click', (e) => !e.target.closest('.menuwrap') && closeMenu());
document.addEventListener('keydown', (e) => e.key === 'Escape' && closeMenu());
menu.addEventListener('click', (e) => {
  const btn = e.target.closest('button[data-act]');
  if (!btn) return;
  closeMenu();
  const [kind, index, full] = btn.dataset.act.split(':');
  if (kind === 'hide') tell('hideRobot');
  else tell('robot', { index: Number(index), fullscreen: full === '1' });
});

// ---- welcome, the first time (and again from the Burnbot menu) ----

let welcomeShown = false;
function fillWelcome() {
  const { scan, baseline, meta } = data;
  $('welcomeFound').textContent =
    scan.phase !== 'live'
      ? `Reading your history: ${scan.done} of ${scan.total} sessions…`
      : !meta.foundLogs
        ? 'No activity on this Mac yet. Start a Claude Code session and the robot wakes up by itself; there is nothing to connect.'
        : baseline.calibrated
          ? `Found ${baseline.daysOnRecord} days of your work in the last ${baseline.windowDays}. Burnbot is already calibrated to you, on ${duration(baseline.activeMinutes)} of hands-on time.`
          : `Found your activity. Until it has seen two hours of your work, Burnbot uses starter values (${baseline.activeMinutes} of ${baseline.needMinutes} minutes so far).`;
  if (!$('welcomeLadder').childElementCount) {
    $('welcomeLadder').innerHTML = LADDER.map((s) => `<span class="chip lit" style="--c:${STATE_META[s].color}"><i></i>${esc(STATE_META[s].label)}</span>`).join('');
    drawLogo($('welcomeRobot'), 'cruising');
  }
}
function welcome(force = false) {
  if (!data) return;
  if (!$('welcome').hidden) return fillWelcome();
  if (!force && (welcomeShown || !data.meta.firstRun)) return;
  welcomeShown = true;
  $('optLogin').checked = Boolean(data.meta.openAtLogin);
  $('optTop').checked = data.meta.keepOnTop !== false;
  fillWelcome();
  $('welcome').hidden = false;
  $('welcomeGo').focus();
}
window.burnbotWelcome = () => welcome(true);
$('welcomeGo').addEventListener('click', () => {
  tell('openAtLogin', { on: $('optLogin').checked });
  tell('keepOnTop', { on: $('optTop').checked });
  tell('welcomed');
  $('welcome').hidden = true;
});
