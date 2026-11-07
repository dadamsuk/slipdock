// Relative times that keep up with the clock (#2025).
//
// The server writes "18 min ago" once, when it renders, and nothing changes it
// until the next render: a card left open says "18 min ago" for an hour. A
// LiveView could re-render every minute, but that is a server tick per open
// page for words the browser can work out by itself. So `timestamp/1` marks
// its relative `<time>`s with `data-relative` (and `data-zone`, the viewer's
// timezone the server wrote it in), and this rewrites their text every 30 s.
//
// `relativeText/3` is `SlipdockWeb.Dates.relative/2` in JavaScript, word for
// word: "just now", "5 min ago", "3 h ago" the same calendar day, "yesterday",
// "3 days ago" up to a week, then the date ("18 Nov", "18 Nov 2025"); and the
// same ahead ("in 5 min", "tomorrow", …). Days are counted on the viewer's
// calendar in `data-zone`, as the server counts them.
//
// A LiveView re-render sends the server's text again, which was right when it
// was rendered and may be minutes old by now for a part of the page whose
// assigns didn't change. `refreshIncoming/2` runs from the LiveSocket's
// `dom.onBeforeElUpdated` and rewrites the incoming element before it is
// patched in, so a re-render never puts a stale time back.
//
// A browser whose clock runs a little behind the server's would read a moment
// just posted as "in 1 min". The server says which side of its own clock the
// moment was (`data-relative="past"`), and a past moment is never taken as
// ahead of the browser's now: it reads "just now" until the browser catches up.

export const TICK_MS = 30_000

const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
const formats = new Map()

function dayFormat(zone) {
  if (!formats.has(zone)) {
    let format
    try {
      format = new Intl.DateTimeFormat("en-CA", {timeZone: zone, year: "numeric", month: "2-digit", day: "2-digit"})
    } catch (_e) {
      // An unknown zone reads as UTC, as `Dates` falls back to it.
      format = new Intl.DateTimeFormat("en-CA", {timeZone: "UTC", year: "numeric", month: "2-digit", day: "2-digit"})
    }
    formats.set(zone, format)
  }
  return formats.get(zone)
}

// The calendar day a moment falls on in `zone`, as {year, month, day}.
export function localDay(at, zone = "UTC") {
  const parts = {}
  for (const {type, value} of dayFormat(zone || "UTC").formatToParts(at)) parts[type] = Number(value)
  return {year: parts.year, month: parts.month, day: parts.day}
}

function dayNumber({year, month, day}) {
  return Math.round(Date.UTC(year, month - 1, day) / 86_400_000)
}

function short(d, today) {
  const text = `${d.day} ${MONTHS[d.month - 1]}`
  return d.year === today.year ? text : `${text} ${d.year}`
}

// `SlipdockWeb.Dates.relative/2`: `at` and `now` are Dates (or milliseconds).
export function relativeText(at, now, zone = "UTC") {
  const atMs = +at
  const nowMs = +now
  if (!Number.isFinite(atMs) || !Number.isFinite(nowMs)) return null

  // Whole seconds, rounded down as `DateTime.diff/2` rounds them.
  const seconds = Math.floor((nowMs - atMs) / 1000)
  const atDay = localDay(new Date(atMs), zone)
  const today = localDay(new Date(nowMs), zone)
  const days = dayNumber(atDay) - dayNumber(today)

  if (days === 0) {
    if (seconds >= 0 && seconds < 60) return "just now"
    if (seconds >= 0 && seconds < 3600) return `${Math.floor(seconds / 60)} min ago`
    if (seconds >= 0) return `${Math.floor(seconds / 3600)} h ago`
    if (seconds > -3600) return `in ${Math.max(Math.trunc(-seconds / 60), 1)} min`
    return `in ${Math.trunc(-seconds / 3600)} h`
  }

  if (days === -1) return "yesterday"
  if (days === 1) return "tomorrow"
  if (days < 0 && days > -7) return `${-days} days ago`
  if (days > 0 && days < 7) return `in ${days} days`
  return short(atDay, today)
}

// What a marked `<time>` should say at `now`, or null when it isn't one.
export function textFor(el, now) {
  if (!el || typeof el.getAttribute !== "function") return null
  const mark = el.getAttribute("data-relative")
  const iso = el.getAttribute("datetime")
  if (mark === null || !iso) return null

  const at = Date.parse(iso)
  if (Number.isNaN(at)) return null
  const zone = el.getAttribute("data-zone") || "UTC"
  const ms = +now
  return relativeText(at, mark === "past" ? Math.max(ms, at) : ms, zone)
}

function rewrite(el, now) {
  const text = textFor(el, now)
  if (text !== null && el.textContent !== text) el.textContent = text
}

// Rewrites every marked `<time>` under `root`.
export function tick(root, now = Date.now()) {
  for (const el of root.querySelectorAll("time[data-relative]")) rewrite(el, now)
}

// For the LiveSocket's `dom.onBeforeElUpdated`: the incoming element `to`
// carries the server's text, which may be stale; give it the time now.
export function refreshIncoming(_from, to, now = Date.now()) {
  if (to && to.nodeName === "TIME") rewrite(to, now)
}

// Ticks every 30 s, and at once when the tab comes back (a hidden tab's
// timers are throttled). Returns a function that stops it.
export function installRelativeTime(win, {every = TICK_MS} = {}) {
  const doc = win.document
  const run = () => tick(doc, Date.now())
  const timer = win.setInterval(run, every)
  const onVisible = () => {
    if (doc.visibilityState !== "hidden") run()
  }
  doc.addEventListener("visibilitychange", onVisible)
  run()

  return () => {
    win.clearInterval(timer)
    doc.removeEventListener("visibilitychange", onVisible)
  }
}
