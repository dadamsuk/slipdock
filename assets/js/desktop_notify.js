// Desktop toasts for waits and mentions (#2101), through the browser's
// Notification API: no service worker, no Web Push, so with no Slipdock tab
// open nothing shows, on purpose.
//
// `SlipdockWeb.NotifyHook` pushes `desktop-notify` to every signed-in page
// when something tells its reader (`Slipdock.Notify`). `DesktopNotify` (on a
// hidden element in the app layout) shows it only when this browser has the
// toggle on and permission given, never for the reader's own doing, and not
// when this tab is in front and already showing the card. The event's id is
// the toast's tag, so several tabs show one toast between them.
//
// The toggle is remembered in this browser (localStorage, through
// `storage.js`), since permission is per browser too.
// `DesktopNotifyToggle` draws it on the account's Preferences page.

import {storage, read, write} from "./storage.js"

export const KEY = "slipdock:desktop-notify"

function notificationApi() {
  return typeof globalThis.Notification === "function" ? globalThis.Notification : null
}

// "unsupported", or the browser's permission: "default", "granted", "denied".
export function permission(N = notificationApi()) {
  if (!N) return "unsupported"
  return N.permission || "default"
}

export function enabled(store = storage()) {
  return read(KEY, store) === "on"
}

export function setEnabled(on, store = storage()) {
  write(KEY, on ? "on" : null, store)
}

// Turning the toggle on: asks for permission and keeps it on only if given.
// Resolves to the permission, or "unsupported".
export async function turnOn({N = notificationApi(), store = storage()} = {}) {
  if (!N) { setEnabled(false, store); return "unsupported" }
  let answer = N.permission
  if (answer !== "granted" && answer !== "denied" && typeof N.requestPermission === "function") {
    answer = await N.requestPermission()
  }
  setEnabled(answer === "granted", store)
  return answer || "default"
}

// What to say beside the toggle.
export function statusText(state, on) {
  switch (state) {
    case "unsupported": return "This browser can't show desktop notifications."
    case "denied": return "Notifications are blocked for this site in this browser's settings."
    case "granted": return on ? "On in this browser." : "Off in this browser."
    default: return on ? "Allow notifications when the browser asks." : "Off in this browser."
  }
}

// Whether this tab is already showing the card the event is about.
export function showingCard(event, loc) {
  if (!loc || !event) return false
  const path = loc.pathname || ""
  if (event.path && path === event.path) return true
  if (event.card_id != null && path.endsWith(`/cards/${event.card_id}`)) return true
  try {
    return new URLSearchParams(loc.search || "").get("card") === String(event.card_id)
  } catch (_) { return false }
}

// Whether to show `event` here and now.
export function shouldShow(event, {userId, store = storage(), N = notificationApi(), focused = false, loc} = {}) {
  if (!event || !event.id) return false
  if (!enabled(store)) return false
  if (permission(N) !== "granted") return false
  if (event.by_id != null && userId != null && String(event.by_id) === String(userId)) return false
  if (focused && showingCard(event, loc)) return false
  return true
}

// Shows the toast. Clicking it brings this tab forward and opens the card.
export function show(event, {N = notificationApi(), win = globalThis} = {}) {
  const toast = new N(event.title, {body: event.body || "", tag: event.id})
  toast.onclick = () => {
    try { win.focus() } catch (_) { /* not allowed */ }
    if (toast.close) toast.close()
    if (event.path) win.location.assign(event.path)
  }
  return toast
}

export function maybeNotify(event, env = {}) {
  const win = env.win || globalThis
  const doc = env.doc || globalThis.document
  const focused = env.focused ?? Boolean(doc && doc.hasFocus && doc.hasFocus())
  const opts = {...env, focused, loc: env.loc || win.location}
  if (!shouldShow(event, opts)) return null
  return show(event, {N: env.N || notificationApi(), win})
}

export const DesktopNotify = {
  mounted() {
    this.handleEvent("desktop-notify", event =>
      maybeNotify(event, {userId: this.el.dataset.userId}))
  },
}

// A checkbox (`input[type=checkbox]`) and a status line (`[data-role=status]`)
// inside the hook's element, which the server leaves alone
// (`phx-update="ignore"`).
export const DesktopNotifyToggle = {
  mounted() {
    this.input = this.el.querySelector("input[type=checkbox]")
    this.status = this.el.querySelector("[data-role=status]")
    this.render()
    this.input.addEventListener("change", async () => {
      if (this.input.checked) await turnOn()
      else setEnabled(false)
      this.render()
    })
  },
  render() {
    const state = permission()
    const on = enabled() && state === "granted"
    this.input.checked = on
    this.input.disabled = state === "unsupported"
    this.el.dataset.state = state
    if (this.status) this.status.textContent = statusText(state, on)
  },
}
