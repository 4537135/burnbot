#!/usr/bin/env node
// Burnbot: tracks Claude Code token burn on this Mac and serves two screens,
// the dashboard (/) and the robot display for a second monitor (/display).
//
//   node server.mjs [--port 4747] [--open] [--display] [--lan]

import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { spawn } from 'node:child_process';
import { Collector } from './lib/collector.mjs';
import { analyze } from './lib/metrics.mjs';
import { listDisplays, openDisplay, closeDisplay, displayIsOpen, watchDisplays } from './lib/displays.mjs';
import { DeskScreen, deskLine } from './lib/deskscreen.mjs';
import { STATE_META, STATE_ORDER } from './public/robot.js';

const HERE = import.meta.dirname;
const PUBLIC = path.join(HERE, 'public');
// Burnbot.app keeps history in Application Support; run from a terminal it sits beside the code.
const DATA = process.env.BURNBOT_DATA || path.join(HERE, 'data');

const argv = process.argv.slice(2);
const flag = (name) => argv.includes(`--${name}`);
const option = (name, fallback) => {
  const i = argv.indexOf(`--${name}`);
  return i !== -1 && argv[i + 1] ? argv[i + 1] : fallback;
};

const PORT = Number(option('port', process.env.PORT || 4747));
const LAN = flag('lan'); // also serve other devices on your network (a tablet as the second screen)
const HOST = LAN ? '0.0.0.0' : '127.0.0.1';
const ROOT = process.env.CLAUDE_PROJECTS_DIR || path.join(os.homedir(), '.claude', 'projects');
const TICK_MS = 2000;

const collector = new Collector({ root: ROOT, storePath: path.join(DATA, 'store.json') });

// The desk screen: a small USB board with a display that shows the robot (see desk/).
const desk = new DeskScreen({ log: console.log });
const LEVEL_NAMES = Object.fromEntries(Object.entries(STATE_META).map(([state, meta]) => [state, meta.label]));

// ---------- state + live stream ----------

let snapshot = null;
let snapshotAt = 0;
const clients = new Set();

function currentState() {
  const now = Date.now();
  if (!snapshot || now - snapshotAt >= 1000) {
    snapshot = analyze(collector, now);
    snapshot.meta = { source: ROOT, displayOpen: displayIsOpen(), desk: { ...desk.status, answering: Date.now() - desk.heardAt < 5000 } };
    snapshotAt = now;
  }
  return snapshot;
}

function broadcast() {
  if (!clients.size) return;
  const frame = `event: state\ndata: ${JSON.stringify(currentState())}\n\n`;
  for (const res of clients) res.write(frame);
}

// ---------- http ----------

const TYPES = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.ico': 'image/x-icon',
};

function send(res, status, body, type = 'application/json; charset=utf-8') {
  res.writeHead(status, { 'Content-Type': type, 'Cache-Control': 'no-store' });
  res.end(typeof body === 'string' || Buffer.isBuffer(body) ? body : JSON.stringify(body));
}

// Bound to localhost, only answer requests addressed to localhost. This stops
// another website from reaching the tracker through a rebound DNS name.
function allowedHost(req) {
  if (LAN) return true;
  const host = String(req.headers.host || '').replace(/:\d+$/, '');
  return host === 'localhost' || host === '127.0.0.1' || host === '[::1]';
}

function serveFile(res, file) {
  fs.readFile(file, (err, data) => {
    if (err) return send(res, 404, 'Not found', 'text/plain; charset=utf-8');
    send(res, 200, data, TYPES[path.extname(file)] || 'application/octet-stream');
  });
}

const server = http.createServer(async (req, res) => {
  if (!allowedHost(req)) return send(res, 403, 'Forbidden', 'text/plain; charset=utf-8');
  const url = new URL(req.url, 'http://localhost');
  const route = url.pathname;

  if (route === '/api/state') return send(res, 200, currentState());

  if (route === '/api/events') {
    res.writeHead(200, {
      'Content-Type': 'text/event-stream',
      'Cache-Control': 'no-store',
      Connection: 'keep-alive',
    });
    res.write(`retry: 2000\nevent: state\ndata: ${JSON.stringify(currentState())}\n\n`);
    clients.add(res);
    req.on('close', () => clients.delete(res));
    return;
  }

  if (route === '/api/displays') return send(res, 200, { displays: await listDisplays(), open: displayIsOpen() });

  if (route === '/api/display/open' || route === '/api/display/close') {
    // A custom header cannot be sent cross-site without a preflight, so only
    // our own pages can press these buttons.
    if (req.method !== 'POST' || req.headers['x-burnbot'] !== '1') return send(res, 405, { ok: false });
    if (route.endsWith('close')) {
      closeDisplay();
      return send(res, 200, { ok: true });
    }
    const index = url.searchParams.has('index') ? Number(url.searchParams.get('index')) : undefined;
    const result = await openDisplay(`http://localhost:${PORT}/display`, {
      index,
      profileDir: path.join(DATA, 'display-browser'),
    });
    return send(res, 200, result);
  }

  if (route === '/api/desk/flip') {
    if (req.method !== 'POST' || req.headers['x-burnbot'] !== '1') return send(res, 405, { ok: false });
    return send(res, 200, { ok: desk.flip() });
  }

  if (route === '/' || route === '/index.html') return serveFile(res, path.join(PUBLIC, 'index.html'));
  if (route === '/display') return serveFile(res, path.join(PUBLIC, 'display.html'));

  const file = path.normalize(path.join(PUBLIC, route));
  if (!file.startsWith(PUBLIC + path.sep)) return send(res, 403, 'Forbidden', 'text/plain; charset=utf-8');
  serveFile(res, file);
});

server.on('error', (err) => {
  if (err.code === 'EADDRINUSE') {
    console.error(`Port ${PORT} is already in use. Burnbot may already be running: http://localhost:${PORT}`);
    process.exit(1);
  }
  throw err;
});

// ---------- lifecycle ----------

function shutdown() {
  desk.close();
  try {
    collector.save();
  } catch (err) {
    console.error('Could not save history:', err.message);
  }
  process.exit(0);
}
process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);

server.listen(PORT, HOST, async () => {
  const base = `http://localhost:${PORT}`;
  console.log(`Burnbot is running.\n  Dashboard      ${base}\n  Second screen  ${base}/display`);
  if (LAN) {
    const addrs = Object.values(os.networkInterfaces())
      .flat()
      .filter((a) => a && a.family === 'IPv4' && !a.internal)
      .map((a) => `http://${a.address}:${PORT}/display`);
    if (addrs.length) console.log(`  On your network ${addrs.join('  ')}`);
  }

  const restored = collector.load();
  const started = Date.now();
  await collector.scanAll();
  console.log(
    `Read ${collector.files.size} session logs in ${((Date.now() - started) / 1000).toFixed(1)}s` +
      (restored ? ' (history restored from data/store.json).' : '.'),
  );
  collector.save();

  if (flag('open')) spawn('open', [base], { stdio: 'ignore', detached: true }).unref();

  // --display: put the robot on the second screen now, and again whenever one is plugged in.
  const profileDir = path.join(DATA, 'display-browser');
  const openRobot = () => openDisplay(`${base}/display`, { profileDir, requireExternal: true });
  if (flag('display')) console.log((await openRobot()).message);
  watchDisplays({ autoOpen: flag('display'), open: openRobot, log: console.log });
});

setInterval(() => {
  collector.poll();
  broadcast();
}, TICK_MS);
setInterval(() => collector.save(), 5 * 60_000);
// Once a second, tell the desk screen which level to show. It animates by itself in between.
setInterval(() => desk.send(deskLine(currentState(), LEVEL_NAMES, STATE_ORDER)), 1000);

// Started by Burnbot.app: stop when the app goes away, even if it crashed.
const parent = Number(option('parent', 0));
if (parent) {
  setInterval(() => {
    try {
      process.kill(parent, 0);
    } catch {
      shutdown();
    }
  }, 3000);
}
