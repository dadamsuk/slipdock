// node --test assets/js — no browser, so the DOM here is the handful of
// methods card_drop.js actually touches, and nothing more.
import {test} from "node:test"
import assert from "node:assert/strict"
import {columnDrop, dropZones, pointOf, zoneAt} from "./card_drop.js"

const box = (left, right, top, bottom) => ({left, right, top, bottom})

// Two lists side by side on a board 0..600 tall; the cards in each fill
// 60..200, under a header and over an "Add card" footer.
function board() {
  const area = {getBoundingClientRect: () => box(0, 1000, 0, 600)}
  const make = (id, left) => {
    const column = {
      getBoundingClientRect: () => box(left, left + 280, 10, 260),
      parentElement: {closest: sel => (sel === "[data-drop-area]" ? area : null)},
    }
    return {
      id,
      column,
      dataset: {columnDrop: ".kanban-column", id},
      closest: sel => (sel === ".kanban-column" ? column : null),
      getBoundingClientRect: () => box(left, left + 280, 60, 200),
    }
  }
  const a = make("1", 0)
  const b = make("2", 300)
  const doc = {
    querySelectorAll(sel) {
      assert.equal(sel, '[data-column-drop][data-group="cards"]')
      return [a, b]
    },
  }
  return {doc, a, b}
}

test("dropZones spans each column's width and the board's height", () => {
  const {doc, a, b} = board()
  const zones = dropZones(doc, "cards")
  assert.deepEqual(zones.map(z => z.list), [a, b])
  assert.deepEqual(zones[1].rect, box(300, 580, 0, 600))
  assert.deepEqual(zones[1].listRect, box(300, 580, 60, 200))
  assert.equal(zones[1].column, b.column)
})

test("dropZones falls back to the column's own box without a drop area", () => {
  const {doc, a} = board()
  a.column.parentElement = null
  assert.deepEqual(dropZones(doc, "cards")[0].rect, box(0, 280, 10, 260))
})

test("zoneAt leaves a pointer over the cards themselves to Sortable", () => {
  const zones = dropZones(board().doc, "cards")
  assert.equal(zoneAt(zones, 400, 100), null)
})

test("zoneAt finds the column under its header, footer and the board below it", () => {
  const {doc, b} = board()
  const zones = dropZones(doc, "cards")
  for (const y of [20, 240, 550]) assert.equal(zoneAt(zones, 400, y).list, b)
})

test("zoneAt finds nothing between columns, off the board, or with no pointer", () => {
  const zones = dropZones(board().doc, "cards")
  assert.equal(zoneAt(zones, 290, 300), null)
  assert.equal(zoneAt(zones, 400, 700), null)
  assert.equal(zoneAt(zones, null, null), null)
})

test("columnDrop sends a card let go under another column to that list", () => {
  const {doc, a, b} = board()
  const zones = dropZones(doc, "cards")
  assert.deepEqual(columnDrop({zones, x: 400, y: 550, from: a, to: a}), {to: b})
  // Sortable may have passed it through a list on the way: the column wins.
  assert.deepEqual(columnDrop({zones, x: 400, y: 20, from: a, to: a}), {to: b})
})

test("columnDrop keeps a card let go under its own column where it was", () => {
  const {doc, a, b} = board()
  const zones = dropZones(doc, "cards")
  assert.equal(columnDrop({zones, x: 100, y: 550, from: a, to: a}), null)
  assert.deepEqual(columnDrop({zones, x: 100, y: 550, from: a, to: b}), {cancel: true})
})

test("columnDrop trusts Sortable over a list, and anywhere outside the columns", () => {
  const {doc, a, b} = board()
  const zones = dropZones(doc, "cards")
  assert.equal(columnDrop({zones, x: 400, y: 100, from: a, to: b}), null)
  assert.equal(columnDrop({zones, x: 290, y: 300, from: a, to: b}), null)
})

test("pointOf reads a mouse, a touch and a lifted touch", () => {
  assert.deepEqual(pointOf({clientX: 1, clientY: 2}), {x: 1, y: 2})
  assert.deepEqual(pointOf({touches: [{clientX: 3, clientY: 4}]}), {x: 3, y: 4})
  assert.deepEqual(pointOf({touches: [], changedTouches: [{clientX: 5, clientY: 6}]}), {x: 5, y: 6})
})
