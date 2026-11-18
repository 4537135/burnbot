// The dashboard, in two pages.
//   Today:   the level you are on first, then how today is going.
//   History: the last week, the last month, or everything on record.
// Burn is shown in tokens, never money.

import { STATE_META, STATE_ORDER, LADDER, drawLogo, drawRobot, Scene } from './robot.js';
import { compact, duration, clock, subline, levelLine, nextLine } from './format.js';
import { listen, tell } from './link.js';

const $ = (id) => document.getElementById(id);
const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]);
const pad = (n) => String(n).padStart(2, '0');
const lower = (s) => STATE_META[s].label.toLowerCase();
const colorOf = (i) => STATE_META[STATE_ORDER[i]].color;
const labelOf = (i) => STATE_META[STATE_ORDER[i]].label;
const hhmm = (minutes) => {
  const m = Math.round(minutes);
  return `${pad(Math.floor(m / 60) % 24)}:${pad(m % 60)}`;
};
const dateOf = (d, opts = { month: 'short', day: 'numeric' }) => new Date(d.t).toLocaleDateString([], opts);
const longDate = (d) => dateOf(d, { weekday: 'short', month: 'short', day: 'numeric' });

let data = null;                              // what the tracker says now, refreshed every couple of seconds
let older = { days: [], projects: [] };       // the days before the last 30, and tokens by project over all time
let page = 'today';
let range = '7';
let state = 'asleep';

// Positions in STATE_ORDER. Asleep is never drawn: it is the empty space.
const AWAKE = [1, 2, 3, 4, 5, 6];             // chilling up to on fire, then autopilot
const WORKING = [2, 3, 4, 5, 6];              // warming up to on fire, then autopilot

// One hue, dark to bright, for "how much".
const HEAT = ['#1c2533', '#27364d', '#34507a', '#4470ad', '#5c93dd', '#8fbcff'];

const SIGNALS = [
  { key: 'burn', name: 'Burn', what: 'Tokens', span: 'last 15 min' },
  { key: 'typing', name: 'Typing', what: 'Characters you typed', span: 'last 30 min' },
  { key: 'actions', name: 'Actions', what: 'Prompts and tool calls', span: 'last 15 min' },
];

function hours(v) {
  if (!v) return '0';
  return v < 1 ? `${Math.round(v * 60)}m` : `${+v.toFixed(1)}h`;
}
// Axis tops for hours, chosen so the halfway gridline is a round time too.
function niceHours(v) {
  return [0.5, 1, 2, 3, 4, 6, 8, 10, 12, 16, 20, 24, 48, 72, 96, 120, 168].find((m) => v <= m) ?? Math.ceil(v / 24) * 24;
}
function niceMax(v) {
  if (!(v > 0)) return 1;
  const p = Math.pow(10, Math.floor(Math.log10(v)));
  for (const m of [1, 2, 2.5, 4, 5, 8, 10]) if (v <= m * p) return m * p;
  return 10 * p;
}
function share(value, total) {
  if (!(total > 0) || !(value > 0)) return '';
  const pct = Math.round((value / total) * 100);
  return pct < 1 ? '<1%' : `${pct}%`;
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
const typed = (chars, prompts) => `${compact(chars)} chars in ${prompts} ${prompts === 1 ? 'prompt' : 'prompts'}`;
const row = (k, v) => `<div><span class="k">${esc(k)}</span> ${esc(v)}</div>`;
const swatchRow = (color, k, v) => `<div><i style="background:${color}"></i><span class="k">${esc(k)}</span> ${esc(v)}</div>`;

// ---------------------------------------------------------------- charts

const nothing = (el, text = 'Nothing here yet') => {
  el.innerHTML = `<p class="nothing">${esc(text)}</p>`;
  el._geom = null;
};

/**
 * Thin square bars on a hairline grid with a hover readout, everything on whole
 * pixels. Each bar is a list of [value, colour] parts stacked from the
 * baseline, a gap of surface between them.
 */
function barChart(el, cfg) {
  const W = Math.floor(el.clientWidth);
  if (!W) return; // not on screen
  el._cfg = cfg;
  const key = JSON.stringify([W, cfg.bars, cfg.xTicks, cfg.label]);
  if (el._key === key) return;
  el._key = key;
  const totals = cfg.bars.map((parts) => parts.reduce((a, p) => a + Math.max(0, p[0]), 0));
  if (!totals.some((v) => v > 0)) return nothing(el, cfg.empty);

  const H = cfg.height;
  const m = { l: 58, r: 6, t: 8, b: 28 };
  const pw = W - m.l - m.r;
  const ph = H - m.t - m.b;
  const n = cfg.bars.length;
  const band = pw / n;
  const bw = Math.max(1, Math.min(24, Math.floor(band - (band >= 8 ? 2 : band >= 4 ? 1 : 0))));
  const max = (cfg.nice || niceMax)(Math.max(...totals));
  const base = m.t + ph;
  const y = (v) => Math.round(base - (v / max) * ph);

  let s = `<svg viewBox="0 0 ${W} ${H}" role="img" aria-label="${esc(cfg.label)}">`;
  for (const v of [max, max / 2, 0]) {
    if (v) s += `<rect x="${m.l}" y="${y(v)}" width="${pw}" height="1" fill="var(--line)"/>`;
    s += `<text x="${m.l - 10}" y="${y(v) + 5}" text-anchor="end">${esc(cfg.axis(v))}</text>`;
  }
  s += `<rect class="hl" y="${m.t}" width="${band}" height="${ph}" fill="rgba(255,255,255,.07)" visibility="hidden"/>`;
  for (let i = 0; i < n; i++) {
    const parts = cfg.bars[i].filter((p) => p[0] > 0);
    if (!parts.length) continue;
    const x = Math.round(m.l + i * band + (band - bw) / 2);
    const tall = Math.max(2, Math.round((totals[i] / max) * ph)); // a sliver still shows
    let y0 = base;
    parts.forEach(([v, color], k) => {
      const last = k === parts.length - 1;
      const top = last ? base - tall : Math.round(y0 - (v / totals[i]) * tall);
      const gap = !last && y0 - top > 3 ? 2 : 0;
      if (y0 - top - gap > 0) s += `<rect x="${x}" y="${top + gap}" width="${bw}" height="${y0 - top - gap}" fill="${color}"/>`;
      y0 = top;
    });
  }
  s += `<rect x="${m.l}" y="${base}" width="${pw}" height="2" fill="var(--line)"/>`;
  for (const t of cfg.xTicks) {
    s += `<text x="${Math.round(m.l + t.at * band)}" y="${H - 6}" text-anchor="${t.anchor || 'middle'}">${esc(t.text)}</text>`;
  }
  el.innerHTML = s + '</svg>';
  el._geom = { m, band, n };

  if (el._wired) return;
  el._wired = true;
  el.addEventListener('mousemove', (e) => {
    const g = el._geom;
    if (!g) return;
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

/** The value of a line (points sorted by x) at x, or null outside it. */
function valueAt(points, x) {
  if (!points.length || x < points[0][0] || x > points[points.length - 1][0]) return null;
  for (let i = 1; i < points.length; i++) {
    const [x0, y0] = points[i - 1];
    const [x1, y1] = points[i];
    if (x <= x1) return x1 === x0 ? y1 : y0 + ((y1 - y0) * (x - x0)) / (x1 - x0);
  }
  return points[points.length - 1][1];
}

/**
 * Lines over time on one axis, with a crosshair. Points are [x, y] with x
 * running from cfg.from to cfg.to. A line is drawn as steps on a 3-pixel grid,
 * so it reads as pixels rather than as a smooth curve.
 */
function lineChart(el, cfg) {
  const W = Math.floor(el.clientWidth);
  if (!W) return;
  el._cfg = cfg;
  const key = JSON.stringify([W, cfg.lines.map((l) => l.points), cfg.from, cfg.to, cfg.max]);
  if (el._key === key) return;
  el._key = key;

  const H = cfg.height;
  const m = { l: 58, r: 12, t: 10, b: 28 };
  const pw = W - m.l - m.r;
  const ph = H - m.t - m.b;
  const base = m.t + ph;
  const STEP = 3;
  const snap = (v) => Math.round(v / STEP) * STEP;
  const X = (x) => m.l + snap(((x - cfg.from) / (cfg.to - cfg.from)) * pw);
  const Y = (v) => base - snap((v / cfg.max) * ph);

  let s = `<svg viewBox="0 0 ${W} ${H}" role="img" aria-label="${esc(cfg.label)}">`;
  for (const v of [cfg.max, cfg.max / 2, 0]) {
    s += `<rect x="${m.l}" y="${Y(v)}" width="${pw}" height="${v ? 1 : 2}" fill="var(--line)"/>`;
    s += `<text x="${m.l - 10}" y="${Y(v) + 5}" text-anchor="end">${esc(cfg.axis(v))}</text>`;
  }
  s += `<rect class="cross" y="${m.t}" width="1" height="${ph}" fill="#4a5568" visibility="hidden"/>`;
  for (const line of cfg.lines) {
    if (line.points.length < 2) continue;
    // along, then up: the value holds until the next reading
    const d = line.points.map(([x, v], i) => (i ? `H${X(x)}V${Y(v)}` : `M${X(x)},${Y(v)}`)).join('');
    const end = line.points[line.points.length - 1];
    if (line.area) s += `<path d="${d}V${base}H${X(line.points[0][0])}Z" fill="${line.color}" opacity=".1"/>`;
    s += `<path d="${d}" fill="none" stroke="${line.color}" stroke-width="${line.area ? 3 : 2}" stroke-linejoin="miter"/>`;
    if (line.dot) s += `<rect x="${X(end[0]) - 5}" y="${Y(end[1]) - 5}" width="10" height="10" fill="${line.color}" stroke="var(--surface)" stroke-width="2"/>`;
  }
  for (const line of cfg.lines) s += `<rect class="mark" width="10" height="10" fill="${line.color}" stroke="var(--surface)" stroke-width="2" visibility="hidden"/>`;
  for (const t of cfg.xTicks) {
    s += `<text x="${X(t.x)}" y="${H - 6}" text-anchor="${t.anchor || 'middle'}">${esc(t.text)}</text>`;
  }
  el.innerHTML = s + '</svg>';
  el._geom = { m, pw, X, Y };

  if (el._wired) return;
  el._wired = true;
  el.addEventListener('mousemove', (e) => {
    const g = el._geom;
    const c = el._cfg;
    const box = el.getBoundingClientRect();
    const f = (e.clientX - box.left - g.m.l) / g.pw;
    const cross = el.querySelector('.cross');
    const marks = el.querySelectorAll('.mark');
    if (f < 0 || f > 1) {
      cross.setAttribute('visibility', 'hidden');
      marks.forEach((mk) => mk.setAttribute('visibility', 'hidden'));
      return hideTip();
    }
    const x = c.from + f * (c.to - c.from);
    cross.setAttribute('x', g.X(x));
    cross.setAttribute('visibility', 'visible');
    c.lines.forEach((line, i) => {
      const v = valueAt(line.points, x);
      marks[i].setAttribute('visibility', v === null ? 'hidden' : 'visible');
      if (v !== null) {
        marks[i].setAttribute('x', g.X(x) - 5);
        marks[i].setAttribute('y', g.Y(v) - 5);
      }
    });
    showTip(c.tip(x), e.clientX, e.clientY);
  });
  el.addEventListener('mouseleave', () => {
    el.querySelector('.cross')?.setAttribute('visibility', 'hidden');
    el.querySelectorAll('.mark').forEach((mk) => mk.setAttribute('visibility', 'hidden'));
    hideTip();
  });
}

/** One whole split into parts: a thin bar, and each part listed under it with its amount and share. */
function splitList(el, parts, label) {
  const key = JSON.stringify(parts);
  if (el._key === key) return;
  el._key = key;
  const total = parts.reduce((a, p) => a + p.value, 0);
  if (!total) return nothing(el);
  el.innerHTML =
    `<div class="split" role="img" aria-label="${esc(label)}">` +
    parts
      .filter((p) => p.value > 0)
      .map((p) => `<i style="flex:${p.value} 1 0;background:${p.color}" title="${esc(p.name)}: ${esc(duration(p.value))}, ${share(p.value, total)}"></i>`)
      .join('') +
    '</div><div class="parts">' +
    parts
      .map((p) => {
        const off = p.value ? '' : ' off';
        return (
          `<i class="${off}" style="background:${p.color}"></i><span class="name${off}">${esc(p.name)}</span>` +
          `<span class="val${off}">${p.value ? esc(duration(p.value)) : '–'}</span><span class="pct${off}">${share(p.value, total)}</span>`
        );
      })
      .join('') +
    '</div>';
}

/** One row per day, midnight to midnight, coloured by the level of each quarter hour. */
function timeline(el, days) {
  const W = Math.floor(el.clientWidth);
  if (!W) return;
  const key = JSON.stringify([W, days.map((d) => [d.t, d.strip])]);
  if (el._key === key) return;
  el._key = key;
  el._days = days;

  const n = days.length;
  const rh = n <= 7 ? 20 : n <= 14 ? 14 : 8;
  const gap = n <= 14 ? 4 : 2;
  const m = { l: 96, r: 6, t: 2, b: 28 };
  const pw = W - m.l - m.r;
  const cw = pw / 96;
  const H = m.t + n * (rh + gap) - gap + m.b;
  let s = `<svg viewBox="0 0 ${W} ${H}" role="img" aria-label="Your level through each day">`;
  days.forEach((d, r) => {
    const y = m.t + r * (rh + gap);
    const monday = new Date(d.t).getDay() === 1;
    if (n <= 14 || monday || r === 0) {
      s += `<text x="0" y="${y + rh / 2 + 5}"${r === 0 ? ' class="strong"' : ''}>${esc(r === 0 ? 'Today' : longDate(d).replace(',', ''))}</text>`;
    }
    s += `<rect x="${m.l}" y="${y}" width="${Math.round(pw)}" height="${rh}" fill="var(--series-track)"/>`;
    const strip = d.strip || '';
    for (let q = 0; q < strip.length; ) {
      let e = q + 1;
      while (e < strip.length && strip[e] === strip[q]) e++;
      if (strip[q] !== '0') {
        const x0 = Math.round(m.l + q * cw);
        s += `<rect x="${x0}" y="${y}" width="${Math.max(1, Math.round(m.l + e * cw) - x0 - (cw > 4 ? 2 : 0))}" height="${rh}" fill="${colorOf(Number(strip[q]))}"/>`;
      }
      q = e;
    }
  });
  for (let h = 0; h <= 24; h += 3) {
    s += `<text x="${Math.round(m.l + h * 4 * cw)}" y="${H - 6}" text-anchor="${h === 0 ? 'start' : h === 24 ? 'end' : 'middle'}">${pad(h)}:00</text>`;
  }
  el.innerHTML = s + '</svg>';
  el._geom = { m, cw, rh, gap };

  if (el._wired) return;
  el._wired = true;
  el.addEventListener('mousemove', (e) => {
    const g = el._geom;
    const box = el.getBoundingClientRect();
    const q = Math.floor((e.clientX - box.left - g.m.l) / g.cw);
    const r = Math.floor((e.clientY - box.top - g.m.t) / (g.rh + g.gap));
    const d = el._days[r];
    if (!d || q < 0 || q > 95) return hideTip();
    const level = d.strip?.[q];
    showTip(
      `<b>${esc(r === 0 ? 'Today' : longDate(d))} · ${hhmm(q * 15)} to ${hhmm(q * 15 + 15)}</b>` +
        (level === undefined ? '<div class="k">not yet</div>' : swatchRow(colorOf(Number(level)), 'Level', labelOf(Number(level)))),
      e.clientX,
      e.clientY,
    );
  });
  el.addEventListener('mouseleave', hideTip);
}

function levelLegend(el, which) {
  if (el.childElementCount) return;
  el.innerHTML = which.map((i) => `<span title="${esc(STATE_META[STATE_ORDER[i]].blurb)}"><i style="background:${colorOf(i)}"></i>${esc(labelOf(i))}</span>`).join('');
}

function rankList(el, rows, emptyText) {
  if (rows.length > 6) {
    const rest = rows.slice(5).reduce((a, p) => a + p.tokens, 0);
    rows = [...rows.slice(0, 5), { name: `${rows.length - 5} others`, tokens: rest }];
  }
  const max = Math.max(1, ...rows.map((p) => p.tokens));
  el.innerHTML = rows.length
    ? rows.map((p) => `<span class="name" title="${esc(p.name)}">${esc(p.name)}</span><span class="row"><i style="width:${(p.tokens / max) * 72}%"></i><span>${compact(p.tokens)}</span></span>`).join('')
    : `<span class="hint">${esc(emptyText)}</span>`;
}

const statTiles = (el, tiles) =>
  (el.innerHTML = tiles.map(([value, label, sub, cls]) => `<div><b>${esc(value)}</b><span>${esc(label)}</span><small${cls ? ` class="${cls}"` : ''}>${esc(sub)}</small></div>`).join(''));

// ---------------------------------------------------------------- always on screen

function renderChrome() {
  const { live, scan, meta } = data;
  const info = STATE_META[live.state];
  state = live.state;
  document.documentElement.style.setProperty('--state', info.color);
  document.title = `${info.label} · ${compact(live.tokensPerHour)} tokens/h · Burnbot`;

  const scanning = scan.phase !== 'live';
  $('scan').hidden = !scanning;
  if (scanning) $('scan').firstElementChild.style.width = `${scan.total ? (scan.done / scan.total) * 100 : 5}%`;
  // Nothing to show yet: say why, instead of a page of zeros.
  $('empty').hidden = scanning || meta.foundLogs !== false;

  if (renderChrome.icon !== live.state) {
    renderChrome.icon = live.state;
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
    $('desk').title = desk.outdated
      ? 'An older program: it may be missing the robot\'s faces, speech bubbles, daily goal or knock. To update it, double-click "Upload to the screen" in the desk folder.'
      : '';
    $('deskText').textContent =
      desk.state === 'connected'
        ? !desk.answering ? 'Desk screen not answering' : desk.outdated ? 'Desk screen on · old program' : 'Desk screen on'
        : desk.state === 'other'
          ? `Desk screen runs ${desk.program}, not Burnbot's program`
          : 'A board is plugged in but does not answer';
  }
}

// ---------------------------------------------------------------- Today: the level

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
function animate(now) {
  if (page === 'today') {
    fitMini();
    mini.frame(now);
  }
  requestAnimationFrame(animate);
}
requestAnimationFrame(animate);

function renderLevel() {
  const { live, scan, baseline } = data;
  const info = STATE_META[live.state];
  $('levelCap').textContent = levelLine(live);
  $('levelName').textContent = info.label;
  // While you work, say how the pace compares; at rest the one line is enough.
  const working = ['warming', 'cruising', 'locked', 'overdrive'].includes(live.state);
  $('sub').textContent =
    scan.phase !== 'live' ? `Reading your history: ${scan.done} of ${scan.total} sessions` : working ? `${info.blurb} · ${subline(live)}` : subline(live);

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
}

function renderStats() {
  const { live, today: t } = data;
  const pace = t.usualByNow > 1000 ? `${Math.round((t.tokens / t.usualByNow) * 100)}% of your usual by ${clock(data.now)}` : 'no usual day to compare yet';
  statTiles($('stats'), [
    [compact(live.tokensPerHour), 'tokens per hour', 'right now'],
    [compact(t.tokens), 'burned today', pace],
    [duration(t.engagedMin), 'hands-on today', t.typicalEngaged ? `usually ${duration(t.typicalEngaged)} a day` : 'you prompting, the AI working'],
    [duration(t.lockedMin), 'locked in or higher', t.engagedMin ? `${Math.round((t.lockedMin / t.engagedMin) * 100)}% of hands-on time` : 'not yet today'],
  ]);
}

// A win is red turning green, a session that shipped (once a day however many commits),
// a pull request, or a plan you approved. The goal is your usual number of them, or yours.
function renderGoal() {
  const g = data.goal;
  $('goalCard').hidden = !g;
  if (!g) return;
  const k = data.today.winKinds || {};
  $('goalBody').classList.toggle('hit', g.hitToday);
  $('goalWins').innerHTML = `${g.wins}<small> / ${g.target} wins</small>`;
  $('goalPips').innerHTML = Array.from({ length: Math.min(g.target, 12) }, (_, i) => `<i class="${i < g.wins ? 'on' : ''}"></i>`).join('');
  const parts = [
    [k.greens, 'red to green', 'red to green'],
    [k.commits, 'session shipped', 'sessions shipped'],
    [k.prs, 'pull request', 'pull requests'],
    [k.plans, 'plan approved', 'plans approved'],
  ].filter(([n]) => n > 0).map(([n, one, many]) => `${n} ${n === 1 ? one : many}`);
  const streak = g.streak > 0 ? `${g.streak}-day streak${g.hitToday ? '' : ' so far'}` : 'No streak yet';
  $('goalKinds').innerHTML = `${esc(parts.length ? parts.join(' · ') : 'No wins yet today')}<small>${esc(streak)} · a day under 30 min hands-on does not break it</small>`;
  $('goalHint').textContent = g.auto
    ? g.workingDays >= 7 ? `Auto: your usual day, ${g.suggested} wins` : `Auto: ${g.suggested} until a week of work shows your usual`
    : `Set by you · auto would be ${g.suggested}`;
  $('goalAuto').setAttribute('aria-pressed', String(g.auto));
  $('goalLess').disabled = g.target <= 1;
}

// ---------------------------------------------------------------- Today: the graphs

function renderBurn() {
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

  const spanH = (to - from) / perHour;
  const every = spanH <= 8 ? 1 : spanH <= 16 ? 2 : 3;
  const xTicks = [];
  for (let h = from / perHour; h <= to / perHour; h += every) {
    xTicks.push({ at: h * perHour - from, text: `${pad(h)}:00`, anchor: h * perHour === to ? 'end' : h * perHour === from ? 'start' : 'middle' });
  }
  barChart($('burnChart'), {
    height: 210,
    label: 'Tokens per five minutes today, coloured by level',
    empty: 'Nothing burned yet today',
    bars: Array.from({ length: to - from }, (_, i) => [[b.tokens[from + i] ?? 0, colorOf(b.state[from + i] || 1)]]),
    axis: compact,
    xTicks,
    tip: (i) => {
      const k = from + i;
      const span = `${hhmm(k * b.step)} to ${hhmm((k + 1) * b.step)}`;
      if (k > last) return `<b>${span}</b><div class="k">not yet</div>`;
      return (
        `<b>${span}</b>` +
        swatchRow(colorOf(b.state[k]), 'Level', labelOf(b.state[k])) +
        row('Tokens', compact(b.tokens[k])) +
        row('You typed', typed(b.chars[k], b.prompts[k])) +
        row('Tool calls', b.tools[k])
      );
    },
  });
  levelLegend($('burnLegend'), AWAKE);
}

function renderPace() {
  const t = data.today;
  const b = t.bins;
  const usual = t.usualCurve ?? [];
  const usualEnd = usual[95] ?? 0;
  const hasUsual = (t.usualDays ?? 0) >= 1 && usualEnd > 0;
  const nowMin = Math.min(1440, (data.now - b.start) / 60000);

  // Tokens burned by each moment of the day: today up to now, and a usual day in full.
  const mine = [[0, 0]];
  let sum = 0;
  b.tokens.forEach((v, k) => mine.push([Math.min(nowMin, (k + 1) * b.step), (sum += v)]));
  const theirs = hasUsual ? [[0, 0], ...usual.map((v, q) => [(q + 1) * 15, v])] : [];

  // The hours worth showing: from where either starts to where both are done.
  const firstBin = b.tokens.findIndex((v) => v > 0);
  const startMine = firstBin < 0 ? nowMin : firstBin * b.step;
  const startUsual = hasUsual ? usual.findIndex((v) => v > usualEnd * 0.005) * 15 : 1440;
  const stopUsual = hasUsual ? (usual.findIndex((v) => v >= usualEnd * 0.995) + 1) * 15 : 0;
  let from = Math.floor(Math.min(startMine, startUsual) / 60) * 60;
  let to = Math.min(1440, Math.ceil(Math.max(nowMin, stopUsual) / 60) * 60);
  if (to - from < 360) to = Math.min(1440, from + 360);
  if (to - from < 360) from = Math.max(0, to - 360);
  const clip = (points) => {
    const inside = points.filter(([x]) => x > from && x <= to);
    const start = valueAt(points, from);
    return start === null ? inside : [[from, start], ...inside];
  };

  const usualNow = hasUsual ? valueAt(theirs, nowMin) : 0;
  $('paceLegend').innerHTML =
    `<span><i class="key" style="background:var(--ink)"></i>Today <b>${compact(sum)}</b></span>` +
    (hasUsual ? `<span><i class="key" style="background:var(--muted)"></i>Usual day <b>${compact(usualNow)}</b> by now, ${compact(usualEnd)} by the end</span>` : '');
  const ratio = usualNow > 1000 ? sum / usualNow : null;
  $('paceHint').textContent =
    ratio === null
      ? 'No usual day to compare with yet'
      : Math.abs(ratio - 1) < 0.03
        ? 'Right on your usual'
        : ratio > 1
          ? ratio >= 3 ? `${ratio.toFixed(1)} times your usual` : `${Math.round((ratio - 1) * 100)}% ahead of your usual`
          : `${Math.round((1 - ratio) * 100)}% behind your usual`;

  const spanH = (to - from) / 60;
  const every = spanH <= 8 ? 1 : spanH <= 16 ? 2 : 3;
  const xTicks = [];
  for (let h = from / 60; h <= to / 60; h += every) xTicks.push({ x: h * 60, text: `${pad(h)}:00`, anchor: h * 60 === to ? 'end' : h * 60 === from ? 'start' : 'middle' });

  lineChart($('paceChart'), {
    height: 220,
    label: 'Tokens burned so far today against a usual day',
    from,
    to,
    max: niceMax(Math.max(sum, hasUsual ? valueAt(theirs, to) : 0, 1)),
    axis: compact,
    xTicks,
    lines: [
      { points: clip(theirs), color: 'var(--muted)' },
      { points: clip(mine), color: 'var(--ink)', area: true, dot: true },
    ],
    tip: (x) => {
      const m = valueAt(mine, x);
      const u = hasUsual ? valueAt(theirs, x) : null;
      return `<b>By ${hhmm(x)}</b>` + (m === null ? '' : row('Today', compact(m))) + (u === null ? '' : row('Usual day', compact(u)));
    },
  });
}

const levelParts = (levelMin) => AWAKE.map((i) => ({ name: labelOf(i), color: colorOf(i), value: levelMin?.[i] ?? 0 }));

function renderLevelsToday() {
  const parts = levelParts(data.today.levelMin);
  const total = parts.reduce((a, p) => a + p.value, 0);
  $('levelsTodayHint').textContent = total ? `${duration(total)} today` : '';
  splitList($('levelsToday'), parts, 'Time on each level today');
}

function renderWhy() {
  const { live, baseline } = data;
  const box = $('meters');
  if (!box.childElementCount) {
    box.innerHTML = SIGNALS.map(
      (s) => `<div class="meter" data-k="${s.key}">
        <div class="top"><b>${s.name}</b><span class="v"></span></div>
        <div class="track"><i></i><u style="left:50%"></u><u style="left:75%"></u><u style="left:90%"></u></div>
        <small class="p"></small><small class="w"></small>
      </div>`,
    ).join('');
  }
  for (const s of SIGNALS) {
    const el = box.querySelector(`[data-k="${s.key}"]`);
    const sig = live.signals[s.key];
    el.querySelector('.track i').style.width = `${Math.max(1, sig.pct)}%`;
    el.querySelector('.v').textContent = `${compact(sig.perHour)}/h`;
    el.querySelector('.p').textContent = `Above ${sig.pct}% of your working time`;
    el.querySelector('.w').textContent = `${s.what}, ${s.span}` + (baseline.calibrated ? ` · your median ${compact(baseline[s.key][0])}/h` : '');
  }
  const t = baseline.thresholds;
  $('calNote').textContent = baseline.calibrated
    ? `Calibrated to you on ${duration(baseline.activeMinutes)} of your work`
    : `Still calibrating: ${baseline.activeMinutes} of ${baseline.needMinutes} minutes seen`;
  $('intNote').textContent =
    `Each bar is ranked against your own last ${baseline.windowDays} days; the notches are your median, top 25% and top 10%. ` +
    `The three are blended into one intensity (now ${live.intensity} of 100) and ranked against you again. ` +
    `${STATE_META.cruising.label} is anything above your quietest ${t.cruise}%, ${lower('locked')} is your top ${100 - t.lock}%, ` +
    `${lower('overdrive')} your top ${100 - t.overdrive}%. Locking in also takes ${baseline.lockMinStreak} minutes of unbroken work. ` +
    `Autopilot starts after ${baseline.autopilotAfter} minutes without a prompt` +
    (baseline.autopilotLearned ? ', learned from the gaps you usually leave.' : '.') +
    (baseline.calibrated ? '' : ' Until Burnbot has seen two hours of your work it uses starter values.');
}

function renderAlso() {
  const { today: t } = data;
  $('facts').innerHTML = [
    ['You typed', `${compact(t.chars)} characters`],
    ['Prompts sent', compact(t.prompts)],
    ['Code written', `${compact(t.lines)} lines`],
    ['Tool calls', compact(t.tools)],
    ['Output tokens', compact(t.split.output)],
    ['You pasted', `${compact(t.pasted)} characters`],
  ]
    .map(([k, v]) => `<div><dt>${esc(k)}</dt><dd>${esc(v)}</dd></div>`)
    .join('');
  rankList($('projectsToday'), t.projects, 'Nothing yet today');
}

// ---------------------------------------------------------------- History

const SUMMED = ['tokens', 'output', 'prompts', 'chars', 'pasted', 'tools', 'lines', 'activeMin', 'engagedMin', 'lockedMin', 'autopilotMin'];

/** Several days as one: every count added up. */
function sumDays(days) {
  const total = { t: days[0]?.t ?? 0, days, levelMin: [0, 0, 0, 0, 0, 0, 0] };
  for (const k of SUMMED) total[k] = 0;
  for (const d of days) {
    for (const k of SUMMED) total[k] += d[k] || 0;
    (d.levelMin || []).forEach((v, i) => (total.levelMin[i] += v));
  }
  return total;
}

const allDays = () => [...older.days, ...data.history.days];

function rangeDays() {
  const all = allDays();
  if (range !== 'all') return all.slice(-Number(range));
  const first = all.findIndex((d) => d.activeMin > 0 || d.tokens > 0);
  return first < 0 || all.length - first < 7 ? all.slice(-7) : all.slice(first);
}

/** A bar per day, or per week once there are too many days to tell apart. */
function buckets(days) {
  if (days.length <= 92) return { weekly: false, list: days.map((d) => sumDays([d])) };
  const weeks = new Map();
  for (const d of days) {
    const at = new Date(d.t);
    const monday = new Date(at.getFullYear(), at.getMonth(), at.getDate() - ((at.getDay() + 6) % 7)).getTime();
    if (!weeks.has(monday)) weeks.set(monday, []);
    weeks.get(monday).push(d);
  }
  return { weekly: true, list: [...weeks.entries()].map(([t, list]) => ({ ...sumDays(list), t })) };
}

function bucketTicks(list, weekly) {
  const n = list.length;
  if (n <= 7 && !weekly) return list.map((d, i) => ({ at: i + 0.5, text: i === n - 1 ? 'Today' : dateOf(d, { weekday: 'short' }) }));
  const step = n <= 16 ? 2 : n <= 31 ? 5 : Math.ceil(n / 8);
  return list
    .map((d, i) => ({ d, i }))
    .filter(({ i }) => (n - 1 - i) % step === 0)
    .map(({ d, i }) => (i === n - 1 ? { at: i + 1, text: weekly ? dateOf(d) : 'Today', anchor: 'end' } : { at: i + 0.5, text: dateOf(d) }));
}

function topLevel(d) {
  for (let i = 5; i >= 1; i--) if (d.levelMin?.[i] > 0) return labelOf(i);
  return '–';
}

function renderHistory() {
  const days = rangeDays();
  const n = days.length;
  const total = sumDays(days);
  const all = allDays();
  const before = range !== 'all' && all.length >= 2 * n ? sumDays(all.slice(-2 * n, -n)) : null;
  const { weekly, list } = buckets(days);
  const per = weekly ? 'week' : 'day';
  const when = (d) => (weekly ? `Week of ${dateOf(d)}` : longDate(d));

  $('histSpan').textContent = `${dateOf(days[0], { month: 'short', day: 'numeric', year: 'numeric' })} to today · ${n} days`;

  // ---- the headline numbers for this stretch
  const worked = days.filter((d) => d.activeMin > 0);
  const best = days.reduce((a, d) => (d.tokens > a.tokens ? d : a), days[0]);
  let versus = range === 'all' ? 'everything on record' : `no ${n} days before these to compare`;
  let dir = '';
  if (before && before.tokens > 0) {
    const change = total.tokens / before.tokens - 1;
    dir = change >= 0 ? 'up' : 'down';
    versus = `${Math.abs(change) >= 2 ? `${(change + 1).toFixed(1)} times` : `${Math.round(Math.abs(change) * 100)}% ${change >= 0 ? 'more than' : 'less than'}`} the ${n} days before`;
  }
  statTiles($('histStats'), [
    [compact(total.tokens), 'tokens burned', versus, dir],
    [duration(total.engagedMin), 'hands-on time', worked.length ? `${duration(total.engagedMin / worked.length)} a day when you worked` : 'you prompting, the AI working'],
    [duration(total.lockedMin), 'locked in or higher', total.engagedMin ? `${Math.round((total.lockedMin / total.engagedMin) * 100)}% of hands-on time` : 'none yet'],
    [`${worked.length} of ${n}`, 'days worked', best.tokens > 0 ? `biggest: ${longDate(best)}, ${compact(best.tokens)}` : 'no work on record'],
  ]);

  // ---- tokens, one bar a day
  const xTicks = bucketTicks(list, weekly);
  $('histTokensTitle').textContent = `Tokens per ${per}`;
  $('histTokensHint').textContent = worked.length ? `${compact(total.tokens / worked.length)} on an average working day` : '';
  barChart($('histTokens'), {
    height: 200,
    label: `Tokens per ${per}`,
    bars: list.map((d) => [[d.tokens, 'var(--series)']]),
    axis: compact,
    xTicks,
    tip: (i) => {
      const d = list[i];
      return (
        `<b>${esc(when(d))}</b>` +
        row('Tokens', compact(d.tokens)) +
        row('Hands-on', duration(d.engagedMin)) +
        row('Locked in or higher', duration(d.lockedMin)) +
        row('You typed', typed(d.chars, d.prompts)) +
        row('Code written', `${compact(d.lines)} lines`)
      );
    },
  });

  // ---- hours on each level, stacked
  $('histLevelsTitle').textContent = `Time on each level, per ${per}`;
  barChart($('histLevels'), {
    height: 200,
    label: `Hours on each level per ${per}`,
    bars: list.map((d) => WORKING.map((i) => [d.levelMin[i] / 60, colorOf(i)])),
    axis: hours,
    nice: niceHours,
    xTicks,
    tip: (i) => {
      const d = list[i];
      const rows = WORKING.filter((k) => d.levelMin[k] > 0)
        .reverse()
        .map((k) => swatchRow(colorOf(k), labelOf(k), duration(d.levelMin[k])));
      return `<b>${esc(when(d))}</b>` + (rows.length ? rows.join('') : '<div class="k">no work</div>');
    },
  });
  levelLegend($('histLevelsLegend'), WORKING);

  // ---- the whole stretch split by level, and by project
  const parts = levelParts(total.levelMin);
  const awake = parts.reduce((a, p) => a + p.value, 0);
  $('levelsRangeHint').textContent = awake ? `${duration(awake)} in all` : '';
  splitList($('levelsRange'), parts, 'Time on each level');
  const projects = range === '7' ? data.history.projects : range === '30' ? data.history.projectsMonth ?? [] : older.projects.length ? older.projects : data.history.projectsMonth ?? [];
  rankList($('projects'), projects, 'Nothing in this stretch');

  // ---- each day, hour by hour (the last 30 days keep this much detail)
  const detailed = data.history.days.slice(-Math.min(30, n)).reverse();
  $('timelineHint').textContent = n > 30 ? 'The last 30 days. Each row is a day, midnight to midnight' : 'Each row is a day, midnight to midnight';
  timeline($('timeline'), detailed);
  levelLegend($('timelineLegend'), AWAKE);

  if ($('foldWeek').open) renderHeat();
  if ($('foldDays').open) renderTable(days);
}

const WEEK = [1, 2, 3, 4, 5, 6, 0]; // Monday first
const WEEKDAY = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];

function renderHeat() {
  const el = $('heat');
  const heat = data.history.heat;
  const W = Math.floor(el.clientWidth);
  if (!W) return;
  const key = JSON.stringify([W, heat]);
  if (el._key !== key) {
    el._key = key;
    const m = { l: 44, t: 2, b: 26 };
    const cw = Math.floor((W - m.l) / 24);
    const ch = Math.max(14, Math.min(22, Math.round(cw * 0.6)));
    const H = m.t + 7 * (ch + 2) + m.b;
    const max = Math.max(...heat.flat());
    const level = (v) => (v > 0 && max > 0 ? Math.min(HEAT.length - 1, Math.floor((v / max) * HEAT.length)) : -1);
    let s = `<svg viewBox="0 0 ${W} ${H}" role="img" aria-label="Average tokens by weekday and hour">`;
    WEEK.forEach((wd, r) => {
      const y = m.t + r * (ch + 2);
      s += `<text x="0" y="${y + ch / 2 + 5}">${WEEKDAY[wd]}</text>`;
      for (let h = 0; h < 24; h++) {
        const l = level(heat[wd][h]);
        s += `<rect x="${m.l + h * cw}" y="${y}" width="${cw - 2}" height="${ch}" fill="${l < 0 ? 'var(--surface-2)' : HEAT[l]}"/>`;
      }
    });
    for (const h of [0, 6, 12, 18]) s += `<text x="${m.l + h * cw}" y="${H - 6}">${pad(h)}:00</text>`;
    el.innerHTML = s + '</svg>';
    el._geom = { m, cw, ch };
    $('heatLegend').innerHTML = `<span>less</span><span>${HEAT.map((c) => `<i style="background:${c}"></i>`).join('')}</span><span>more · the busiest hour averages ${compact(max)} tokens</span>`;
  }
  if (el._wired) return;
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

function renderTable(days) {
  const time = (minutes) => (minutes > 0 ? duration(minutes) : '–');
  const key = JSON.stringify(days.map((d) => [d.t, d.tokens, d.engagedMin, d.chars]));
  if (renderTable.key === key) return;
  renderTable.key = key;
  $('daysTable').innerHTML =
    '<thead><tr><th>Day</th><th>Tokens</th><th>Hands-on</th><th>Locked in+</th><th>Autopilot</th><th>Top level</th><th>Prompts</th><th>Chars typed</th><th>Lines of code</th></tr></thead><tbody>' +
    [...days]
      .reverse()
      .map(
        (d) =>
          `<tr><td>${esc(longDate(d))}</td><td>${compact(d.tokens)}</td><td>${time(d.engagedMin)}</td><td>${time(d.lockedMin)}</td><td>${time(d.autopilotMin)}</td>` +
          `<td>${esc(topLevel(d))}</td><td>${d.prompts}</td><td>${compact(d.chars)}</td><td>${compact(d.lines)}</td></tr>`,
      )
      .join('') +
    '</tbody>';
}

function renderFoot() {
  const key = `${data.meta.source}|${Boolean(data.meta.aiOn)}`;
  if (renderFoot.done === key) return;
  renderFoot.done = key;
  $('foot').innerHTML =
    `Burnbot reads the Claude Code session logs in <code>${esc(data.meta.source)}</code> and keeps its own history, so nothing is lost when old logs are cleared. ` +
    (data.meta.aiOn
      ? 'AI recaps and loop checks are on: session names, your prompts, file names and test results (never file contents) go to Claude through your own <code>claude</code> command, at most 20 times a day. Nothing else leaves this Mac; turn it off in the Robot menu. '
      : 'Nothing leaves this Mac. ') +
    'Tokens count everything read and written, cached context included. ' +
    '<a href="/display?demo=cycle" target="_blank" rel="noopener">Preview every level</a>.<br>' +
    'Burnbot is an independent project. It is not made by, affiliated with, or endorsed by Anthropic. Claude and Claude Code are trademarks of Anthropic, PBC.';
}

function render() {
  renderChrome();
  if (page === 'today') {
    renderLevel();
    renderStats();
    renderGoal();
    renderBurn();
    renderPace();
    renderLevelsToday();
    renderWhy();
    renderAlso();
  } else {
    renderHistory();
  }
  renderFoot();
}

// ---------------------------------------------------------------- pages

function show(next) {
  page = next === 'history' ? 'history' : 'today';
  $('pageToday').hidden = page !== 'today';
  $('pageHistory').hidden = page !== 'history';
  for (const tab of $('tabs').children) tab.setAttribute('aria-selected', String(tab.dataset.page === page));
  try {
    history.replaceState(null, '', page === 'history' ? '#history' : location.pathname);
  } catch {
    // the address is only a convenience
  }
  hideTip();
  scrollTo(0, 0);
  if (data) render();
}
$('tabs').addEventListener('click', (e) => {
  const tab = e.target.closest('button[data-page]');
  if (tab) show(tab.dataset.page);
});
if (location.hash === '#history') show('history');
window.burnbot = { mini, fit: fitMini, show }; // handle for poking at the page from the console

$('rangeSeg').addEventListener('click', (e) => {
  const btn = e.target.closest('button');
  if (!btn) return;
  range = btn.dataset.k;
  for (const b of $('rangeSeg').children) b.setAttribute('aria-pressed', String(b === btn));
  if (data) render();
});

// ---------------------------------------------------------------- wiring

listen(
  (next) => {
    data = next;
    render();
    welcome();
  },
  (next) => {
    older = { days: next.days ?? [], projects: next.projects ?? [] };
    if (data) render();
  },
);
// The app tells the desk screen what each level is called; the names live in robot.js.
tell('levels', { names: Object.fromEntries(STATE_ORDER.map((s) => [s, STATE_META[s].label])) });

let resizeTimer;
addEventListener('resize', () => {
  clearTimeout(resizeTimer);
  resizeTimer = setTimeout(() => data && render(), 120);
});
// What is folded away is drawn when it opens.
for (const fold of document.querySelectorAll('details.fold')) fold.addEventListener('toggle', () => data && render());

setInterval(() => drawLogo($('logo'), state, performance.now() / 1000), 125);

$('deskFlip').addEventListener('click', () => tell('flipDesk'));
$('goalLess').addEventListener('click', () => data.goal && tell('dailyGoal', { n: Math.max(1, data.goal.target - 1) }));
$('goalMore').addEventListener('click', () => data.goal && tell('dailyGoal', { n: Math.min(20, data.goal.target + 1) }));
$('goalAuto').addEventListener('click', () => tell('dailyGoal', { n: 0 }));

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
  let html = item('robot:0:0', 'Robot on the desktop', 'Stands in a corner over your work; drag it anywhere');
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
// Three sparks fanning out above its antenna: straight up, up and out, and out. One canvas pixel each.
const SPARKS = [[33, 2], [33, 3], [33, 4], [33, 5], [38, 8], [39, 7], [40, 6], [41, 5], [40, 12], [41, 12], [42, 12], [43, 12]];
function drawWelcomeRobot() {
  const canvas = $('welcomeRobot');
  if (canvas.width === 50) return; // drawn once: it holds still here
  canvas.width = 50; canvas.height = 64;
  const ctx = canvas.getContext('2d');
  drawRobot(ctx, 22, 62, 'cruising', 0.5, 'smile', { smoke: false });
  ctx.fillStyle = '#ffd25e';
  for (const [x, y] of SPARKS) ctx.fillRect(x, y, 1, 1);
}
function fillWelcome() {
  const { scan, meta } = data;
  const [title, line] =
    scan.phase !== 'live'
      ? ['Getting ready', `Reading your history: ${scan.done} of ${scan.total} sessions…`]
      : !meta.foundLogs
        ? ['Ready when you are', 'Start a Claude Code session and the robot wakes up by itself.']
        : ['Ready to go', 'Your levels adapt to your own Claude Code activity.'];
  $('readyTitle').textContent = title;
  $('readyLine').textContent = line;
  $('welcomeFound').classList.toggle('busy', scan.phase !== 'live');
  drawWelcomeRobot();
}
function welcome(force = false) {
  if (!data) return;
  if (!$('welcome').hidden) return fillWelcome();
  if (!force && (welcomeShown || !data.meta.firstRun)) return;
  welcomeShown = true;
  $('optLogin').checked = Boolean(data.meta.openAtLogin);
  $('optTop').checked = data.meta.keepOnTop !== false;
  // Asked for the first time (new, or coming from 1.0): alerts default on. AI recaps are yours to
  // switch on: the app keeps them off until you do, so this shows what is set now.
  $('optAlerts').checked = data.meta.firstRun ? true : Boolean(data.meta.claudeAlerts);
  $('optAI').checked = Boolean(data.meta.aiOn);
  fillWelcome();
  $('welcome').hidden = false;
  // Enter starts; the focus ring only shows once you reach for the keyboard.
  $('welcomeGo').focus({ preventScroll: true, focusVisible: false }); $('welcome').scrollTop = 0;
}
window.burnbotWelcome = () => welcome(true);
$('welcomeGo').addEventListener('click', () => {
  tell('openAtLogin', { on: $('optLogin').checked });
  tell('keepOnTop', { on: $('optTop').checked });
  tell('claudeAlerts', { on: $('optAlerts').checked });
  tell('aiOn', { on: $('optAI').checked });
  tell('welcomed');
  $('welcome').hidden = true;
});
