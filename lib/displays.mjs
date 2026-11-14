// Finds the monitors attached to this Mac and opens the robot screen on one of
// them, fullscreen, in its own Chrome window.

import { execFile, spawn } from 'node:child_process';
import fs from 'node:fs';

// NSScreen puts the origin at the bottom-left of the primary screen; browsers
// want top-left, so flip y here.
const JXA = `
ObjC.import('AppKit');
const screens = $.NSScreen.screens;
const primaryH = screens.objectAtIndex(0).frame.size.height;
const out = [];
for (let i = 0; i < screens.count; i++) {
  const s = screens.objectAtIndex(i);
  const f = s.frame;
  out.push({
    index: i,
    name: ObjC.unwrap(s.localizedName),
    x: f.origin.x,
    y: primaryH - (f.origin.y + f.size.height),
    width: f.size.width,
    height: f.size.height,
    primary: i === 0,
  });
}
JSON.stringify(out);
`;

const BROWSERS = [
  '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
  '/Applications/Chromium.app/Contents/MacOS/Chromium',
  '/Applications/Brave Browser.app/Contents/MacOS/Brave Browser',
  '/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge',
];

export function listDisplays() {
  return new Promise((resolve) => {
    if (process.platform !== 'darwin') return resolve([]);
    execFile('osascript', ['-l', 'JavaScript', '-e', JXA], { timeout: 5000 }, (err, stdout) => {
      if (err) return resolve([]);
      try {
        resolve(JSON.parse(stdout));
      } catch {
        resolve([]);
      }
    });
  });
}

let child = null;
let current = null; // the screen the robot window was opened on

export function closeDisplay() {
  if (child && child.exitCode === null) child.kill();
  child = null;
  current = null;
}

export function displayIsOpen() {
  return Boolean(child && child.exitCode === null);
}

/**
 * Opens `url` fullscreen on a display. With `index`, that display; otherwise
 * the first one that is not the primary. `requireExternal` makes it do nothing
 * when only the built-in screen is attached, instead of covering it.
 */
export async function openDisplay(url, { index, profileDir, requireExternal = false } = {}) {
  const screens = await listDisplays();
  const external = screens.find((s) => !s.primary);
  if (requireExternal && !external) {
    return { ok: true, placed: false, waiting: true, message: 'No second screen is attached. Plug one in and the robot will appear on it.' };
  }
  const target = (index !== undefined && screens.find((s) => s.index === index)) || external || screens[0];
  const browser = BROWSERS.find((b) => fs.existsSync(b));

  if (!browser || !target) {
    // No Chromium browser to position: open normally and let the person drag it over.
    spawn('open', [url], { stdio: 'ignore', detached: true }).unref();
    return {
      ok: true,
      placed: false,
      message: 'Opened in your default browser. Drag the window to the second screen and click it to go fullscreen.',
    };
  }

  closeDisplay();
  fs.mkdirSync(profileDir, { recursive: true });
  // A separate profile makes Chrome start a fresh process, which is the only
  // way it honours the window position while your normal Chrome is running.
  const proc = spawn(
    browser,
    [
      `--user-data-dir=${profileDir}`,
      '--no-first-run',
      '--no-default-browser-check',
      '--disable-session-crashed-bubble',
      '--disable-features=Translate',
      `--window-position=${Math.round(target.x)},${Math.round(target.y)}`,
      `--window-size=${Math.round(target.width)},${Math.round(target.height)}`,
      '--start-fullscreen',
      `--app=${url}`,
    ],
    { stdio: 'ignore', detached: true },
  );
  proc.unref();
  proc.on('exit', () => {
    if (child === proc) {
      child = null;
      current = null;
    }
  });
  child = proc;
  current = target;
  return { ok: true, placed: true, screen: target, message: `Opened on ${target.name}.` };
}

/**
 * Follows monitors being plugged in and out. Unplugging the robot's screen
 * closes its window, so it does not jump onto the laptop screen. With
 * `autoOpen`, plugging a second screen in brings the robot up on it.
 */
export function watchDisplays({ autoOpen, open, log = () => {} }) {
  let hadExternal = null;
  const check = async () => {
    const screens = await listDisplays();
    if (!screens.length) return;
    const external = screens.some((s) => !s.primary);
    if (displayIsOpen() && current && !current.primary && !screens.some((s) => s.name === current.name)) {
      log(`${current.name} was unplugged, so the robot window was closed.`);
      closeDisplay();
    }
    if (autoOpen && hadExternal === false && external && !displayIsOpen()) log((await open()).message);
    hadExternal = external;
  };
  check();
  return setInterval(check, 8000);
}
