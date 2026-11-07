// node --test assets/js — no browser, so the DOM here is the few methods
// relative_time.js touches.
import {test} from "node:test"
import assert from "node:assert/strict"
import {readFileSync} from "node:fs"
import {
  TICK_MS, localDay, relativeText, textFor, tick, refreshIncoming, installRelativeTime,
} from "./relative_time.js"

const {cases} = JSON.parse(readFileSync(new URL("./relative_time_cases.json", import.meta.url)))

function time(attrs = {}, text = "") {
  const a = {...attrs}
  return {
    nodeName: "TIME",
    textContent: text,
    getAttribute: k => (k in a ? a[k] : null),
  }
}

function root(els) {
  return {
    selectors: [],
    querySelectorAll(sel) {
      this.selectors.push(sel)
      return els
    },
  }
}

test("says what SlipdockWeb.Dates.relative/2 says, case for case", () => {
  assert.ok(cases.length > 20)
  for (const c of cases) {
    assert.equal(relativeText(new Date(c.at), new Date(c.now), c.zone), c.says, `${c.at} at ${c.now} in ${c.zone}`)
  }
})

test("counts days on the viewer's calendar", () => {
  assert.deepEqual(localDay(new Date("2026-11-17T23:50:00Z"), "Pacific/Auckland"), {year: 2026, month: 11, day: 18})
  assert.deepEqual(localDay(new Date("2026-11-17T23:50:00Z"), "Etc/UTC"), {year: 2026, month: 11, day: 17})
  assert.deepEqual(localDay(new Date("2026-11-17T23:50:00Z"), "Nowhere/Land"), {year: 2026, month: 11, day: 17})
  assert.deepEqual(localDay(new Date("2026-11-17T23:50:00Z"), ""), {year: 2026, month: 11, day: 17})
})

test("an unreadable moment says nothing", () => {
  assert.equal(relativeText(NaN, Date.now()), null)
  assert.equal(relativeText(Date.now(), new Date("nope")), null)
})

test("textFor reads a marked <time> and leaves anything else alone", () => {
  const now = Date.parse("2026-11-18T12:00:00Z")
  const el = time({"data-relative": "past", datetime: "2026-11-18T11:42:00Z", "data-zone": "Etc/UTC"})
  assert.equal(textFor(el, now), "18 min ago")

  assert.equal(textFor(time({datetime: "2026-11-18T11:42:00Z"}), now), null, "not marked")
  assert.equal(textFor(time({"data-relative": "past"}), now), null, "no datetime")
  assert.equal(textFor(time({"data-relative": "past", datetime: "soon"}), now), null, "bad datetime")
  assert.equal(textFor(null, now), null)
  assert.equal(textFor({}, now), null)
})

test("no data-zone reads as UTC", () => {
  const el = time({"data-relative": "past", datetime: "2026-11-17T23:50:00Z"})
  assert.equal(textFor(el, Date.parse("2026-11-18T00:10:00Z")), "yesterday")
})

test("a past moment never reads as ahead when the browser's clock is behind", () => {
  // Posted at 12:00:00 by the server's clock; the browser thinks it is 11:59:58.
  const now = Date.parse("2026-11-18T11:59:58Z")
  const past = time({"data-relative": "past", datetime: "2026-11-18T12:00:00Z", "data-zone": "Etc/UTC"})
  assert.equal(textFor(past, now), "just now")

  const future = time({"data-relative": "future", datetime: "2026-11-18T12:05:00Z", "data-zone": "Etc/UTC"})
  assert.equal(textFor(future, now), "in 5 min")
  // A future moment goes by in its own time, without a re-render.
  assert.equal(textFor(future, Date.parse("2026-11-18T12:25:00Z")), "20 min ago")
})

test("tick rewrites every marked time under the root", () => {
  const a = time({"data-relative": "past", datetime: "2026-11-18T11:42:00Z", "data-zone": "Etc/UTC"}, "just now")
  const b = time({"data-relative": "past", datetime: "2026-11-18T09:00:00Z", "data-zone": "Etc/UTC"}, "1 min ago")
  const r = root([a, b])

  tick(r, Date.parse("2026-11-18T12:00:00Z"))

  assert.deepEqual(r.selectors, ["time[data-relative]"])
  assert.equal(a.textContent, "18 min ago")
  assert.equal(b.textContent, "3 h ago")
})

test("tick leaves text that is already right untouched", () => {
  let writes = 0
  const el = time({"data-relative": "past", datetime: "2026-11-18T11:42:00Z", "data-zone": "Etc/UTC"})
  let text = "18 min ago"
  Object.defineProperty(el, "textContent", {get: () => text, set: v => { writes++; text = v }})

  tick(root([el]), Date.parse("2026-11-18T12:00:00Z"))
  assert.equal(writes, 0)
})

test("a re-render's stale text is replaced before it is patched in", () => {
  const stale = time({"data-relative": "past", datetime: "2026-11-18T11:42:00Z", "data-zone": "Etc/UTC"}, "just now")
  refreshIncoming(null, stale, Date.parse("2026-11-18T12:00:00Z"))
  assert.equal(stale.textContent, "18 min ago")

  const other = {nodeName: "SPAN", textContent: "just now", getAttribute: () => "past"}
  refreshIncoming(null, other, Date.parse("2026-11-18T12:00:00Z"))
  assert.equal(other.textContent, "just now", "only <time>s")

  const plain = time({datetime: "2026-11-18T11:42:00Z"}, "18 Nov")
  refreshIncoming(null, plain, Date.parse("2026-11-18T12:00:00Z"))
  assert.equal(plain.textContent, "18 Nov", "an unmarked <time> keeps the server's words")

  assert.doesNotThrow(() => refreshIncoming(null, null))
})

test("installRelativeTime ticks at once, every 30 s, and when the tab comes back", () => {
  const el = time({"data-relative": "past", datetime: new Date(Date.now() - 3 * 86_400_000).toISOString(), "data-zone": "Etc/UTC"}, "just now")
  const listeners = {}
  const doc = {
    visibilityState: "visible",
    querySelectorAll: () => [el],
    addEventListener: (t, f) => { listeners[t] = f },
    removeEventListener: (t, f) => { if (listeners[t] === f) delete listeners[t] },
  }
  const timers = []
  const win = {
    document: doc,
    setInterval: (f, ms) => { timers.push({f, ms}); return timers.length },
    clearInterval: id => { timers[id - 1].cleared = true },
  }

  const stop = installRelativeTime(win)
  assert.equal(el.textContent, "3 days ago", "at once")
  assert.equal(timers.length, 1)
  assert.equal(timers[0].ms, TICK_MS)
  assert.equal(TICK_MS, 30_000)

  el.textContent = "stale"
  timers[0].f()
  assert.equal(el.textContent, "3 days ago", "on the tick")

  el.textContent = "stale"
  doc.visibilityState = "hidden"
  listeners.visibilitychange()
  assert.equal(el.textContent, "stale", "not while hidden")
  doc.visibilityState = "visible"
  listeners.visibilitychange()
  assert.equal(el.textContent, "3 days ago", "when it comes back")

  stop()
  assert.ok(timers[0].cleared)
  assert.equal(listeners.visibilitychange, undefined)
})
