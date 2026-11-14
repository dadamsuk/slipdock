// node --test assets/js — the arithmetic of dragging the phone's floating
// button (#1130); tools/e2e/mobile-dock-drag.sh drags it in a browser.
import {test} from "node:test"
import assert from "node:assert/strict"
import {DRAG_START, MARGIN, STORE_KEY, isDrag, settle, clampTop, placement, save, load, DockDrag} from "./dock_drag.js"

const phone = {width: 390, height: 844}

function storage(initial = {}) {
  const data = {...initial}
  return {data, getItem: k => (k in data ? data[k] : null), setItem: (k, v) => { data[k] = String(v) }}
}

test("a small wobble is a tap, a longer move is a drag", () => {
  assert.equal(isDrag(3, 4), false)
  assert.equal(isDrag(DRAG_START - 1, 0), false)
  assert.equal(isDrag(0, DRAG_START), true)
  assert.equal(isDrag(-20, 5), true)
})

test("settles on the side its centre is nearer", () => {
  assert.equal(settle({x: 10, y: 400}, 56, phone).side, "left")
  assert.equal(settle({x: 300, y: 400}, 56, phone).side, "right")
  // Centre exactly in the middle goes right; one pixel left of it, left.
  assert.equal(settle({x: 195 - 28, y: 400}, 56, phone).side, "right")
  assert.equal(settle({x: 195 - 29, y: 400}, 56, phone).side, "left")
})

test("keeps the height it was dropped at, but never off the screen", () => {
  assert.equal(settle({x: 0, y: 400}, 56, phone).top, 400)
  assert.equal(clampTop(-50, 56, phone), MARGIN)
  assert.equal(clampTop(5000, 56, phone), phone.height - 56 - MARGIN)
  // A screen shorter than the button pins it to the margin rather than going negative.
  assert.equal(clampTop(100, 56, {width: 300, height: 40}), MARGIN)
})

test("placement pins the chosen side and frees the other", () => {
  const left = placement({side: "left", top: 600}, 56, phone)
  assert.equal(left.style, `top:600px;bottom:auto;left:${MARGIN}px;right:auto;--dock-room:580px`)
  assert.equal(left.side, "left")

  const right = placement({side: "right", top: 600}, 56, phone)
  assert.equal(right.style, `top:600px;bottom:auto;right:${MARGIN}px;left:auto;--dock-room:580px`)
  assert.equal(right.side, "right")
})

test("in the top half the Menu opens downwards", () => {
  assert.equal(placement({side: "left", top: 100}, 56, phone).edge, "top")
  assert.equal(placement({side: "left", top: 700}, 56, phone).edge, "bottom")
  // A position saved on a taller screen is clamped before it is judged.
  const p = placement({side: "left", top: 2000}, 56, phone)
  assert.equal(p.style.startsWith(`top:${phone.height - 56 - MARGIN}px`), true)
  assert.equal(p.edge, "bottom")
})

test("the Menu gets the room on the side it opens, and never less than none", () => {
  // Downwards: 844 - 100 - 56 - 8 (gap) - 12 (margin).
  assert.match(placement({side: "left", top: 100}, 56, phone).style, /--dock-room:668px$/)
  // Upwards: 600 - 8 (gap) - 12 (margin).
  assert.match(placement({side: "left", top: 600}, 56, phone).style, /--dock-room:580px$/)
  // A screen too short for any.
  assert.match(placement({side: "left", top: 0}, 56, {width: 300, height: 60}).style, /--dock-room:0px$/)
})

test("remembers the position as a fraction of the height, so a turned phone keeps it", () => {
  const s = storage()
  save(s, {side: "right", top: 422}, phone)
  assert.deepEqual(JSON.parse(s.data[STORE_KEY]), {side: "right", y: 0.5})

  assert.deepEqual(load(s, phone), {side: "right", top: 422})
  assert.deepEqual(load(s, {width: 844, height: 390}), {side: "right", top: 195})
})

test("nothing saved, or something unreadable, means the default corner", () => {
  assert.equal(load(storage(), phone), null)
  assert.equal(load(storage({[STORE_KEY]: "not json"}), phone), null)
  assert.equal(load(storage({[STORE_KEY]: JSON.stringify({side: "middle", y: 0.5})}), phone), null)
  assert.equal(load(storage({[STORE_KEY]: JSON.stringify({side: "left", y: "half"})}), phone), null)
  assert.equal(load({getItem: () => { throw new Error("denied") }}, phone), null)
})

test("storage that refuses a write is not an error", () => {
  assert.doesNotThrow(() => save({setItem: () => { throw new Error("quota") }}, {side: "left", top: 1}, phone))
})

// Where storage is blocked, reading the `localStorage` property itself throws
// (#2882): runs `fn` with such a getter in place.
function whileStorageBlocked(fn) {
  const before = Object.getOwnPropertyDescriptor(globalThis, "localStorage")
  Object.defineProperty(globalThis, "localStorage", {configurable: true, get() { throw new Error("SecurityError") }})
  try { return fn() } finally {
    if (before) Object.defineProperty(globalThis, "localStorage", before)
    else delete globalThis.localStorage
  }
}

test("where reading localStorage throws, nothing is loaded and saving doesn't throw", () => {
  whileStorageBlocked(() => {
    assert.equal(load(undefined, phone), null)
    assert.doesNotThrow(() => save(undefined, {side: "left", top: 100}, phone))
  })
})

// The hook itself, mounted where storage is blocked (#2882): `window` is
// faked down to what the hook touches, and its `localStorage` throws too.
test("where reading localStorage throws, the hook mounts and a drag ends without throwing", () => {
  const before = globalThis.window
  const blocked = {configurable: true, get() { throw new Error("SecurityError") }}
  const win = {innerWidth: phone.width, innerHeight: phone.height, addEventListener() {}, removeEventListener() {}}
  Object.defineProperty(win, "localStorage", blocked)
  globalThis.window = win
  try {
    whileStorageBlocked(() => {
      const on = {}
      const fab = {
        offsetHeight: 56,
        addEventListener: (type, fn) => { on[type] = fn },
        getBoundingClientRect: () => ({left: 12, top: 700}),
        setPointerCapture() {},
      }
      const attrs = {"phx-click-away": "[]"}
      const el = {
        dataset: {},
        querySelector: sel => (sel === "#mobile-fab" ? fab : null),
        getAttribute: k => attrs[k] ?? null,
        setAttribute: (k, v) => { attrs[k] = v },
      }
      const hook = Object.assign(Object.create(DockDrag), {
        el,
        js: () => ({ignoreAttributes() {}, exec() {}}),
      })
      assert.doesNotThrow(() => hook.mounted())
      assert.equal(hook.pos, null)

      on.pointerdown({button: 0, clientX: 40, clientY: 720})
      on.pointermove({clientX: 300, clientY: 400, preventDefault() {}})
      assert.doesNotThrow(() => on.pointerup({type: "pointerup", clientX: 300, clientY: 400}))
      assert.equal(hook.pos.side, "right")
      assert.equal(el.dataset.side, "right")
    })
  } finally {
    globalThis.window = before
  }
})
