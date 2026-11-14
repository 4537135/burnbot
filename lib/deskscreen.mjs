// Feeds the desk screen: a small board with a display, plugged in by USB, that
// shows the robot and the level (see desk/). The tracker sends it one line a
// second; the board draws and animates by itself.
//
// The board appears as a serial port (/dev/cu.usbmodem…). This talks to it
// with plain file reads and writes, so nothing needs installing.
//
// Run it directly to ask a board what it is:  node lib/deskscreen.mjs

import fs from 'node:fs';
import { execFile } from 'node:child_process';

const O = fs.constants;
const NAME = 'BURNBOT';
const RETRY_MS = 4000; // how often to look for a board that is not there (or not ours)
const SILENT_MS = 8000; // no answer for this long: start over

const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

function ports() {
  try {
    return fs
      .readdirSync('/dev')
      .filter((name) => name.startsWith('cu.usbmodem'))
      .map((name) => `/dev/${name}`);
  } catch {
    return [];
  }
}

/** Opens a port for talking in plain lines. Never at 1200 baud: that speed tells these boards to wipe themselves for an upload. */
async function open(port) {
  const fd = fs.openSync(port, O.O_RDWR | O.O_NOCTTY | O.O_NONBLOCK);
  await new Promise((resolve) => execFile('/bin/stty', ['-f', port, '115200', 'raw', '-echo', 'clocal'], () => resolve()));
  return fd;
}

/** Everything the board has said since the last look, without waiting. */
function drain(fd) {
  const buffer = Buffer.alloc(512);
  let text = '';
  for (;;) {
    let n;
    try {
      n = fs.readSync(fd, buffer, 0, buffer.length, null);
    } catch (error) {
      if (error.code === 'EAGAIN') return text;
      throw error;
    }
    if (!n) return text;
    text += buffer.toString('latin1', 0, n);
  }
}

/** Asks a port what program its board runs. Returns the answer ("BURNBOT 1", "FOOOCUS 2", …) or '' for silence. */
export async function ask(port) {
  let fd;
  try {
    fd = await open(port);
    drain(fd);
    fs.writeSync(fd, '\nV\n');
    let heard = '';
    for (let i = 0; i < 15; i++) {
      await wait(100);
      heard += drain(fd);
      const answer = heard.split(/[\r\n]+/).find((line) => /^[A-Z]+ \d+$/.test(line.trim()));
      if (answer) return answer.trim();
    }
    return '';
  } catch {
    return '';
  } finally {
    if (fd !== undefined) fs.closeSync(fd);
  }
}

export class DeskScreen {
  constructor({ log = () => {} } = {}) {
    this.log = log;
    this.fd = null;
    this.busy = false;
    this.lookedAt = 0;
    this.heardAt = 0;
    this.pending = '';
    this.rotation = 0; // which way up the board draws: 0 or 2 (it remembers this itself)
    // state: 'absent' (no board), 'connected', 'other' (a board with another program), 'silent' (a port that does not answer)
    this.status = { state: 'absent', port: null, program: null };
  }

  #set(state, port = null, program = null) {
    const changed = state !== this.status.state || port !== this.status.port || program !== this.status.program;
    this.status = { state, port, program };
    if (!changed) return;
    if (state === 'connected') this.log(`Desk screen connected on ${port} (${program}).`);
    else if (state === 'other') this.log(`The board on ${port} runs ${program}, not Burnbot's screen program. Upload it with "desk/Upload to the screen.command".`);
    else if (state === 'absent') this.log('Desk screen unplugged.');
  }

  #close() {
    if (this.fd !== null) {
      try {
        fs.closeSync(this.fd);
      } catch {
        /* already gone */
      }
    }
    this.fd = null;
  }

  async #connect() {
    const found = ports();
    if (!found.length) return this.#set('absent');
    for (const port of found) {
      const program = await ask(port);
      if (program.startsWith(NAME)) {
        try {
          this.fd = await open(port);
          this.heardAt = Date.now();
          this.pending = '';
          fs.writeSync(this.fd, 'Q\n'); // ask which way up it is
          return this.#set('connected', port, program);
        } catch {
          this.#close();
        }
      } else if (program) {
        return this.#set('other', port, program);
      }
    }
    this.#set('silent', found[0]);
  }

  /** Call once a second with the line to show. Finds the board, sends, and notices when it is unplugged. */
  async send(line) {
    if (this.busy) return;
    this.busy = true;
    try {
      const now = Date.now();
      if (this.fd === null) {
        if (now - this.lookedAt < RETRY_MS) return;
        this.lookedAt = now;
        await this.#connect();
        if (this.fd === null) return;
      }
      try {
        this.pending += drain(this.fd);
        if (/OK/.test(this.pending)) this.heardAt = now;
        const way = this.pending.match(/Q\|o=(\d)/);
        if (way) this.rotation = Number(way[1]);
        this.pending = this.pending.slice(-64);
        fs.writeSync(this.fd, line + '\n');
      } catch (error) {
        if (error.code === 'EAGAIN') return; // the board is busy drawing; next second
        this.#close();
        this.lookedAt = 0;
        return this.#set('absent');
      }
      if (now - this.heardAt > SILENT_MS) {
        this.#close();
        this.#set('silent', this.status.port);
      }
    } finally {
      this.busy = false;
    }
  }

  /** Turns the picture the other way up, for a screen mounted with its pins at the top. */
  flip() {
    if (this.fd === null) return false;
    const next = this.rotation === 2 ? 0 : 2;
    try {
      fs.writeSync(this.fd, `O${next}\n`);
    } catch {
      return false;
    }
    this.rotation = next;
    return true;
  }

  close() {
    this.#close();
  }
}

/** The line for the board, from the tracker's state. `labels` maps a state to what it is called on screen. */
export function deskLine(state, labels, order) {
  const live = state.live;
  const clean = (text) => String(text).toUpperCase().replace(/[^A-Z0-9 .,!%/:+-]/g, '').slice(0, 18);
  const tokens = (v) => {
    const n = Number(v) || 0;
    if (n >= 1e9) return (n / 1e9).toFixed(2) + 'B';
    if (n >= 1e6) return (n / 1e6).toFixed(n >= 1e8 ? 0 : n >= 1e7 ? 1 : 2) + 'M';
    if (n >= 1e4) return (n / 1e3).toFixed(n >= 1e5 ? 0 : 1) + 'K';
    return String(Math.round(n));
  };
  const cuts = state.baseline.thresholds;
  const time = new Date(state.now);
  const two = (n) => String(n).padStart(2, '0');
  return [
    'B',
    `s=${Math.max(0, order.indexOf(live.state))}`,
    `lv=${live.level === null ? -1 : live.level}`,
    `tp=${live.topLevel}`,
    `u=${live.usual ? order.indexOf(live.usual) : -1}`,
    `i=${live.intensity}`,
    `f=${Math.round(live.flame * 100)}`,
    `c=${cuts.cruise},${cuts.lock},${cuts.overdrive}`,
    `nm=${clean(labels[live.state] || live.state)}`,
    `cp=${live.level === null ? 'OFF LADDER' : `LEVEL ${live.level} OF ${live.topLevel}`}`,
    `rt=${tokens(live.tokensPerHour)}`,
    `tm=${two(time.getHours())}:${two(time.getMinutes())}`,
  ].join('|');
}

// Run directly: say what is plugged in.
if (import.meta.filename === process.argv[1]) {
  const found = ports();
  if (!found.length) console.log('No board plugged in (no /dev/cu.usbmodem…).');
  for (const port of found) console.log(`${port}: ${(await ask(port)) || 'no answer'}`);
}
