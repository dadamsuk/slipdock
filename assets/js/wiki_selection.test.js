// node --test assets/js — "card from selection" on a wiki page (#3101). Text
// decrypted in this browser (an open Meld block) must never be sent to the
// server. No browser, so the nodes and ranges here are the little
// wiki_selection.js touches.
import {test} from "node:test"
import assert from "node:assert/strict"
import {selectedText, sendSelection, touchesPlaintext} from "./wiki_selection.js"

class El {
  constructor(tag, {cls = "", attrs = []} = {}) {
    this.nodeType = 1
    this.tagName = tag
    this.className = cls
    this.attrs = attrs
    this.children = []
    this.parentElement = null
  }
  add(...nodes) {
    nodes.forEach(n => { n.parentElement = this; this.children.push(n) })
    return this
  }
  matches(sel) {
    return sel.split(",").some(s => {
      s = s.trim()
      if (s.startsWith(".")) return this.className.split(" ").includes(s.slice(1))
      if (s.startsWith("[")) return this.attrs.includes(s.slice(1, -1))
      return false
    })
  }
  closest(sel) {
    for (let n = this; n; n = n.parentElement) if (n.matches(sel)) return n
    return null
  }
  contains(node) {
    for (let n = node; n; n = n.parentElement) if (n === this) return true
    return false
  }
  querySelector(sel) {
    for (const c of this.children) {
      if (c.nodeType !== 1) continue
      if (c.matches(sel)) return c
      const found = c.querySelector(sel)
      if (found) return found
    }
    return null
  }
}

const textNode = data => ({nodeType: 3, data, parentElement: null})

// A wiki page: a plain paragraph, an open Meld block holding its plaintext,
// another plain paragraph; and something outside the page altogether.
function page() {
  const before = textNode("Ship the release on Friday.")
  const secret = textNode("the vault code is 1234")
  const after = textNode("Then tell the team.")
  const plain = new El("span", {cls: "meld-plain"}).add(secret)
  const open = new El("span", {cls: "meld-open", attrs: ["data-meld-open"]}).add(plain, new El("button", {cls: "meld-lock"}))
  const p1 = new El("p").add(before)
  const p2 = new El("p").add(open)
  const p3 = new El("p").add(after)
  const el = new El("div", {attrs: ["phx-hook"]}).add(p1, p2, p3)
  const outsideText = textNode("A sidebar link elsewhere.")
  const outside = new El("nav").add(outsideText)
  const body = new El("body").add(el, outside)
  return {el, body, before, secret, after, plain, open, p1, p2, p3, outsideText, outside}
}

// A range from `start` to `end`. cloneContents gives the elements it wholly
// or partly covers below the common ancestor, as a browser's would.
function range(start, end, common, covered = []) {
  return {
    startContainer: start,
    endContainer: end,
    commonAncestorContainer: common,
    cloneContents: () => new El("#fragment").add(...covered.map(clone)),
  }
}

function clone(el) {
  const copy = new El(el.tagName, {cls: el.className, attrs: el.attrs})
  return copy.add(...el.children.filter(c => c.nodeType === 1).map(clone))
}

function selection(r, text, {isCollapsed = false} = {}) {
  return {isCollapsed, rangeCount: r ? 1 : 0, getRangeAt: () => r, toString: () => text}
}

function sent(el, sel) {
  const pushes = []
  const result = sendSelection(el, sel, (event, payload) => pushes.push([event, payload]))
  return {result, pushes}
}

function assertNotSent(el, sel) {
  assert.equal(selectedText(el, sel), null)
  const {result, pushes} = sent(el, sel)
  assert.equal(result, false)
  assert.deepEqual(pushes, [])
}

test("a clean selection inside the page is sent, trimmed", () => {
  const {el, before, p1} = page()
  const sel = selection(range(before, before, p1), "  Ship the release  ")
  assert.equal(selectedText(el, sel), "Ship the release")
  assert.deepEqual(sent(el, sel), {result: true, pushes: [["card_from_selection", {text: "Ship the release"}]]})
})

test("a clean selection across paragraphs is sent", () => {
  const {el, before, after, p1, p3} = page()
  const r = range(before, after, el, [p1, p3])
  assert.equal(touchesPlaintext(r), false)
  assert.deepEqual(sent(el, selection(r, "Friday. Then tell")).pushes, [["card_from_selection", {text: "Friday. Then tell"}]])
})

test("a selection wholly inside decrypted text is never sent", () => {
  const {el, secret, plain} = page()
  const r = range(secret, secret, plain)
  assert.equal(touchesPlaintext(r), true)
  assertNotSent(el, selection(r, "vault code"))
})

test("a selection that starts in decrypted text is never sent", () => {
  const {el, secret, after} = page()
  // cloneContents' copy of the open block is left out, so only the start
  // container's ancestors can catch it.
  const r = range(secret, after, el, [])
  assert.equal(touchesPlaintext(r), true)
  assertNotSent(el, selection(r, "code is 1234 Then tell"))
})

test("a selection that ends in decrypted text is never sent", () => {
  const {el, before, secret} = page()
  const r = range(before, secret, el, [])
  assert.equal(touchesPlaintext(r), true)
  assertNotSent(el, selection(r, "Friday. the vault"))
})

test("a selection that spans decrypted text, starting and ending outside it, is never sent", () => {
  const {el, before, after, p1, p2, p3} = page()
  const r = range(before, after, el, [p1, p2, p3])
  assert.equal(touchesPlaintext(r), true)
  assertNotSent(el, selection(r, "Friday. the vault code is 1234 Then"))
})

test("a spanned .meld-plain is caught without its [data-meld-open] wrapper", () => {
  const {el, before, after, plain} = page()
  const r = range(before, after, el, [plain])
  assert.equal(touchesPlaintext(r), true)
  assertNotSent(el, selection(r, "Friday. the vault code"))
})

test("a selection starting at an element node inside the open block is never sent", () => {
  const {el, open, after} = page()
  const r = range(open, after, el, [])
  assert.equal(touchesPlaintext(r), true)
  assertNotSent(el, selection(r, "the vault code is 1234 Then"))
})

test("a selection outside the page element is not sent", () => {
  const {el, outsideText, outside} = page()
  assertNotSent(el, selection(range(outsideText, outsideText, outside), "A sidebar link"))
})

test("a selection from the page out past it is not sent", () => {
  const {el, body, before, outsideText} = page()
  assertNotSent(el, selection(range(before, outsideText, body), "Ship the release A sidebar"))
})

test("a selection under 3 characters is not sent; 3 is", () => {
  const {el, before, p1} = page()
  const r = range(before, before, p1)
  assertNotSent(el, selection(r, "Sh"))
  assertNotSent(el, selection(r, "  S \n"))
  assert.equal(selectedText(el, selection(r, " Shi ")), "Shi")
})

test("no selection, a collapsed one or one with no range is not sent", () => {
  const {el, before, p1} = page()
  assertNotSent(el, null)
  assertNotSent(el, selection(range(before, before, p1), "", {isCollapsed: true}))
  assertNotSent(el, selection(null, "Ship the release"))
})
