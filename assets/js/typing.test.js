// Run with: node --test assets/js/typing.test.js
import {test} from "node:test"
import assert from "node:assert/strict"
import {typing} from "./typing.js"

// An element as far as typing() looks at one: a tag, and the selectors it or
// an ancestor answers to.
const el = (tagName, {editable = false, within = []} = {}) => ({
  tagName,
  isContentEditable: editable,
  closest: selector => (within.includes(selector) ? {} : null),
})

test("a field, a select and anything contentEditable are typed into", () => {
  for (const tag of ["INPUT", "TEXTAREA", "SELECT", "input", "textarea", "select"]) {
    assert.equal(typing(el(tag)), true, tag)
  }
  assert.equal(typing(el("DIV", {editable: true})), true)
})

test("the page itself, a button and a link are not", () => {
  for (const tag of ["BODY", "BUTTON", "A", "DIV"]) assert.equal(typing(el(tag)), false, tag)
})

test("a widget that keeps its own keys counts, and so does anything inside it", () => {
  assert.equal(typing(el("DIV", {within: ["[data-own-keys]"]})), true)
  assert.equal(typing(el("A", {within: ["[data-own-keys]"]})), true)
  assert.equal(typing(el("DIV", {within: ["[data-other]"]})), false)
})

test("nothing focused is not typing, nor is a target that is no element", () => {
  assert.equal(typing(null), false)
  // The document and the window are key targets too: no tag, no closest.
  assert.equal(typing({}), false)
  assert.equal(typing({tagName: "DIV"}), false)
  // contentEditable has to be true, not merely set.
  assert.equal(typing({tagName: "DIV", isContentEditable: "inherit"}), false)
})

test("with no argument it asks about whatever holds the focus", t => {
  t.after(() => delete globalThis.document)
  globalThis.document = {activeElement: el("TEXTAREA")}
  assert.equal(typing(), true)
  globalThis.document = {activeElement: el("BODY")}
  assert.equal(typing(), false)
  globalThis.document = {activeElement: el("DIV", {within: ["[data-own-keys]"]})}
  assert.equal(typing(), true)
  globalThis.document = {activeElement: null}
  assert.equal(typing(), false)
})
