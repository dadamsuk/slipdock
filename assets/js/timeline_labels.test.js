// node --test assets/js — the timeline's title column width and the routing
// of dependency lines around titles (#1732), with <html>, localStorage and
// the handle faked down to what is touched.
import {test} from "node:test"
import assert from "node:assert/strict"
import {
  clampLabelWidth, setLabelWidth, resetLabelWidth, restoreLabelWidth, labelWidth,
  TimelineLabelResize, linkPath,
  LABEL_WIDTH_KEY, DEFAULT_LABEL_WIDTH, MIN_LABEL_WIDTH, MAX_LABEL_WIDTH, LABEL_STEP,
} from "./timeline_labels.js"

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
  return {
    attrs, listeners,
    getAttribute: k => (k in attrs ? attrs[k] : null),
    setAttribute: (k, v) => { attrs[k] = String(v) },
    removeAttribute: k => { delete attrs[k] },
    style: {
      props,
      setProperty: (k, v) => { props[k] = v },
      removeProperty: k => { delete props[k] },
      getPropertyValue: k => props[k] || "",
    },
    addEventListener: (t, fn) => { listeners[t] = fn },
    removeEventListener: t => { delete listeners[t] },
    fire(t, e = {}) {
      const ev = {
        prevented: false, stopped: false,
        preventDefault() { ev.prevented = true }, stopPropagation() { ev.stopped = true }, ...e,
      }
      listeners[t](ev)
      return ev
    },
  }
}

function mount(extra = {}) {
  const hook = Object.create(TimelineLabelResize)
  let redraws = 0
  Object.assign(hook, {el: element(), root: element(), storage: storage(), redraw: () => redraws++}, extra)
  hook.mounted()
  hook.redraws = () => redraws
  return hook
}

test("widths are clamped, rounded, and nonsense falls back to the default", () => {
  assert.equal(clampLabelWidth(10), MIN_LABEL_WIDTH)
  assert.equal(clampLabelWidth(5000), MAX_LABEL_WIDTH)
  assert.equal(clampLabelWidth("300.6"), 301)
  assert.equal(clampLabelWidth("wide"), DEFAULT_LABEL_WIDTH)
  assert.equal(clampLabelWidth(undefined), DEFAULT_LABEL_WIDTH)
})

test("restoreLabelWidth puts back a saved width, clamped, and saves nothing itself", () => {
  const root = element()
  const store = storage({[LABEL_WIDTH_KEY]: "9999"})
  restoreLabelWidth(root, store)
  assert.equal(root.style.props["--tl-label-width"], `${MAX_LABEL_WIDTH}px`)
  assert.equal(store.items[LABEL_WIDTH_KEY], "9999")
})

test("with nothing saved, or storage refused, the column keeps its default", () => {
  for (const store of [storage(), brokenStorage]) {
    const root = element()
    restoreLabelWidth(root, store)
    assert.deepEqual(root.style.props, {})
    assert.equal(labelWidth(root), DEFAULT_LABEL_WIDTH)
  }
})

test("setting and resetting write through to storage; a refusing one still sets it", () => {
  const root = element()
  const store = storage()
  assert.equal(setLabelWidth(root, store, 320), 320)
  assert.equal(store.items[LABEL_WIDTH_KEY], "320")
  assert.equal(labelWidth(root), 320)
  assert.equal(resetLabelWidth(root, store), DEFAULT_LABEL_WIDTH)
  assert.equal(root.style.props["--tl-label-width"], undefined)
  assert.equal(store.items[LABEL_WIDTH_KEY], undefined)

  assert.equal(setLabelWidth(root, brokenStorage, 400), 400)
  assert.equal(root.style.props["--tl-label-width"], "400px")
  assert.equal(resetLabelWidth(root, brokenStorage), DEFAULT_LABEL_WIDTH)
})

test("dragging the handle widens the column live and saves it on release", () => {
  const hook = mount()
  assert.equal(hook.el.attrs["aria-valuenow"], String(DEFAULT_LABEL_WIDTH))
  assert.equal(hook.el.attrs["aria-valuemin"], String(MIN_LABEL_WIDTH))

  const down = hook.el.fire("pointerdown", {button: 0, clientX: 100})
  assert.ok(down.prevented)
  assert.equal(hook.el.attrs["data-dragging"], "")
  hook.el.fire("pointermove", {clientX: 220})
  assert.equal(hook.root.style.props["--tl-label-width"], `${DEFAULT_LABEL_WIDTH + 120}px`)
  assert.equal(hook.storage.items[LABEL_WIDTH_KEY], undefined, "not saved mid-drag")
  hook.el.fire("pointerup")
  assert.equal(hook.storage.items[LABEL_WIDTH_KEY], String(DEFAULT_LABEL_WIDTH + 120))
  assert.equal(hook.el.getAttribute("data-dragging"), null)
  assert.equal(hook.el.attrs["aria-valuenow"], String(DEFAULT_LABEL_WIDTH + 120))
  assert.ok(hook.redraws() >= 2, "lines redrawn as the bars move")

  // A drag far past either end stops at the limits.
  hook.el.fire("pointerdown", {button: 0, clientX: 0})
  hook.el.fire("pointermove", {clientX: -5000})
  hook.el.fire("pointerup")
  assert.equal(hook.storage.items[LABEL_WIDTH_KEY], String(MIN_LABEL_WIDTH))
})

test("a press on the handle stops there, so it never starts a bar's drag (#2883)", () => {
  const hook = mount()
  assert.ok(hook.el.fire("pointerdown", {button: 0, clientX: 0}).stopped)
  assert.equal(hook.el.fire("pointerdown", {button: 2, clientX: 0}).stopped, false)
})

test("other buttons, and moves or releases without a drag, do nothing", () => {
  const hook = mount()
  hook.el.fire("pointerdown", {button: 2, clientX: 100})
  hook.el.fire("pointermove", {clientX: 300})
  hook.el.fire("pointerup")
  assert.deepEqual(hook.root.style.props, {})
  assert.deepEqual(hook.storage.items, {})
  assert.equal(hook.redraws(), 0)
})

test("arrow keys step the width, Home and End jump, Enter and a double-click reset", () => {
  const hook = mount()
  hook.el.fire("keydown", {key: "ArrowRight"})
  assert.equal(hook.storage.items[LABEL_WIDTH_KEY], String(DEFAULT_LABEL_WIDTH + LABEL_STEP))
  hook.el.fire("keydown", {key: "ArrowLeft"})
  hook.el.fire("keydown", {key: "ArrowLeft"})
  assert.equal(hook.storage.items[LABEL_WIDTH_KEY], String(DEFAULT_LABEL_WIDTH - LABEL_STEP))
  hook.el.fire("keydown", {key: "End"})
  assert.equal(hook.el.attrs["aria-valuenow"], String(MAX_LABEL_WIDTH))
  hook.el.fire("keydown", {key: "Home"})
  assert.equal(hook.el.attrs["aria-valuenow"], String(MIN_LABEL_WIDTH))
  const enter = hook.el.fire("keydown", {key: "Enter"})
  assert.ok(enter.prevented)
  assert.equal(hook.storage.items[LABEL_WIDTH_KEY], undefined)
  assert.equal(hook.el.attrs["aria-valuenow"], String(DEFAULT_LABEL_WIDTH))

  hook.el.fire("keydown", {key: "End"})
  hook.el.fire("dblclick")
  assert.equal(hook.root.style.props["--tl-label-width"], undefined)

  const other = hook.el.fire("keydown", {key: "a"})
  assert.equal(other.prevented, false)
})

test("destroyed removes every listener", () => {
  const hook = mount()
  hook.destroyed()
  assert.deepEqual(hook.el.listeners, {})
})

const rect = (left, top, width, height) => ({left, top, width, height, right: left + width, bottom: top + height})
const box = rect(10, 20, 2000, 1000)

test("a line leaves a bar's right end sideways and arrives at the next bar's left", () => {
  const {d, x2, y2} = linkPath(box, rect(110, 120, 50, 24), rect(260, 170, 30, 24))
  // (150,112) → (250,162), controls half the gap out sideways.
  assert.equal(d, "M150,112 C200,112 200,162 250,162")
  assert.deepEqual([x2, y2], [250, 162])
})

test("close bars still bow out at least 16px", () => {
  const {d} = linkPath(box, rect(110, 120, 50, 24), rect(170, 170, 30, 24))
  assert.equal(d, "M150,112 C166,112 144,162 160,162")
})

test("a blocker with its title on the right is left from its bottom edge, going down", () => {
  const {d} = linkPath(box, rect(110, 120, 14, 24), rect(300, 170, 30, 24), true)
  // From (124-10-4, 144-20) straight down, then sideways into the target.
  assert.match(d, /^M110,124 C110,149 /)
  assert.match(d, / 290,162$/)
})

test("... or from its top edge when the bar it blocks is above", () => {
  const {d} = linkPath(box, rect(110, 220, 14, 24), rect(300, 120, 30, 24), true)
  assert.match(d, /^M110,200 C110,150 /)
})

test("a blocked bar with its title on the left is reached from above or below", () => {
  const down = linkPath(box, rect(110, 120, 50, 24), rect(300, 220, 30, 24), false, true)
  assert.deepEqual([down.x2, down.y2], [294, 200])
  assert.match(down.d, / 294,150 294,200$/)

  const up = linkPath(box, rect(110, 220, 50, 24), rect(300, 120, 30, 24), false, true)
  assert.deepEqual([up.x2, up.y2], [294, 124])
})

test("a sliver of a bar is left from its middle, not past its far edge", () => {
  const {d} = linkPath(box, rect(110, 120, 4, 24), rect(300, 170, 30, 24), true)
  assert.match(d, /^M102,124 /)
})
