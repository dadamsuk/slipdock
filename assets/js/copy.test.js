// node --test assets/js — copying with a "Copied" confirmation (#2887), the
// one function behind CopyText, CopyLink and the wiki tree's Copy link.
import {test, mock} from "node:test"
import assert from "node:assert/strict"
import {COPIED, COPIED_MS, confirmCopied, copyWithFeedback} from "./copy.js"

function button({label = "Copy", tip} = {}) {
  const labelEl = label === null ? null : {textContent: label}
  const dataset = tip === undefined ? {} : {tip}
  return {labelEl, dataset, querySelector: sel => (sel === "[data-label]" ? labelEl : null)}
}

function clipboard() {
  const written = []
  return {written, writeText: text => { written.push(text); return Promise.resolve() }}
}

function withTimers(fn) {
  mock.timers.enable({apis: ["setTimeout"]})
  return Promise.resolve().then(fn).finally(() => mock.timers.reset())
}

test("copies the text at once, says Copied, and puts the label back", () => withTimers(async () => {
  const el = button({label: "Copy prompt"})
  const board = clipboard()
  const done = copyWithFeedback(el, "slipdock auth", board)
  // Written within the click, not a tick later.
  assert.deepEqual(board.written, ["slipdock auth"])
  assert.equal(await done, true)
  assert.equal(el.labelEl.textContent, COPIED)
  mock.timers.tick(COPIED_MS - 1)
  assert.equal(el.labelEl.textContent, COPIED)
  mock.timers.tick(1)
  assert.equal(el.labelEl.textContent, "Copy prompt")
}))

test("a tooltip says Copied too, and is put back", () => withTimers(async () => {
  const el = button({label: null, tip: "Copy the page code"})
  assert.equal(await copyWithFeedback(el, "W-12", clipboard()), true)
  assert.equal(el.dataset.tip, COPIED)
  mock.timers.tick(COPIED_MS)
  assert.equal(el.dataset.tip, "Copy the page code")
}))

test("with no clipboard nothing is written and the words are left alone", async () => {
  const el = button()
  assert.equal(await copyWithFeedback(el, "x", null), false)
  assert.equal(el.labelEl.textContent, "Copy")
})

test("a refused write (rejected or thrown) claims no copy", async () => {
  const el = button()
  const rejects = {writeText: () => Promise.reject(new Error("denied"))}
  assert.equal(await copyWithFeedback(el, "x", rejects), false)
  const throws = {writeText: () => { throw new Error("denied") }}
  assert.equal(await copyWithFeedback(el, "x", throws), false)
  assert.equal(el.labelEl.textContent, "Copy")
})

test("a second copy while it says Copied doesn't leave it saying so", () => withTimers(() => {
  const el = button({tip: "Copy"})
  confirmCopied(el)
  mock.timers.tick(500)
  confirmCopied(el)
  mock.timers.tick(COPIED_MS)
  assert.equal(el.labelEl.textContent, "Copy")
  assert.equal(el.dataset.tip, "Copy")
}))

test("an element with nothing to relabel, or none at all, is copied without fuss", async () => {
  const board = clipboard()
  assert.equal(await copyWithFeedback(button({label: null}), "a", board), true)
  assert.equal(await copyWithFeedback(null, "b", board), true)
  assert.deepEqual(board.written, ["a", "b"])
})
