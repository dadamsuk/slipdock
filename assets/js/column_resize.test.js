// node --test assets/js — dragging a column heading's edge (#3665).
import {test} from "node:test"
import assert from "node:assert/strict"
import {ColumnResize, MAX_WIDTH, MIN_WIDTH, STEP, clampWidth, dragWidth} from "./column_resize.js"

// Just enough of an element: listeners, attributes, a style, a rect.
function fakeEl({dataset = {}, width = 0} = {}) {
  const listeners = {}
  const attrs = {}
  const props = {}
  return {
    dataset,
    listeners,
    attrs,
    props,
    style: {
      setProperty: (k, v) => { props[k] = v },
      removeProperty: k => { delete props[k] },
    },
    addEventListener: (type, fn) => { listeners[type] = fn },
    removeEventListener: type => { delete listeners[type] },
    setAttribute: (k, v) => { attrs[k] = v },
    removeAttribute: k => { delete attrs[k] },
    getBoundingClientRect: () => ({width}),
  }
}

function mount({width = 200} = {}) {
  const table = fakeEl()
  const heading = fakeEl({width})
  const el = fakeEl({dataset: {view: "table", col: "priority", var: "--cw-priority", target: "#card-table"}})
  el.parentElement = heading
  globalThis.document = {querySelector: sel => (sel === "#card-table" ? table : null)}
  const pushed = []
  const hook = {...ColumnResize, el, pushEvent: (event, payload) => pushed.push([event, payload])}
  hook.mounted()
  return {hook, el, table, pushed}
}

const event = (extra = {}) => ({button: 0, preventDefault() {}, stopPropagation() {}, ...extra})

test("a width is a whole number of pixels between the limits", () => {
  assert.equal(clampWidth(120.4), 120)
  assert.equal(clampWidth(1), MIN_WIDTH)
  assert.equal(clampWidth(99999), MAX_WIDTH)
  assert.equal(clampWidth("abc"), null)
  assert.equal(dragWidth(200, 37), 237)
  assert.equal(dragWidth(200, -400), MIN_WIDTH)
})

test("dragging moves the column as it goes and sends the width when let go", () => {
  const {el, table, pushed} = mount({width: 200})
  el.listeners.pointerdown(event({clientX: 500}))
  assert.equal(el.attrs["data-dragging"], "")
  el.listeners.pointermove(event({clientX: 540}))
  assert.equal(table.props["--cw-priority"], "240px")
  assert.deepEqual(pushed, [], "nothing is sent mid-drag")
  el.listeners.pointerup(event())
  assert.deepEqual(pushed, [["col_width", {view: "table", col: "priority", width: 240}]])
  assert.equal("data-dragging" in el.attrs, false)
})

test("a press without a move sends nothing", () => {
  const {el, pushed} = mount()
  el.listeners.pointerdown(event({clientX: 500}))
  el.listeners.pointerup(event())
  assert.deepEqual(pushed, [])
})

test("a right or middle button press doesn't start a drag", () => {
  const {el, table, pushed} = mount()
  el.listeners.pointerdown(event({button: 2, clientX: 500}))
  el.listeners.pointermove(event({clientX: 600}))
  el.listeners.pointerup(event())
  assert.deepEqual(table.props, {})
  assert.deepEqual(pushed, [])
})

test("a double-click puts the column back to its own width", () => {
  const {el, table, pushed} = mount()
  table.props["--cw-priority"] = "300px"
  el.listeners.dblclick(event())
  assert.equal("--cw-priority" in table.props, false)
  assert.deepEqual(pushed, [["col_width", {view: "table", col: "priority", width: null}]])
})

test("the arrow keys move the edge a step; Enter resets", () => {
  const {el, pushed} = mount({width: 200})
  el.listeners.keydown(event({key: "ArrowRight"}))
  el.listeners.keydown(event({key: "ArrowLeft"}))
  el.listeners.keydown(event({key: "Enter"}))
  el.listeners.keydown(event({key: "a"}))
  assert.deepEqual(pushed.map(([, p]) => p.width), [200 + STEP, 200 - STEP, null])
})

test("a click on the edge never reaches the heading's sort button", () => {
  const {el} = mount()
  let stopped = false
  el.listeners.click({stopPropagation: () => { stopped = true }})
  assert.equal(stopped, true)
})

test("unmounting takes its listeners off", () => {
  const {hook, el} = mount()
  hook.destroyed()
  assert.deepEqual(Object.keys(el.listeners), [])
})
