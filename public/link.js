// How the screens talk to the app they run in.

const native = window.webkit?.messageHandlers?.burnbot;

/** True inside Burnbot.app; false when a page is opened in a browser to work on it. */
export const inApp = Boolean(native);

/** Sends the app a message, for example tell('robot', { index: 1, fullscreen: true }). */
export function tell(type, more = {}) {
  native?.postMessage({ type, ...more });
}

/** Calls onState with the tracker's state now, and again every couple of seconds. */
export function listen(onState) {
  window.burnbotReceive = onState;
  tell('ready');
}
