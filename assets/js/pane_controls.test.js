// node --test assets/js — the shared pane controls (#2883): a width kept on
// <html>, an on/off layout flag, the resize handle and the toggle button,
// with <html>, localStorage and the elements faked down to what is touched.
import {test} from "node:test"
import assert from "node:assert/strict"
import {read, write, widthPref, rootFlag, resizeHandle, rootToggle} from "./pane_controls.js"

function storage(initial = {}) {
  const items = {...initial}
  return {
    items,
    getItem: k => (k in items ? items[k] : null),
    setItem: (k, v) => { items[k] = String(v) },
    removeItem: k => { delete items[k] },
  }
}

const brokenStorage = {
  getItem() { throw new Error("denied") },
  setItem() { throw new Error("denied") },
  removeItem() { throw new Error("denied") },
}

function element() {
  const attrs = {}
  const props = {}
  const listeners = {}
  const captured = []
  return {
    attrs, listeners, captured,
    getAttribute: k => (k in attrs ? attrs[k] : null),
    setAttribute: (k, v) => { attrs[k] = String(v) },
    removeAttribute: k => { delete attrs[k] },
    hasAttribute: k => k in attrs,
    setPointerCapture: id => captured.push(id),
    style: {
      props,
      setProperty: (k, v) => { props[k] = v },
      removeProperty: k => { delete props[k] },
      getPropertyValue: k => props[k] || "",
    },
    addEventListener: (t, fn) => { listeners[t] = fn },
    removeEventListener: (t, fn) => { if (listeners[t] === fn) delete listeners[t] },
    fire(t, e = {}) {
      const ev = {
        prevented: false, stopped: false,
        preventDefault() { ev.prevented = true },
        stopPropagation() { ev.stopped = true },
        ...e,
      }
      listeners[t](ev)
      return ev
    },
  }
}

const KEY = "test:width"
const PROP = "--test-width"
const pref = () => widthPref({prop: PROP, key: KEY, min: 100, max: 500, def: 200})

function mountHandle(opts = {}, extra = {}) {
  const changes = []
  const hookDef = resizeHandle({pref: pref(), step: 10, onChange: h => changes.push(h), ...opts})
  const hook = Object.create(hookDef)
  Object.assign(hook, {el: element(), root: element(), storage: storage()}, extra)
  hook.mounted()
  hook.changes = changes
  return hook
}

test("read and write go through to storage, and a refusing one neither throws nor keeps", () => {
  const store = storage()
  write("k", "v", store)
  assert.equal(read("k", store), "v")
  write("k", null, store)
  assert.equal(read("k", store), null)
  assert.equal(read("k", brokenStorage), null)
  write("k", "v", brokenStorage)
  write("k", null, brokenStorage)
})

test("widthPref clamps, rounds, and falls back to its default", () => {
  const w = pref()
  assert.equal(w.clamp(10), 100)
  assert.equal(w.clamp(9000), 500)
  assert.equal(w.clamp("250.5"), 251)
  assert.equal(w.clamp("wide"), 200)
  assert.equal(w.clamp(undefined), 200)
  assert.equal(w.clamp(NaN), 200)
})

test("widthPref sets, reads back, resets and restores through its variable and key", () => {
  const w = pref()
  const root = element()
  const store = storage()
  assert.equal(w.current(root), 200)
  assert.equal(w.set(root, store, 300), 300)
  assert.equal(root.style.props[PROP], "300px")
  assert.equal(store.items[KEY], "300")
  assert.equal(w.current(root), 300)

  assert.equal(w.set(root, store, 320, {save: false}), 320)
  assert.equal(store.items[KEY], "300", "a live width is not saved")

  assert.equal(w.reset(root, store), 200)
  assert.equal(root.style.props[PROP], undefined)
  assert.equal(store.items[KEY], undefined)

  assert.equal(w.saved(storage()), null)
  assert.equal(w.saved(storage({[KEY]: "9999"})), 500)
  assert.equal(w.saved(brokenStorage), null)

  const restored = element()
  const kept = storage({[KEY]: "50"})
  w.restore(restored, kept)
  assert.equal(restored.style.props[PROP], "100px")
  assert.equal(kept.items[KEY], "50", "restoring saves nothing")

  const untouched = element()
  w.restore(untouched, brokenStorage)
  assert.deepEqual(untouched.style.props, {})
})

test("rootFlag sets its attribute and key together, and restores only a kept '1'", () => {
  const flag = rootFlag({attr: "data-x", value: "on", key: "test:x"})
  const root = element()
  const store = storage()
  assert.equal(flag.is(root), false)
  assert.equal(flag.set(root, store, true), true)
  assert.equal(root.attrs["data-x"], "on")
  assert.equal(store.items["test:x"], "1")
  assert.equal(flag.is(root), true)
  assert.equal(flag.set(root, store, false), false)
  assert.equal(root.getAttribute("data-x"), null)
  assert.equal(store.items["test:x"], undefined)

  root.setAttribute("data-x", "other")
  assert.equal(flag.is(root), false, "another value is not on")

  for (const [kept, want] of [[storage({"test:x": "1"}), "on"], [storage({"test:x": "yes"}), null],
                              [storage(), null], [brokenStorage, null]]) {
    const r = element()
    flag.restore(r, kept)
    assert.equal(r.getAttribute("data-x"), want)
  }

  const r = element()
  assert.equal(flag.set(r, brokenStorage, true), true)
  assert.equal(r.attrs["data-x"], "on", "a refusing storage still sets it for the visit")
})

test("the handle mounts saying its range and the width already set", () => {
  const root = element()
  root.style.setProperty(PROP, "333px")
  const hook = mountHandle({}, {root})
  assert.equal(hook.el.attrs["aria-valuemin"], "100")
  assert.equal(hook.el.attrs["aria-valuemax"], "500")
  assert.equal(hook.el.attrs["aria-valuenow"], "333")
  assert.equal(hook.changes.length, 0, "mounting changes nothing")
})

test("a drag starts from the variable's width, shows it live, and saves on release", () => {
  const hook = mountHandle()
  const down = hook.el.fire("pointerdown", {button: 0, clientX: 50, pointerId: 7})
  assert.ok(down.prevented)
  assert.equal(down.stopped, false, "propagation is left alone unless asked")
  assert.deepEqual(hook.el.captured, [7])
  assert.ok(hook.el.hasAttribute("data-dragging"))

  hook.el.fire("pointermove", {clientX: 120})
  assert.equal(hook.root.style.props[PROP], "270px")
  assert.equal(hook.el.attrs["aria-valuenow"], "270")
  assert.equal(hook.storage.items[KEY], undefined)

  hook.el.fire("pointerup")
  assert.equal(hook.storage.items[KEY], "270")
  assert.ok(!hook.el.hasAttribute("data-dragging"))
  assert.equal(hook.changes.length, 2)
  assert.equal(hook.changes[0], hook, "onChange is given the hook")

  // Nothing held: moves and releases change nothing.
  hook.el.fire("pointermove", {clientX: 900})
  hook.el.fire("pointerup")
  assert.equal(hook.root.style.props[PROP], "270px")
  assert.equal(hook.changes.length, 2)
})

test("a pointercancel ends a drag as a release does", () => {
  const hook = mountHandle()
  hook.el.fire("pointerdown", {button: 0, clientX: 0})
  hook.el.fire("pointermove", {clientX: 5000})
  hook.el.fire("pointercancel")
  assert.equal(hook.storage.items[KEY], "500")
  assert.ok(!hook.el.hasAttribute("data-dragging"))
})

test("a press without a pointer id is not captured, and a press without a button is a drag", () => {
  const hook = mountHandle()
  hook.el.fire("pointerdown", {clientX: 0})
  assert.deepEqual(hook.el.captured, [])
  assert.ok(hook.el.hasAttribute("data-dragging"))
})

test("stopPropagation keeps the press from what is under the handle", () => {
  const hook = mountHandle({stopPropagation: true})
  const down = hook.el.fire("pointerdown", {button: 0, clientX: 0})
  assert.ok(down.stopped)
})

test("startWidth says where a drag starts from", () => {
  const hook = mountHandle({startWidth: h => (h.seen = true, 400)})
  hook.el.fire("pointerdown", {button: 0, clientX: 0})
  assert.ok(hook.seen)
  hook.el.fire("pointermove", {clientX: 30})
  assert.equal(hook.root.style.props[PROP], "430px")
})

test("another button does not start a drag or stop the press", () => {
  const hook = mountHandle({stopPropagation: true})
  const down = hook.el.fire("pointerdown", {button: 2, clientX: 0})
  assert.equal(down.prevented, false)
  assert.equal(down.stopped, false)
  hook.el.fire("pointermove", {clientX: 100})
  hook.el.fire("pointerup")
  assert.deepEqual(hook.root.style.props, {})
  assert.deepEqual(hook.storage.items, {})
  assert.equal(hook.changes.length, 0)
})

test("the keys step, jump and reset; other keys are the page's", () => {
  const hook = mountHandle()
  hook.el.fire("keydown", {key: "ArrowRight"})
  assert.equal(hook.storage.items[KEY], "210")
  hook.el.fire("keydown", {key: "ArrowLeft"})
  hook.el.fire("keydown", {key: "ArrowLeft"})
  assert.equal(hook.storage.items[KEY], "190")
  hook.el.fire("keydown", {key: "End"})
  assert.equal(hook.el.attrs["aria-valuenow"], "500")
  hook.el.fire("keydown", {key: "ArrowRight"})
  assert.equal(hook.el.attrs["aria-valuenow"], "500", "End is the widest")
  hook.el.fire("keydown", {key: "Home"})
  assert.equal(hook.el.attrs["aria-valuenow"], "100")

  const enter = hook.el.fire("keydown", {key: "Enter"})
  assert.ok(enter.prevented)
  assert.equal(hook.storage.items[KEY], undefined)
  assert.equal(hook.el.attrs["aria-valuenow"], "200")
  assert.equal(hook.changes.length, 7)

  const other = hook.el.fire("keydown", {key: "a"})
  assert.equal(other.prevented, false)
  assert.equal(hook.changes.length, 7)
})

test("a double-click puts the width back", () => {
  const hook = mountHandle()
  hook.el.fire("keydown", {key: "End"})
  hook.el.fire("dblclick")
  assert.equal(hook.root.style.props[PROP], undefined)
  assert.equal(hook.storage.items[KEY], undefined)
  assert.equal(hook.el.attrs["aria-valuenow"], "200")
  assert.equal(hook.changes.length, 2)
})

test("a storage that refuses still lets the handle move the pane for this visit", () => {
  const hook = mountHandle({}, {storage: brokenStorage})
  hook.el.fire("keydown", {key: "ArrowRight"})
  assert.equal(hook.root.style.props[PROP], "210px")
  hook.el.fire("dblclick")
  assert.equal(hook.root.style.props[PROP], undefined)
})

test("the handle lets go of every listener on destroy", () => {
  const hook = mountHandle()
  assert.deepEqual(Object.keys(hook.el.listeners).sort(),
    ["dblclick", "keydown", "pointercancel", "pointerdown", "pointermove", "pointerup"])
  hook.destroyed()
  assert.deepEqual(Object.keys(hook.el.listeners), [])
})

function mountToggle(opts, extra = {}) {
  const flag = rootFlag({attr: "data-x", value: "on", key: "test:x"})
  const hook = Object.create(rootToggle({flag, titles: {on: "Turn off", off: "Turn on"}, ...opts}))
  Object.assign(hook, {el: element(), root: element(), storage: storage()}, extra)
  hook.mounted()
  return hook
}

test("the toggle flips its flag, saying which on itself", () => {
  const hook = mountToggle({aria: "aria-pressed"})
  assert.equal(hook.el.attrs["aria-pressed"], "false")
  assert.equal(hook.el.attrs.title, "Turn on")

  hook.el.fire("click")
  assert.equal(hook.root.attrs["data-x"], "on")
  assert.equal(hook.storage.items["test:x"], "1")
  assert.equal(hook.el.attrs["aria-pressed"], "true")
  assert.equal(hook.el.attrs.title, "Turn off")

  hook.el.fire("click")
  assert.equal(hook.root.getAttribute("data-x"), null)
  assert.equal(hook.storage.items["test:x"], undefined)
  assert.equal(hook.el.attrs["aria-pressed"], "false")

  hook.destroyed()
  assert.equal(hook.el.listeners.click, undefined)
})

test("an inverted toggle says the opposite of its flag, and mounts showing a restored one", () => {
  const root = element()
  root.setAttribute("data-x", "on")
  const hook = mountToggle({aria: "aria-expanded", invert: true}, {root})
  assert.equal(hook.el.attrs["aria-expanded"], "false")
  assert.equal(hook.el.attrs.title, "Turn off")
  hook.el.fire("click")
  assert.equal(hook.el.attrs["aria-expanded"], "true")
})
