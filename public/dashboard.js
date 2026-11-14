// The main screen: the level you are on, live token burn, the calibrated
// signals, today, and history. Burn is shown in tokens, never money.

import { STATE_META, STATE_ORDER, LADDER, drawLogo, Scene } from './robot.js';
import { compact, duration, clock, subline, levelLine, nextLine } from './format.js';

const $ = (id) => document.getElementById(id);
const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]);
const pad = (n) => String(n).padStart(2, '0');
const lower = (s) => STATE_META[s].label.toLowerCase();

let data = null;
let dayMetric = 'tokens';
let state = 'asleep';

// Categorical colours follow the model, never its rank (validated for colour-blind separation).
const MODEL = {
  fable: { name: 'Fable', color: '#3987e5' },
  opus: { name: 'Opus', color: '#d95926' },
  sonnet: { name: 'Sonnet', color: '#199e70' },
  haiku: { name: 'Haiku', color: '#c98500' },
  other: { name: 'Other', color: '#d55181' },
};
const HEAT = ['#3b2318', '#6b3419', '#9c471d', '#cb5c24', '#ee7c3b', '#ffb07a'];

const SIGNALS = [
  { key: 'burn', name: 'Burn', what: 'tokens, last 15 min' },
  { key: 'typing', name: 'Typing', what: 'characters you typed, last 30 min' },
  { key: 'actions', name: 'Actions', what: 'prompts + tool calls, last 15 min' },
];

const DAY_METRICS = {
  tokens: { title: 'tokens per day', scale: 1, axis: compact },
  engagedMin: { title: 'hands-on time per day', scale: 1 / 60, axis: hours, nice: niceHours },
  lockedMin: { title: 'time locked in or higher, per day', scale: 1 / 60, axis: hours, nice: niceHours },
  chars: { title: 'characters you typed per day', scale: 1, axis: compact },
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

  const m = { l: 50, r: 8, t: 10, b: cfg.strip ? 36 : 24 };
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
    if (v) s += `<line x1="${m.l}" x2="${W - m.r}" y1="${y(v)}" y2="${y(v)}" stroke="var(--grid)"/>`;
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
  s += `<line x1="${m.l}" x2="${W - m.r}" y1="${base}" y2="${base}" stroke="var(--axis)"/>`;
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

// ---------------------------------------------------------------- sections

function renderHeader() {
  const { live, scan } = data;
  const meta = STATE_META[live.state];
  state = live.state;
  document.documentElement.style.setProperty('--state', meta.color);
  $('pillText').textContent = meta.label;
  $('pillWhy').textContent = `${levelLine(live)} · ${subline(live)}`;
  document.title = `${meta.label} · ${compact(live.tokensPerHour)} tokens/h · Burnbot`;

  // The desk screen (the USB board with the robot on it), when one is plugged in.
  const desk = data.meta.desk;
  $('desk').hidden = !desk || desk.state === 'absent';
  if (desk && desk.state !== 'absent') {
    $('desk').classList.toggle('on', desk.state === 'connected' && desk.answering);
    $('deskFlip').hidden = desk.state !== 'connected';
    $('deskText').textContent =
      desk.state === 'connected'
        ? desk.answering ? 'Desk screen on' : 'Desk screen not answering'
        : desk.state === 'other'
          ? `Desk screen runs ${desk.program}: run "desk/Upload to the screen.command"`
          : 'A board is plugged in but does not answer';
  }

  const scanning = scan.phase !== 'live';
  $('scan').hidden = !scanning;
  if (scanning) {
    $('scan').firstElementChild.style.width = `${scan.total ? (scan.done / scan.total) * 100 : 5}%`;
    $('pillWhy').textContent = `Reading your Claude history: ${scan.done} of ${scan.total} sessions`;
  }

  if (renderHeader.icon !== live.state) {
    renderHeader.icon = live.state;
    drawLogo($('logo'), live.state);
    const icon = document.createElement('canvas');
    icon.width = icon.height = 64;
    const c = icon.getContext('2d');
    c.imageSmoothingEnabled = false;
    c.drawImage($('logo'), 0, 4, 64, 55);
    $('favicon').href = icon.toDataURL();
  }
}

// The robot also lives on the dashboard, in the "right now" card.
const mini = new Scene($('mini'), { centered: true });
let miniSize = '';
function fitMini() {
  const box = $('mini').getBoundingClientRect();
  const size = `${Math.round(box.width)}x${Math.round(box.height)}`;
  if (!box.width || size === miniSize) return;
  miniSize = size;
  mini.resize(box.width, box.height);
}
function animate(now) {
  fitMini();
  mini.frame(now);
  requestAnimationFrame(animate);
}
requestAnimationFrame(animate);

function renderNow() {
  const { live } = data;
  mini.setLive({ state: live.state, flame: live.flame, dropRate: live.flame > 0.1 ? 0.2 + 2.5 * live.flame ** 2 : 0 });
  $('rate').textContent = compact(live.tokensPerHour);
  $('lastHour').textContent = compact(live.lastHourTokens);
  $('outRate').textContent = compact(live.outputPerHour);
  $('sessions').textContent = `${live.sessions} / ${live.agents}`;

  // The ladder: every level, the one you are on, and the one you usually reach at this hour.
  const ladder = $('ladder');
  if (!ladder.childElementCount) {
    ladder.innerHTML = [...LADDER, 'autopilot']
      .map((s) => {
        const m = STATE_META[s];
        return `<span class="chip" role="listitem" data-s="${s}" style="--c:${m.color}" title="${esc(m.blurb)}"><b>${m.level ?? 'A'}</b>${esc(lower(s))}<em>usual now</em></span>`;
      })
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

  let line = `${STATE_META[live.state].blurb}. ${nextLine(live, live.next ? lower(live.next.state) : '')}.`;
  if (live.usual && live.usual !== live.state) line += ` Your usual level around ${clock(data.now)}: ${lower(live.usual)}.`;
  $('nowLine').textContent = line;
}

function renderMeters() {
  const { live, baseline } = data;
  const box = $('meters');
  if (!box.childElementCount) {
    box.innerHTML = SIGNALS.map(
      (s) => `<div class="meter" data-k="${s.key}">
        <div class="head">
          <span class="what"><b>${s.name}</b><small>${s.what}</small></span>
          <span class="val"><b></b><small></small></span>
        </div>
        <div class="track"><i></i><u style="left:50%"></u><u style="left:75%"></u><u style="left:90%"></u></div>
        <div class="marks"><span style="left:50%"></span><span style="left:75%"></span><span style="left:90%"></span></div>
      </div>`,
    ).join('');
    const t = baseline.thresholds;
    const cuts = [t.cruise, t.lock, t.overdrive];
    $('intTrack').insertAdjacentHTML('beforeend', cuts.map((v) => `<u style="left:${v}%"></u>`).join(''));
    $('intMarks').innerHTML = cuts.map((v) => `<span style="left:${v}%">${v}</span>`).join('');
  }
  // Nothing below is a fixed amount of tokens: every cut-off is a share of your own history.
  const t = baseline.thresholds;
  $('intNote').textContent =
    `Intensity is where this moment ranks in your own hands-on time, so the levels move with you: ` +
    `${lower('cruising')} is anything above your quietest ${t.cruise}%, ${lower('locked')} is your top ${100 - t.lock}%, ` +
    `${lower('overdrive')} your top ${100 - t.overdrive}%. Locking in also takes ${baseline.lockMinStreak} minutes of unbroken work. ` +
    `Autopilot starts after ${baseline.autopilotAfter} minutes without a prompt, ` +
    (baseline.autopilotLearned ? `learned from the ${baseline.promptGapsSeen} gaps you have left between prompts.` : 'until your own rhythm is known.');
  for (const s of SIGNALS) {
    const el = box.querySelector(`[data-k="${s.key}"]`);
    const sig = live.signals[s.key];
    el.querySelector('.track i').style.width = `${Math.max(1, sig.pct)}%`;
    el.querySelector('.val b').textContent = `${compact(sig.perHour)}/h`;
    el.querySelector('.val small').textContent = `above ${sig.pct}% of your time`;
    const marks = el.querySelectorAll('.marks span');
    // The ticks are your own median, 75th and 90th percentile, in real units.
    const names = ['your median ', '', ''];
    baseline[s.key].forEach((v, i) => (marks[i].textContent = baseline.calibrated ? names[i] + compact(v) : ''));
  }
  $('intTrack').firstElementChild.style.width = `${Math.max(1, live.intensity)}%`;
  $('intVal').textContent = live.intensity;
  $('calNote').textContent = baseline.calibrated
    ? `Calibrates itself: ${duration(baseline.activeMinutes)} of your hands-on time, last ${baseline.windowDays} days, updated as you work`
    : `Calibrating to you: ${baseline.activeMinutes} of ${baseline.needMinutes} hands-on minutes seen so far`;
}

function renderTiles() {
  const t = data.today;
  const pace = t.usualByNow > 1000 ? `${Math.round((t.tokens / t.usualByNow) * 100)}% of your usual by ${clock(data.now)}` : 'No usual day to compare yet';
  const tiles = [
    ['Burned today', `${compact(t.tokens)} tokens`, pace],
    ['Written by Claude', `${compact(t.split.output)} tokens`, `${compact(t.split.thinking)} of it thinking`],
    ['You typed', `${compact(t.chars)} chars`, `${t.prompts} prompts · ${compact(t.pasted)} pasted`],
    ['Code written', `${compact(t.lines)} lines`, `${compact(t.tools)} tool calls`],
    ['Hands-on time', duration(t.engagedMin), t.typicalEngaged ? `usually ${duration(t.typicalEngaged)} a day` : 'you prompting, Claude working'],
    [`${STATE_META.locked.label[0]}${lower('locked').slice(1)} or higher`, duration(t.lockedMin), t.engagedMin ? `${Math.round((t.lockedMin / t.engagedMin) * 100)}% of hands-on time` : 'not yet today'],
  ];
  $('tiles').innerHTML = tiles
    .map(([label, value, sub]) => `<div class="tile"><span class="label">${esc(label)}</span><b>${esc(value)}</b><small>${esc(sub)}</small></div>`)
    .join('');
}

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
    height: 230,
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
        row('Tokens', compact(b.tokens[k])) +
        row('Level', lower(STATE_ORDER[b.state[k]])) +
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
  $('daysTitle').textContent = `Last ${days.length} days, ${metric.title}`;
  const xTicks = days
    .map((d, i) => ({ d, i }))
    .filter(({ i }) => (days.length - 1 - i) % 5 === 0)
    .map(({ d, i }) => (i === days.length - 1 ? { at: i + 1, text: date(d), anchor: 'end' } : { at: i + 0.5, text: date(d) }));
  barChart($('daysChart'), {
    height: 220,
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
        row(`${lower('locked')} or higher`, duration(d.lockedMin)) +
        row('On autopilot', duration(d.autopilotMin)) +
        row('You typed', `${compact(d.chars)} chars in ${d.prompts} prompts`) +
        row('Code written', `${compact(d.lines)} lines`) +
        row('Peak', `${compact(d.peakPerHour)} tokens/h`)
      );
    },
  });

  const key = JSON.stringify(days);
  if (renderDays.key === key) return;
  renderDays.key = key;
  $('daysTable').innerHTML =
    '<thead><tr><th>Day</th><th>Tokens</th><th>Written by Claude</th><th>Prompts</th><th>Chars typed</th><th>Lines of code</th><th>Hands-on</th><th>Locked in or higher</th><th>Autopilot</th></tr></thead><tbody>' +
    [...days]
      .reverse()
      .map(
        (d) =>
          `<tr><td>${esc(date(d, { weekday: 'short', month: 'short', day: 'numeric' }))}</td><td>${compact(d.tokens)}</td><td>${compact(d.output)}</td>` +
          `<td>${d.prompts}</td><td>${compact(d.chars)}</td><td>${compact(d.lines)}</td><td>${duration(d.engagedMin)}</td>` +
          `<td>${duration(d.lockedMin)}</td><td>${duration(d.autopilotMin)}</td></tr>`,
      )
      .join('') +
    '</tbody>';
}

const WEEK = [1, 2, 3, 4, 5, 6, 0]; // Monday first
const WEEKDAY = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];

function renderHeat() {
  const el = $('heat');
  const heat = data.history.heat;
  const W = Math.max(320, Math.floor(el.clientWidth));
  const key = JSON.stringify([W, heat]);
  if (el._key === key) return;
  el._key = key;
  const m = { l: 36, t: 2, b: 20 };
  const cw = (W - m.l) / 24;
  const ch = Math.max(14, Math.min(24, cw * 0.72));
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
  $('heatLegend').innerHTML =
    `<span>0</span><span>${HEAT.map((c) => `<i style="background:${c}"></i>`).join('')}</span>` +
    `<span>${compact(max)} tokens per hour, your busiest slot</span>`;

  if (el._wired) return;
  el._wired = true;
  el.addEventListener('mousemove', (e) => {
    const g = el._geom;
    const box = el.getBoundingClientRect();
    const h = Math.floor((e.clientX - box.left - g.m.l) / g.cw);
    const r = Math.floor((e.clientY - box.top - g.m.t) / (g.ch + 2));
    if (h < 0 || h > 23 || r < 0 || r > 6) return hideTip();
    const wd = WEEK[r];
    showTip(`<b>${WEEKDAY[wd]} ${pad(h)}:00 to ${pad((h + 1) % 24)}:00</b>` + row('Average', `${compact(data.history.heat[wd][h])} tokens per hour`), e.clientX, e.clientY);
  });
  el.addEventListener('mouseleave', hideTip);
}

function renderSplit() {
  const models = data.history.models;
  const total = models.reduce((a, m) => a + m.tokens, 0);
  const info = (m) => MODEL[m.name] || MODEL.other;
  $('models').innerHTML = models
    .map((m) => {
      const share = total ? m.tokens / total : 0;
      return `<div style="flex:${Math.max(m.tokens, total * 0.004)};background:${info(m).color}" title="${info(m).name}: ${compact(m.tokens)} tokens (${Math.round(share * 100)}%)">${share >= 0.12 ? Math.round(share * 100) + '%' : ''}</div>`;
    })
    .join('');
  $('models').setAttribute('aria-label', models.map((m) => `${info(m).name} ${compact(m.tokens)} tokens`).join(', ') || 'No tokens in the last 7 days');
  $('modelLegend').innerHTML = models.map((m) => `<span><i style="background:${info(m).color}"></i>${info(m).name} ${compact(m.tokens)}</span>`).join('');

  let rows = data.history.projects;
  if (rows.length > 6) {
    const rest = rows.slice(5).reduce((a, p) => a + p.tokens, 0);
    rows = [...rows.slice(0, 5), { name: `${rows.length - 5} others`, tokens: rest }];
  }
  const max = Math.max(1, ...rows.map((p) => p.tokens));
  $('projects').innerHTML = rows.length
    ? rows
        .map(
          (p) =>
            `<span class="name" title="${esc(p.name)}">${esc(p.name)}</span>` +
            `<span class="row"><i style="width:${(p.tokens / max) * 78}%"></i><span>${compact(p.tokens)}</span></span>`,
        )
        .join('')
    : '<span class="hint">No tokens in the last 7 days</span>';
}

function renderFoot() {
  if (renderFoot.done) return;
  renderFoot.done = true;
  $('foot').innerHTML =
    `Tracking Claude Code sessions logged in <code>${esc(data.meta.source)}</code> on this Mac. ` +
    'Tokens count everything Claude read and wrote, including cached context. ' +
    'Typed characters are what you wrote into Claude, with pasted text and system messages left out. ' +
    'History is kept in <code>data/store.json</code>, so it survives when Claude Code clears old logs. ' +
    '<a href="/display?demo=cycle" target="_blank" rel="noopener">Preview every level</a>.';
}

function render() {
  renderHeader();
  renderNow();
  renderMeters();
  renderTiles();
  renderToday();
  renderDays();
  renderHeat();
  renderSplit();
  renderFoot();
}

// ---------------------------------------------------------------- wiring

const stream = new EventSource('/api/events');
stream.addEventListener('state', (e) => {
  data = JSON.parse(e.data);
  render();
});

let resizeTimer;
addEventListener('resize', () => {
  clearTimeout(resizeTimer);
  resizeTimer = setTimeout(() => data && render(), 120);
});

setInterval(() => drawLogo($('logo'), state, performance.now() / 1000), 125);

$('daysSeg').addEventListener('click', (e) => {
  const btn = e.target.closest('button');
  if (!btn) return;
  dayMetric = btn.dataset.k;
  for (const b of $('daysSeg').children) b.setAttribute('aria-pressed', String(b === btn));
  if (data) renderDays();
});

$('deskFlip').addEventListener('click', () => fetch('/api/desk/flip', { method: 'POST', headers: { 'X-Burnbot': '1' } }));

// ---- second screen menu ----

const menu = $('screenMenu');
const screenBtn = $('screenBtn');
// Inside Burnbot.app the robot is one of the app's own windows; in a browser it is a Chrome window.
const native = window.webkit?.messageHandlers?.burnbot;
const post = (url) => fetch(url, { method: 'POST', headers: { 'X-Burnbot': '1' } }).then((r) => r.json());

function closeMenu() {
  menu.hidden = true;
  screenBtn.setAttribute('aria-expanded', 'false');
}

async function openMenu() {
  const { displays, open } = await fetch('/api/displays').then((r) => r.json());
  const external = displays.filter((d) => !d.primary);
  const item = (act, title, sub) => `<button data-act="${act}">${esc(title)}<small>${esc(sub)}</small></button>`;
  let html = '';
  if (native) {
    for (const d of [...external, ...displays.filter((d) => d.primary)]) {
      html += item(`robot:${d.index}:1`, `Robot fullscreen on ${d.name}`, `${Math.round(d.width)} × ${Math.round(d.height)}${d.primary ? ' · this is your main screen' : ''}`);
    }
    html += '<hr>' + item('robot:0:0', 'Robot in a window', 'A normal window you can move and resize') + item('hide', 'Hide the robot', 'Bring it back from the Robot menu');
    menu.innerHTML = html;
    menu.hidden = false;
    screenBtn.setAttribute('aria-expanded', 'true');
    return;
  }
  for (const d of [...external, ...displays.filter((d) => d.primary)]) {
    html += item(
      `open:${d.index}`,
      `Open on ${d.name}`,
      `${Math.round(d.width)} × ${Math.round(d.height)} · fullscreen in its own window${d.primary ? ' · this is your main screen' : ''}`,
    );
  }
  if (!displays.length) html += '<button disabled>No displays detected<small>Use a browser tab instead</small></button>';
  html += '<hr>' + item('tab', 'Open in a browser tab', 'Drag it to any screen, then click it for fullscreen');
  if (open) html += item('close', 'Close the second screen', 'Quits the robot window');
  menu.innerHTML = html;
  menu.hidden = false;
  screenBtn.setAttribute('aria-expanded', 'true');
}

screenBtn.addEventListener('click', () => (menu.hidden ? openMenu() : closeMenu()));
document.addEventListener('click', (e) => !e.target.closest('.menuwrap') && closeMenu());
document.addEventListener('keydown', (e) => e.key === 'Escape' && closeMenu());
menu.addEventListener('click', async (e) => {
  const btn = e.target.closest('button[data-act]');
  if (!btn) return;
  const act = btn.dataset.act;
  closeMenu();
  if (native) {
    const [kind, index, full] = act.split(':');
    native.postMessage(kind === 'hide' ? { type: 'hideRobot' } : { type: 'robot', index: Number(index), fullscreen: full === '1' });
    return;
  }
  if (act === 'tab') return void window.open('/display', '_blank', 'noopener');
  if (act === 'close') {
    await post('/api/display/close');
    screenBtn.textContent = 'Second screen';
    return;
  }
  const result = await post(`/api/display/open?index=${act.split(':')[1]}`);
  screenBtn.textContent = result.placed ? `On ${result.screen.name}` : 'Second screen';
  if (!result.placed) alert(result.message);
});
