// Number and time formatting shared by both screens. Burn is always shown in
// tokens, never money.

export function compact(v) {
  const n = Number(v) || 0;
  const a = Math.abs(n);
  if (a >= 1e9) return (n / 1e9).toFixed(a >= 1e10 ? 1 : 2) + 'B';
  if (a >= 1e6) return (n / 1e6).toFixed(a >= 1e8 ? 0 : a >= 1e7 ? 1 : 2) + 'M';
  if (a >= 1e4) return (n / 1e3).toFixed(a >= 1e5 ? 0 : 1) + 'K';
  return Math.round(n).toLocaleString('en-US');
}

/** A running token count with enough digits that you can watch it climb. */
export function ticker(v) {
  const n = Math.max(0, Number(v) || 0);
  if (n >= 1e9) return (n / 1e9).toFixed(5) + 'B';
  if (n >= 1e6) return (n / 1e6).toFixed(3) + 'M';
  return Math.round(n).toLocaleString('en-US');
}

export function duration(minutes) {
  const m = Math.max(0, Math.round(minutes));
  if (m < 60) return `${m} min`;
  const h = Math.floor(m / 60);
  const r = m % 60;
  return r ? `${h}h ${r}m` : `${h}h`;
}

export function clock(ms) {
  return new Date(ms).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', hour12: false });
}

/** "Level 3 of 5", or what to say when the robot is off the ladder. */
export function levelLine(live) {
  return live.level === null ? 'Off the ladder' : `Level ${live.level} of ${live.topLevel}`;
}

/** One line under the level name saying why the robot is there. */
export function subline(live) {
  switch (live.state) {
    case 'asleep':
      return live.lastCallMs ? `Last Claude activity at ${clock(live.lastCallMs)}` : 'No Claude activity yet';
    case 'idle':
      return `Quiet for ${duration(live.idleMin)}`;
    case 'autopilot':
      return `Agents burning without you · last prompt ${duration(live.humanIdleMin)} ago`;
    case 'locked':
    case 'overdrive': {
      const top = live.hotterThan === null ? '' : ` · top ${Math.max(1, 100 - live.hotterThan)}% for you`;
      return `${duration(live.lockedRunMin)} locked in${top}`;
    }
    default:
      return `${duration(live.streakMin)} streak · intensity ${live.intensity} of 100`;
  }
}

/** What it takes to reach the next level, in plain words. `name` is that level's label. */
export function nextLine(live, name) {
  const n = live.next;
  if (!n) {
    if (live.level === live.topLevel) return 'Nothing above this';
    if (live.state === 'autopilot') return 'Send a prompt to get back on the ladder';
    return 'Start working with Claude to climb';
  }
  if (live.intensity >= n.intensity && n.streakLeftMin > 0) return `${n.streakLeftMin} more min of unbroken work to reach ${name}`;
  return `Intensity ${live.intensity}, ${name} starts at ${n.intensity}`;
}
