// How the screens talk to the app they run in.

const native = window.webkit?.messageHandlers?.burnbot;

/** True inside Burnbot.app; false when a page is opened in a browser to work on it. */
export const inApp = Boolean(native);

/** Sends the app a message, for example tell('robot', { index: 1, fullscreen: true }). */
export function tell(type, more = {}) {
  native?.postMessage({ type, ...more });
}

/**
 * Calls onState with the tracker's state now, and again every couple of seconds.
 * onOlder, if given, gets the days before the last 30 whenever they are worked out.
 */
export function listen(onState, onOlder) {
  window.burnbotReceive = onState;
  if (onOlder) window.burnbotOlder = onOlder;
  tell('ready');
  // In a browser there is no tracker. A saved state served next to the pages
  // as state.json (see --dump-state) stands in for it, to work on the look.
  if (!inApp) {
    fetch('state.json')
      .then((r) => (r.ok ? r.json() : null))
      .then((saved) => {
        if (!saved) return;
        if (saved.older) onOlder?.(saved.older);
        onState(saved);
      })
      .catch(() => {});
  }
}
