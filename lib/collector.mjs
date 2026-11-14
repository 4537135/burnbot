// Reads Claude Code's session logs (~/.claude/projects/**/*.jsonl) and folds them
// into per-minute buckets. Each file is tailed incrementally, so a running
// session shows up within a couple of seconds.

import fs from 'node:fs';
import path from 'node:path';

// Fields of a minute bucket. Everything is counted in tokens, never money.
export const F = {
  input: 0, // uncached input tokens
  output: 1, // output tokens (includes thinking)
  cacheWrite: 2,
  cacheRead: 3,
  thinking: 4,
  calls: 5, // API responses
  tools: 6, // tool calls Claude made
  prompts: 7, // messages the person sent
  chars: 8, // characters the person typed
  pasted: 9, // characters the person pasted
  lines: 10, // lines Claude wrote through Edit/Write
  tokFable: 11, // all tokens, by model family
  tokOpus: 12,
  tokSonnet: 13,
  tokHaiku: 14,
  tokOther: 15,
};
export const NF = 16;

/** Every token a response touched: read, cached and written. */
export const totalTokens = (v) => v[F.input] + v[F.output] + v[F.cacheWrite] + v[F.cacheRead];

export const FAMILIES = ['fable', 'opus', 'sonnet', 'haiku', 'other'];
const familyCache = new Map();
function familyOf(model) {
  let k = familyCache.get(model);
  if (k === undefined) {
    const id = String(model || '').toLowerCase();
    k = /fable|mythos/.test(id) ? 0 : id.includes('opus') ? 1 : id.includes('sonnet') ? 2 : id.includes('haiku') ? 3 : 4;
    familyCache.set(model, k);
  }
  return k;
}

const STORE_VERSION = 4;
const HOT_MS = 6 * 3600_000;

const N_ASSISTANT = Buffer.from('"type":"assistant"');
const N_USER = Buffer.from('"type":"user"');
const N_TOOL_RESULT = Buffer.from('"tool_use_id"');

const WRITE_TOOLS = new Set(['Edit', 'Write', 'MultiEdit', 'NotebookEdit']);

// Wrappers the harness injects into user turns. None of it was typed by the person.
const INJECTED = new RegExp(
  '<(system-reminder|artifact-view-context|artifact-content-authored-by-others|' +
    'local-command-stdout|local-command-stderr|local-command-caveat|bash-stdout|bash-stderr|' +
    'task-notification|fork-boilerplate|command-message|command-args|user-prompt-submit-hook)\\b[^>]*>' +
    '[\\s\\S]*?</\\1>',
  'g',
);
const PASTED = /<pasted_content\b[^>]*>([\s\S]*?)<\/pasted_content[^>]*>/g;
const KEPT_TAGS = /<\/?(bash-input|command-name)>/g;

function countLines(s) {
  if (typeof s !== 'string' || !s) return 0;
  let n = 1;
  for (let i = s.indexOf('\n'); i !== -1; i = s.indexOf('\n', i + 1)) n++;
  return n;
}

/** Splits a user turn into what was typed and what was pasted. */
export function measurePrompt(text) {
  let pasted = 0;
  let t = text.replace(PASTED, (_, body) => {
    pasted += body.length;
    return '';
  });
  t = t.replace(INJECTED, '').replace(KEPT_TAGS, '');
  return { typed: t.trim().length, pasted };
}

function newRecord(file) {
  return {
    path: file,
    size: 0,
    offset: 0,
    mtimeMs: 0,
    side: file.includes(`${path.sep}subagents${path.sep}`),
    project: '',
    mins: new Map(), // minute -> Float64Array(NF): this file's contribution
    ids: new Map(), // message id -> [minute, input, output, cacheWrite, cacheRead, thinking]
    gone: false,
  };
}

export class Collector {
  constructor({ root, storePath }) {
    this.root = root;
    this.storePath = storePath;
    this.files = new Map();
    this.minutes = new Map(); // minute -> { v: Float64Array(NF), ns: main sessions, na: agents }
    this.lastCallMs = 0;
    this.lastPromptMs = 0;
    this.rev = 0;
    this.scan = { phase: 'starting', done: 0, total: 0 };
    this.buf = Buffer.allocUnsafe(8 << 20);
    this.dirty = false;
    this.lastWalk = 0;
  }

  // ---------- buckets ----------

  #bucket(rec, minute) {
    let g = this.minutes.get(minute);
    if (!g) {
      g = { v: new Float64Array(NF), ns: 0, na: 0 };
      this.minutes.set(minute, g);
    }
    let f = rec.mins.get(minute);
    if (!f) {
      f = new Float64Array(NF);
      rec.mins.set(minute, f);
      if (rec.side) g.na++;
      else g.ns++;
    }
    return [f, g.v];
  }

  #retract(rec) {
    for (const [minute, f] of rec.mins) {
      const g = this.minutes.get(minute);
      if (!g) continue;
      for (let i = 0; i < NF; i++) g.v[i] -= f[i];
      if (rec.side) g.na--;
      else g.ns--;
      if (g.ns <= 0 && g.na <= 0) this.minutes.delete(minute);
    }
    rec.mins.clear();
    rec.ids.clear();
  }

  // ---------- parsing ----------

  #assistant(rec, o, ts) {
    const m = o.message;
    const u = m && m.usage;
    if (!u || m.model === '<synthetic>') return;
    const minute = Math.floor(ts / 60000);

    // Claude Code writes one line per content block, so block stats are per line...
    let tools = 0;
    let lines = 0;
    if (Array.isArray(m.content)) {
      for (const b of m.content) {
        if (b.type !== 'tool_use') continue;
        tools++;
        if (!WRITE_TOOLS.has(b.name) || !b.input) continue;
        const inp = b.input;
        lines += countLines(inp.new_string ?? inp.content ?? inp.new_source);
        if (Array.isArray(inp.edits)) for (const e of inp.edits) lines += countLines(e && e.new_string);
      }
    }
    if (tools) {
      const [f, g] = this.#bucket(rec, minute);
      f[F.tools] += tools;
      g[F.tools] += tools;
      f[F.lines] += lines;
      g[F.lines] += lines;
    }

    // ...but every line of one response repeats that response's usage, and the
    // last line carries the final output count. Count each response once and
    // top it up when a later line reports more.
    const id = m.id || o.requestId || o.uuid;
    const cur = [
      minute,
      u.input_tokens || 0,
      u.output_tokens || 0,
      u.cache_creation_input_tokens || 0,
      u.cache_read_input_tokens || 0,
      (u.output_tokens_details && u.output_tokens_details.thinking_tokens) || 0,
    ];
    const sum = (v) => v[1] + v[2] + v[3] + v[4];
    const prev = rec.ids.get(id);
    if (prev && cur[2] <= prev[2] && sum(cur) <= sum(prev)) return;

    const at = prev ? prev[0] : minute;
    const [f, g] = this.#bucket(rec, at);
    const d = (i) => cur[i] - (prev ? prev[i] : 0);
    const add = (field, val) => {
      f[field] += val;
      g[field] += val;
    };
    add(F.input, d(1));
    add(F.output, d(2));
    add(F.cacheWrite, d(3));
    add(F.cacheRead, d(4));
    add(F.thinking, d(5));
    add(F.tokFable + familyOf(m.model), d(1) + d(2) + d(3) + d(4));
    if (!prev) add(F.calls, 1);
    cur[0] = at;
    rec.ids.set(id, cur);

    if (ts > this.lastCallMs) this.lastCallMs = ts;
  }

  #user(rec, o, ts) {
    if (o.isSidechain || o.isMeta || o.isCompactSummary || o.isVisibleInTranscriptOnly) return;
    if (o.toolUseResult !== undefined) return;
    const kind = (o.origin && o.origin.kind) || o.turnOrigin;
    if (kind && kind !== 'human') return;
    const c = o.message && o.message.content;
    let text = '';
    if (typeof c === 'string') text = c;
    else if (Array.isArray(c)) {
      for (const b of c) {
        if (b.type === 'tool_result') return;
        if (b.type === 'text') text += b.text + '\n';
      }
    } else return;
    const { typed, pasted } = measurePrompt(text);
    if (!typed && !pasted) return;
    const [f, g] = this.#bucket(rec, Math.floor(ts / 60000));
    f[F.prompts] += 1;
    g[F.prompts] += 1;
    f[F.chars] += typed;
    g[F.chars] += typed;
    f[F.pasted] += pasted;
    g[F.pasted] += pasted;
    if (ts > this.lastPromptMs) this.lastPromptMs = ts;
  }

  #line(rec, line) {
    // Cheap byte-level filter first: most lines are tool output and bookkeeping.
    const assistant = line.indexOf(N_ASSISTANT) !== -1;
    if (!assistant && (line.indexOf(N_USER) === -1 || line.indexOf(N_TOOL_RESULT) !== -1)) return;
    let o;
    try {
      o = JSON.parse(line.toString('utf8'));
    } catch {
      return;
    }
    const ts = Date.parse(o.timestamp);
    if (!ts) return;
    if (!rec.project && typeof o.cwd === 'string') rec.project = projectName(o.cwd);
    if (o.type === 'assistant') this.#assistant(rec, o, ts);
    else if (o.type === 'user') this.#user(rec, o, ts);
  }

  /** Reads whatever was appended to a file since the last look. */
  #read(rec, stat) {
    if (stat.size < rec.offset) {
      // Truncated or replaced: start over.
      this.#retract(rec);
      rec.offset = 0;
    }
    rec.mtimeMs = stat.mtimeMs;
    rec.gone = false;
    if (stat.size === rec.offset) {
      rec.size = stat.size;
      return false;
    }
    let fd;
    try {
      fd = fs.openSync(rec.path, 'r');
    } catch {
      return false;
    }
    const from = rec.offset;
    try {
      const buf = this.buf;
      let pos = rec.offset;
      let carry = null;
      for (;;) {
        const n = fs.readSync(fd, buf, 0, buf.length, pos);
        if (n <= 0) break;
        pos += n;
        let chunk = buf.subarray(0, n);
        if (carry) {
          chunk = Buffer.concat([carry, chunk]);
          carry = null;
        }
        let start = 0;
        for (let nl = chunk.indexOf(10, start); nl !== -1; nl = chunk.indexOf(10, start)) {
          if (nl - start > 20) this.#line(rec, chunk.subarray(start, nl));
          start = nl + 1;
        }
        if (start < chunk.length) carry = Buffer.from(chunk.subarray(start));
      }
      // A trailing partial line is still being written; pick it up next time.
      rec.offset = pos - (carry ? carry.length : 0);
      rec.size = stat.size;
    } finally {
      fs.closeSync(fd);
    }
    // Finished responses never change again, so only live files need their ids.
    if (Date.now() - stat.mtimeMs > 10 * 60_000) rec.ids.clear();
    else if (rec.ids.size > 2000) rec.ids = new Map([...rec.ids].slice(-500));
    if (rec.offset === from) return false;
    this.rev++;
    this.dirty = true;
    return true;
  }

  // ---------- discovery ----------

  #walk() {
    const out = [];
    const visit = (dir) => {
      let entries;
      try {
        entries = fs.readdirSync(dir, { withFileTypes: true });
      } catch {
        return;
      }
      for (const e of entries) {
        const p = path.join(dir, e.name);
        if (e.isDirectory()) visit(p);
        else if (e.name.endsWith('.jsonl')) {
          try {
            const st = fs.statSync(p);
            out.push({ path: p, size: st.size, mtimeMs: st.mtimeMs });
          } catch {
            /* vanished between readdir and stat */
          }
        }
      }
    };
    visit(this.root);
    return out;
  }

  /** First pass over everything on disk, newest first so today shows up at once. */
  async scanAll() {
    const found = this.#walk().sort((a, b) => b.mtimeMs - a.mtimeMs);
    this.scan = { phase: 'scanning', done: 0, total: found.length };
    const seen = new Set();
    let slice = Date.now();
    for (const st of found) {
      seen.add(st.path);
      let rec = this.files.get(st.path);
      if (!rec) {
        rec = newRecord(st.path);
        this.files.set(st.path, rec);
      }
      this.#read(rec, st);
      this.scan.done++;
      if (Date.now() - slice > 40) {
        await new Promise((r) => setImmediate(r));
        slice = Date.now();
      }
    }
    // Logs Claude Code has since deleted stay in history.
    for (const rec of this.files.values()) if (!seen.has(rec.path)) rec.gone = true;
    this.lastWalk = Date.now();
    this.scan = { phase: 'live', done: found.length, total: found.length };
    this.rev++;
  }

  /** Cheap periodic check: tail recently active files, rediscover now and then. */
  poll() {
    if (this.scan.phase !== 'live') return;
    const now = Date.now();
    if (now - this.lastWalk > 20_000) {
      this.lastWalk = now;
      for (const st of this.#walk()) {
        let rec = this.files.get(st.path);
        if (!rec) {
          rec = newRecord(st.path);
          this.files.set(st.path, rec);
        }
        if (st.size !== rec.offset || rec.gone) this.#read(rec, st);
      }
    } else {
      for (const rec of this.files.values()) {
        if (rec.gone || now - rec.mtimeMs > HOT_MS) continue;
        try {
          const st = fs.statSync(rec.path);
          if (st.size !== rec.offset) this.#read(rec, st);
        } catch {
          rec.gone = true;
        }
      }
    }
  }

  // ---------- persistence ----------

  load() {
    let raw;
    try {
      raw = JSON.parse(fs.readFileSync(this.storePath, 'utf8'));
    } catch {
      return false;
    }
    if (raw.version !== STORE_VERSION || raw.root !== this.root) return false;
    for (const s of raw.files) {
      const rec = newRecord(s.p);
      rec.size = rec.offset = s.o;
      rec.mtimeMs = s.t;
      rec.project = s.j || '';
      for (const row of s.m) {
        const [f, g] = this.#bucket(rec, row[0]);
        for (let i = 0; i < NF; i++) {
          f[i] = row[i + 1];
          g[i] += row[i + 1];
        }
      }
      if (s.i) for (const row of s.i) rec.ids.set(row[0], row.slice(1));
      this.files.set(rec.path, rec);
    }
    this.lastCallMs = raw.lastCallMs || 0;
    this.lastPromptMs = raw.lastPromptMs || 0;
    return true;
  }

  save() {
    if (!this.dirty) return;
    const files = [];
    for (const rec of this.files.values()) {
      if (!rec.mins.size && !rec.offset) continue;
      const m = [];
      for (const [minute, f] of rec.mins) m.push([minute, ...f]);
      const s = { p: rec.path, o: rec.offset, t: rec.mtimeMs, j: rec.project, m };
      if (rec.ids.size) s.i = [...rec.ids].slice(-300).map(([id, v]) => [id, ...v]);
      files.push(s);
    }
    const body = JSON.stringify({
      version: STORE_VERSION,
      root: this.root,
      savedAt: Date.now(),
      lastCallMs: this.lastCallMs,
      lastPromptMs: this.lastPromptMs,
      files,
    });
    fs.mkdirSync(path.dirname(this.storePath), { recursive: true });
    const tmp = this.storePath + '.tmp';
    fs.writeFileSync(tmp, body);
    fs.renameSync(tmp, this.storePath);
    this.dirty = false;
  }
}

function projectName(cwd) {
  // Worktrees live under <repo>/.claude/worktrees/<name>; report the repo.
  const i = cwd.indexOf(`${path.sep}.claude${path.sep}worktrees${path.sep}`);
  const dir = i === -1 ? cwd : cwd.slice(0, i);
  return path.basename(dir.trimEnd()) || dir;
}
