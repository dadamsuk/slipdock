// node --test assets/js — the list at the caret that the @mention list and
// the [[page picker share (#2884). No browser, so the DOM here is the handful
// of things caret_menu.js touches.
import {test, beforeEach} from "node:test"
import assert from "node:assert/strict"
import {caretMenu, placeMenu, step, writeAt} from "./caret_menu.js"

function listeners() {
  const on = {}
  return {
    on,
    addEventListener: (type, fn) => { (on[type] ||= []).push(fn) },
    fire(type, e = {}) { (on[type] || []).forEach(fn => fn(e)) },
  }
}

function element(tag) {
  const classes = new Set()
  const l = listeners()
  return {
    tag, children: [], dataset: {}, style: {}, textContent: "", offsetHeight: 0, removed: false,
    get className() { return [...classes].join(" ") },
    set className(v) { classes.clear(); v.split(/\s+/).filter(Boolean).forEach(c => classes.add(c)) },
    classList: {add: c => classes.add(c), remove: c => classes.delete(c), contains: c => classes.has(c)},
    ...l,
    appendChild(c) { this.children.push(c); return c },
    append(...cs) { this.children.push(...cs) },
    replaceChildren(...cs) { this.children = cs },
    remove() { this.removed = true },
  }
}

let body, timers
beforeEach(() => {
  body = element("body")
  timers = []
  globalThis.document = {createElement: element, body}
  globalThis.window = {innerWidth: 1000, innerHeight: 800}
  globalThis.Event = class { constructor(type, o) { this.type = type; Object.assign(this, o) } }
  globalThis.setTimeout = fn => timers.push(fn)
})

function textarea(value, caret = value.length) {
  const ta = {
    value, selectionStart: caret, selectionEnd: caret, sent: [], focused: 0,
    ...listeners(),
    dispatchEvent(e) { this.sent.push(e.type); this.fire(e.type, e) },
    focus() { this.focused++ },
    getBoundingClientRect: () => ({left: 100, bottom: 200}),
  }
  return ta
}

// A word is "#" and what follows it; each row is a word to write.
const query = (text, caret) => {
  const m = text.slice(0, caret).match(/#(\w*)$/)
  return m ? {start: caret - m[0].length, text: m[1]} : null
}

function mount(value, opts = {}) {
  const ta = textarea(value)
  const el = {...listeners(), dataset: {}, querySelector: () => ta}
  const calls = []
  const hook = caretMenu({
    query,
    fetch: opts.fetch || ((h, q, o) => { calls.push({q, ...o}); return ["one", "two", "three"].filter(w => w.startsWith(q.text)) }),
    renderRow: (row, a) => { a.textContent = row },
    apply: opts.apply || ((text, start, caret, row) => ({value: text.slice(0, start) + "#" + row + " " + text.slice(caret), caret: start + row.length + 2})),
    width: 300,
    dataset: {testMenu: ""},
  })
  const h = Object.assign(Object.create(null), hook, {el})
  h.mounted()
  return {h, ta, el, calls, menu: body.children[0]}
}

const key = k => {
  const e = {key: k, prevented: 0, stopped: 0}
  e.preventDefault = () => e.prevented++
  e.stopPropagation = () => e.stopped++
  return e
}

const rows = menu => menu.children.map(li => li.children[0].textContent)
const active = menu => menu.children.findIndex(li => li.children[0].classList.contains("menu-active"))

test("the list goes on <body>, hidden, at its width and with its data", () => {
  const {menu} = mount("")
  assert.equal(body.children.length, 1)
  assert.equal(menu.classList.contains("hidden"), true)
  assert.equal(menu.style.width, "300px")
  assert.deepEqual(menu.dataset, {testMenu: ""})
})

test("no textarea, no list", () => {
  const h = Object.assign({}, caretMenu({query, fetch: () => [], renderRow() {}, apply() {}, width: 1}),
    {el: {querySelector: () => null}})
  h.mounted()
  assert.equal(body.children.length, 0)
  h.destroyed()
})

test("typing the word opens the list with the first row picked", () => {
  const {ta, menu} = mount("see #t")
  ta.fire("input")
  assert.deepEqual(rows(menu), ["two", "three"])
  assert.equal(active(menu), 0)
  assert.equal(menu.classList.contains("hidden"), false)
})

test("a click in the wrapper looks again too", () => {
  const {el, menu} = mount("see #o")
  el.fire("click")
  assert.deepEqual(rows(menu), ["one"])
})

test("arrows move round the ends; Enter takes, Escape closes", () => {
  const {ta, el, menu, h} = mount("see #")
  ta.fire("input")
  const up = key("ArrowUp")
  el.fire("keydown", up)
  assert.equal(active(menu), 2, "up from the first is the last")
  assert.equal(up.prevented, 1)
  assert.equal(up.stopped, 1, "the textarea's own bindings never hear it")
  el.fire("keydown", key("ArrowDown"))
  assert.equal(active(menu), 0, "down from the last is the first")
  el.fire("keydown", key("ArrowDown"))
  el.fire("keydown", key("Enter"))
  assert.equal(ta.value, "see #two ")
  assert.equal(ta.selectionStart, 9)
  assert.equal(h.matches.length, 0)

  ta.value = "#"; ta.selectionStart = 1
  ta.fire("input")
  const esc = key("Escape")
  el.fire("keydown", esc)
  assert.equal(menu.classList.contains("hidden"), true)
  assert.equal(esc.prevented, 1)
})

test("Tab takes as Enter does", () => {
  const {ta, el} = mount("#th")
  ta.fire("input")
  el.fire("keydown", key("Tab"))
  assert.equal(ta.value, "#three ")
})

test("other keys, and any key with the list shut, pass through", () => {
  const {ta, el} = mount("#t")
  const shut = key("Enter")
  el.fire("keydown", shut)
  assert.equal(shut.prevented, 0)
  ta.fire("input")
  const letter = key("a")
  el.fire("keydown", letter)
  assert.equal(letter.prevented, 0)
  assert.equal(letter.stopped, 0)
})

test("taking closes first, then writes, tells the form once and focuses", () => {
  const {ta, el, h, calls} = mount("see #o")
  ta.fire("input")
  assert.equal(calls.length, 1)
  el.fire("keydown", key("Enter"))
  assert.deepEqual(ta.sent, ["input"], "one input event")
  assert.equal(calls.length, 1, "the input it sent found no word, so asked nothing")
  assert.equal(h.open, null)
  assert.equal(ta.focused, 1)
})

test("a take that leaves a word at the caret opens the list again on it", () => {
  const apply = (text, start, caret, row) => ({value: "#" + row, caret: row.length + 1})
  const {ta, el, h, calls} = mount("#", {apply})
  ta.fire("input")
  el.fire("keydown", key("Enter"))
  assert.equal(ta.value, "#one")
  assert.equal(calls.length, 2)
  assert.deepEqual(h.matches, ["one"], "the refresh the write started is not undone by the take")
})

test("a mousedown on a row takes it, without the textarea losing focus", () => {
  const {ta, menu} = mount("#")
  ta.fire("input")
  const a = menu.children[1].children[0]
  let prevented = 0
  a.fire("mousedown", {preventDefault: () => prevented++})
  assert.equal(prevented, 1)
  assert.equal(ta.value, "#two ")
})

test("no word, or no rows, hides the list", () => {
  const {ta, menu, h} = mount("#z")
  ta.fire("input")
  assert.equal(menu.classList.contains("hidden"), true)
  assert.equal(h.open, 0, "no rows only hides: the word is still open")
  ta.value = "plain"; ta.selectionStart = 5
  ta.fire("input")
  assert.equal(h.open, null)
})

test("losing focus closes the list a moment later, so a click can land first", () => {
  const {ta, el, h} = mount("#o")
  ta.fire("input")
  el.fire("focusout")
  assert.equal(h.matches.length, 1)
  timers.forEach(fn => fn())
  assert.equal(h.matches.length, 0)
})

test("fresh only when the word starts somewhere new", () => {
  const {ta, calls} = mount("#")
  ta.fire("input")
  ta.value = "#o"; ta.selectionStart = 2
  ta.fire("input")
  ta.value = "#o #"; ta.selectionStart = 4
  ta.fire("input")
  assert.deepEqual(calls.map(c => c.fresh), [true, false, true])
})

test("an answer to an older keystroke, or after closing, is dropped", async () => {
  const pending = []
  const fetch = (h, q) => new Promise(resolve => pending.push(() => resolve([q.text || "all"])))
  const {ta, menu, h} = mount("#a", {fetch})
  ta.fire("input")
  ta.value = "#ab"; ta.selectionStart = 3
  ta.fire("input")
  pending[1]()
  await Promise.resolve()
  pending[0]()
  await Promise.resolve()
  assert.deepEqual(rows(menu), ["ab"], "the newer answer stands")

  ta.fire("input")
  h.close()
  pending[2]()
  await Promise.resolve()
  assert.equal(h.matches.length, 0)
})

test("destroyed takes the list off <body>", () => {
  const {h, menu} = mount("")
  h.destroyed()
  assert.equal(menu.removed, true)
})

test("the list sits under the caret, or the editor's caret when there is one", () => {
  const {ta, menu} = mount("#")
  ta.fire("input")
  assert.equal(menu.style.left, "100px")
  assert.equal(menu.style.top, "204px")
  ta.markdownEditor = {caretRect: () => ({left: 40, bottom: 60})}
  ta.fire("input")
  assert.equal(menu.style.left, "40px")
  assert.equal(menu.style.top, "64px")
})

test("placement holds the list on screen by its own size", () => {
  const view = {width: 1000, height: 800}
  assert.deepEqual(placeMenu({left: 10, bottom: 20}, {width: 300, height: 100}, view), {left: 10, top: 24})
  assert.deepEqual(placeMenu({left: 900, bottom: 20}, {width: 300, height: 100}, view), {left: 692, top: 24})
  assert.deepEqual(placeMenu({left: 10, bottom: 760}, {width: 300, height: 100}, view), {left: 10, top: 692})
  assert.deepEqual(placeMenu({left: 10, bottom: 10}, {width: 300, height: 900}, view), {left: 10, top: 0},
    "taller than the screen keeps its top on it")
  assert.deepEqual(placeMenu({left: 10, bottom: 10}, {width: 1200, height: 10}, view), {left: 0, top: 14})
})

test("step goes round the ends", () => {
  assert.equal(step(0, 3, "ArrowDown"), 1)
  assert.equal(step(2, 3, "ArrowDown"), 0)
  assert.equal(step(0, 3, "ArrowUp"), 2)
})

test("writeAt writes, puts the caret, and sends one bubbling input", () => {
  const ta = textarea("old")
  let bubbles
  ta.addEventListener("input", e => { bubbles = e.bubbles })
  writeAt(ta, "new text", 3)
  assert.equal(ta.value, "new text")
  assert.equal(ta.selectionStart, 3)
  assert.equal(ta.selectionEnd, 3)
  assert.deepEqual(ta.sent, ["input"])
  assert.equal(bubbles, true)
})
