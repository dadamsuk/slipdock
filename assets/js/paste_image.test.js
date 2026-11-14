// node --test assets/js
import {test} from "node:test"
import assert from "node:assert/strict"
import {PLACEHOLDER, imageFiles, insertAtCursor, pastedName, replacePlaceholder} from "./paste_image.js"

const P = PLACEHOLDER

test("only image files are taken from a paste or a drop", () => {
  const png = {name: "a.png", type: "image/png"}
  const jpg = {name: "b.jpg", type: "image/jpeg"}
  const pdf = {name: "c.pdf", type: "application/pdf"}
  const text = {name: "d.txt", type: "text/plain"}
  assert.deepEqual(imageFiles([png, pdf, jpg, text], false), [png, jpg])
  assert.deepEqual(imageFiles([pdf, text], false), [])
  assert.deepEqual(imageFiles([{name: "x", type: ""}], false), [])
})

test("nothing is taken when there are no files or the textarea is disabled", () => {
  const png = {name: "a.png", type: "image/png"}
  assert.deepEqual(imageFiles([png], true), [])
  assert.deepEqual(imageFiles(undefined, false), [])
  assert.deepEqual(imageFiles(null, false), [])
})

test("inserting into an empty box or at a line start adds no padding", () => {
  assert.deepEqual(insertAtCursor("", {start: 0, end: 0}, "X\n"), {value: "X\n", caret: 2})
  assert.deepEqual(insertAtCursor("ab\ncd", {start: 3, end: 3}, "X\n"), {value: "ab\nX\ncd", caret: 5})
})

test("inserting mid-line puts the text on a line of its own", () => {
  assert.deepEqual(insertAtCursor("abcd", {start: 2, end: 2}, "X\n"), {value: "ab\nX\ncd", caret: 5})
})

test("inserting replaces the selection", () => {
  assert.deepEqual(insertAtCursor("ab\nSEL\ncd", {start: 3, end: 6}, "X"), {value: "ab\nX\ncd", caret: 4})
})

test("with no caret the text goes at the end", () => {
  assert.deepEqual(insertAtCursor("ab", {}, "X\n"), {value: "ab\nX\n", caret: 5})
  assert.deepEqual(insertAtCursor("ab", {start: null, end: null}, "X\n"), {value: "ab\nX\n", caret: 5})
})

test("a start with no end inserts there and keeps the text after it", () => {
  assert.deepEqual(insertAtCursor("abcd", {start: 2}, "X"), {value: "ab\nXcd", caret: 4})
  assert.deepEqual(insertAtCursor("abcd", {start: 2, end: null}, "X"), {value: "ab\nXcd", caret: 4})
  assert.deepEqual(insertAtCursor("abcd", {start: 0}, "X"), {value: "Xabcd", caret: 1})
})

test("an uploaded image's Markdown takes the placeholder's place", () => {
  const value = `before\n${P}\nafter`
  const caret = value.length
  const md = "![a](/files/1)"
  const out = replacePlaceholder(value, caret, md)
  assert.equal(out.value, `before\n${md}\nafter`)
  assert.equal(out.caret, caret + md.length - P.length)
})

test("a failed upload removes the placeholder and its newline, and the caret moves with it", () => {
  const value = `before\n${P}\nafter`
  const caret = value.length
  const out = replacePlaceholder(value, caret, "")
  assert.equal(out.value, "before\nafter")
  assert.equal(out.caret, caret - P.length - 1)
  assert.equal(out.value.slice(out.caret - 5), "after")
})

test("a failed upload with no newline after the placeholder eats no other character", () => {
  const out = replacePlaceholder(`ab${P}cd`, 0, "")
  assert.equal(out.value, "abcd")
})

test("a caret before the placeholder stays where it is", () => {
  const value = `before\n${P}\nafter`
  assert.equal(replacePlaceholder(value, 3, "").caret, 3)
  assert.equal(replacePlaceholder(value, 7, "![a](/f)").caret, 7)
})

test("only the first placeholder is replaced", () => {
  const out = replacePlaceholder(`${P}\n${P}\n`, 0, "![a](/f)")
  assert.equal(out.value, `![a](/f)\n${P}\n`)
})

test("the Markdown is appended on a line of its own when the placeholder was deleted", () => {
  assert.deepEqual(replacePlaceholder("some text  \n\n", 2, "![a](/f)"), {
    value: "some text\n![a](/f)\n",
    caret: "some text\n![a](/f)\n".length,
  })
  assert.deepEqual(replacePlaceholder("  ", 0, "![a](/f)"), {value: "![a](/f)\n", caret: 9})
})

test("a failure after the placeholder was deleted changes nothing", () => {
  assert.deepEqual(replacePlaceholder("some text", 4, ""), {value: "some text", caret: 4})
})

test("a pasted clipboard image is renamed with a date and its type's extension", () => {
  const now = new Date("2026-11-14T09:05:07.123Z")
  assert.equal(pastedName({name: "image.png", type: "image/png"}, now), "pasted-2026-11-14T09-05-07.png")
  assert.equal(pastedName({name: "blob", type: "image/jpeg"}, now), "pasted-2026-11-14T09-05-07.jpg")
  assert.equal(pastedName({name: "", type: "image/gif"}, now), "pasted-2026-11-14T09-05-07.gif")
  assert.equal(pastedName({name: "", type: ""}, now), "pasted-2026-11-14T09-05-07.png")
})

test("a file with a name of its own keeps it", () => {
  assert.equal(pastedName({name: "diagram.png", type: "image/png"}), "diagram.png")
})
