// node --test assets/js — a board page asks whether it has missed a change,
// and says so when its connection stops answering (#2918).
import {test, mock, beforeEach, afterEach} from "node:test"
import assert from "node:assert/strict"
import {ANSWER_WITHIN, BoardResync, PROBE_EVERY, noAnswer, probe} from "./board_resync.js"

// A document and window that only keep their listeners, so a test can fire them.
function target() {
  const listeners = {}
  return {
    listeners,
    addEventListener(name, fn) { (listeners[name] ||= []).push(fn) },
    removeEventListener(name, fn) { listeners[name] = (listeners[name] || []).filter(f => f !== fn) },
    fire(name) { (listeners[name] || []).forEach(fn => fn()) },
  }
}

function hook({connected = true, answers = true} = {}) {
  const notice = {hidden: true}
  const socket = {
    connected,
    reconnects: 0,
    isConnected() { return this.connected },
    disconnect(then) { this.reconnects++; then() },
    connect() {},
  }
  const h = {
    ...BoardResync,
    el: {querySelector: sel => (sel === "[data-stale-notice]" ? notice : null)},
    liveSocket: socket,
    pushed: [],
    answers,
    pushEvent(event, payload, reply) {
      this.pushed.push(event)
      if (this.answers) reply({resynced: false})
    },
  }
  return {h, notice, socket}
}

beforeEach(() => {
  mock.timers.enable({apis: ["setTimeout", "setInterval"]})
  globalThis.document = Object.assign(target(), {visibilityState: "visible"})
  globalThis.window = target()
})

afterEach(() => {
  mock.timers.reset()
  delete globalThis.document
  delete globalThis.window
})

test("an answered question leaves the notice hidden and nothing reconnects", () => {
  const {h, notice, socket} = hook()
  probe(h)
  mock.timers.tick(ANSWER_WITHIN + 1)
  assert.deepEqual(h.pushed, ["resync"])
  assert.equal(notice.hidden, true)
  assert.equal(socket.reconnects, 0)
})

test("no answer in time shows the notice and reconnects", () => {
  const {h, notice, socket} = hook({answers: false})
  probe(h)
  mock.timers.tick(ANSWER_WITHIN - 1)
  assert.equal(notice.hidden, true, "not before the time is up")
  mock.timers.tick(1)
  assert.equal(notice.hidden, false)
  assert.equal(socket.reconnects, 1)
})

test("a socket that knows it is down is left to its own banner", () => {
  const {h, notice, socket} = hook({connected: false})
  noAnswer(h)
  assert.equal(notice.hidden, true)
  assert.equal(socket.reconnects, 0)
})

test("one question at a time: a second waits for the first", () => {
  const {h} = hook({answers: false})
  probe(h)
  probe(h)
  assert.deepEqual(h.pushed, ["resync"])
  mock.timers.tick(ANSWER_WITHIN)
  probe(h)
  assert.deepEqual(h.pushed, ["resync", "resync"])
})

test("a late answer hides the notice", () => {
  const {h, notice} = hook({answers: false})
  let reply
  h.pushEvent = (_e, _p, r) => { reply = r }
  probe(h)
  mock.timers.tick(ANSWER_WITHIN)
  assert.equal(notice.hidden, false)
  probe(h)
  reply({resynced: true})
  assert.equal(notice.hidden, true)
})

test("it asks when the tab comes back into view, online and from the back-forward cache", () => {
  const {h} = hook()
  h.mounted()
  document.visibilityState = "hidden"
  document.fire("visibilitychange")
  assert.deepEqual(h.pushed, [], "not while hidden")
  document.visibilityState = "visible"
  document.fire("visibilitychange")
  window.fire("online")
  window.fire("pageshow")
  assert.deepEqual(h.pushed, ["resync", "resync", "resync"])
})

test("once a minute while in view, never while hidden", () => {
  assert.equal(PROBE_EVERY, 60_000, "about once a minute (bar 2)")
  const {h} = hook()
  h.mounted()
  mock.timers.tick(59_999)
  assert.equal(h.pushed.length, 0, "not before the minute is up")
  mock.timers.tick(1)
  assert.equal(h.pushed.length, 1)
  document.visibilityState = "hidden"
  mock.timers.tick(PROBE_EVERY * 3)
  assert.equal(h.pushed.length, 1)
})

test("a reconnect hides the notice, and destroyed stops asking", () => {
  const {h, notice} = hook({answers: false})
  h.mounted()
  probe(h)
  mock.timers.tick(ANSWER_WITHIN)
  assert.equal(notice.hidden, false)
  h.reconnected()
  assert.equal(notice.hidden, true)
  h.destroyed()
  h.answers = true
  mock.timers.tick(PROBE_EVERY * 2)
  document.fire("visibilitychange")
  assert.deepEqual(h.pushed, ["resync"])
})
