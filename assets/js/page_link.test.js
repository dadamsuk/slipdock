// node --test assets/js
import {test} from "node:test"
import assert from "node:assert/strict"
import {linkQuery, applyLink} from "./page_link.js"

const at = text => linkQuery(text, text.length)

test("[[ opens the picker with nothing typed yet", () => {
  assert.deepEqual(at("See [["), {start: 4, text: ""})
  assert.deepEqual(at("[["), {start: 0, text: ""})
})

test("what follows the brackets is the query: a title, a folder, a code", () => {
  assert.deepEqual(at("See [[Retry pol"), {start: 4, text: "Retry pol"})
  assert.deepEqual(at("x [[Design/Bil"), {start: 2, text: "Design/Bil"}, "folder, then title")
  assert.deepEqual(at("x [[W-19"), {start: 2, text: "W-19"})
  assert.deepEqual(at("an embed ![[Dia"), {start: 10, text: "Dia"})
})

test("a closed link, a new line, a label or an anchor closes it", () => {
  assert.equal(at("See [[Retry policy]] and"), null)
  assert.equal(at("See [[Retry\npolicy"), null)
  assert.equal(at("See [[Retry policy|how"), null)
  assert.equal(at("See [[Retry policy#Back"), null)
  assert.equal(at("one [ bracket"), null)
  assert.equal(at("[[" + "x".repeat(81)), null)
})

test("the caret, not the end of the text, is where the query ends", () => {
  const text = "See [[Ret and more"
  assert.deepEqual(linkQuery(text, 9), {start: 4, text: "Ret"})
  assert.equal(linkQuery(text, 2), null)
})

test("taking a page writes the link over [[word, caret after it", () => {
  assert.deepEqual(applyLink("See [[ret now", 4, 9, "[[Retry policy]]"),
    {value: "See [[Retry policy]] now", caret: 20})
})

test("brackets the editor closed already are taken in, not doubled", () => {
  assert.deepEqual(applyLink("See [[ret]] now", 4, 9, "[[W-31]]"), {value: "See [[W-31]] now", caret: 12})
  assert.deepEqual(applyLink("See [[ret] now", 4, 9, "[[W-31]]"), {value: "See [[W-31]] now", caret: 12})
})
