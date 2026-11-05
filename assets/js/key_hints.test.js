// node --test assets/js
import {test} from "node:test"
import assert from "node:assert/strict"
import {hintsAfter, installKeyHints} from "./key_hints.js"

test("Alt down shows the hints, Alt up hides them, other keys leave them", () => {
  assert.equal(hintsAfter({type: "keydown", key: "Alt"}, false), true)
  assert.equal(hintsAfter({type: "keyup", key: "Alt"}, true), false)
  assert.equal(hintsAfter({type: "keydown", key: "c"}, true), true)
  assert.equal(hintsAfter({type: "keydown", key: "c"}, false), false)
  assert.equal(hintsAfter({type: "keyup", key: "Shift"}, true), true)
})

function fakeWindow() {
  const listeners = {}
  return {
    listeners,
    addEventListener: (t, f) => { (listeners[t] ||= new Set()).add(f) },
    removeEventListener: (t, f) => { listeners[t]?.delete(f) },
    fire: (t, e = {}) => { for (const f of listeners[t] || []) f({type: t, ...e}) },
  }
}

function fakeEl() {
  const attrs = {}
  return {
    attrs,
    setAttribute: (k, v) => { attrs[k] = v },
    removeAttribute: k => { delete attrs[k] },
  }
}

test("the panel gets data-show-keys while Alt is held, and loses it on blur", () => {
  const win = fakeWindow()
  const el = fakeEl()
  const stop = installKeyHints(el, win)

  win.fire("keydown", {key: "Alt"})
  assert.ok("data-show-keys" in el.attrs)
  win.fire("keydown", {key: "f"})
  assert.ok("data-show-keys" in el.attrs)
  win.fire("keyup", {key: "Alt"})
  assert.ok(!("data-show-keys" in el.attrs))

  win.fire("keydown", {key: "Alt"})
  win.fire("blur")
  assert.ok(!("data-show-keys" in el.attrs))

  win.fire("keydown", {key: "Alt"})
  stop()
  assert.ok(!("data-show-keys" in el.attrs))
  assert.equal(win.listeners.keydown.size, 0)
  assert.equal(win.listeners.blur.size, 0)
})
