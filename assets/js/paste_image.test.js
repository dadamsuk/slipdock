// node --test assets/js
import {test, beforeEach} from "node:test"
import assert from "node:assert/strict"
import {PLACEHOLDER, PasteImage, imageFiles, insertAtCursor, pastedName, replacePlaceholder} from "./paste_image.js"
import {fakeDom, mountHook, key} from "./caret_menu_fake_dom.js"

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

// PasteImage as built: the hook app.js registers, mounted on a wrapper with
// data-upload, a textarea inside, and LiveView's handleEvent and uploadTo
// standing in (#3129).
beforeEach(() => { fakeDom() })

const png = (name = "diagram.png") => new File(["x"], name, {type: "image/png"})

function mountPaste(value, caret = value.length) {
  const server = {}
  const uploads = []
  const extra = {
    handleEvent: (name, fn) => { server[name] = fn },
    uploadTo: (el, upload, files) => uploads.push({el, upload, files}),
  }
  const {h, ta, el} = mountHook(PasteImage, value, {dataset: {upload: "images"}, extra})
  ta.selectionStart = ta.selectionEnd = caret
  return {h, ta, el, server, uploads}
}

test("PasteImage: a pasted image leaves the placeholder on a line of its own and uploads the file", () => {
  const {ta, el, uploads} = mountPaste("abcd", 2)
  const e = key("v")
  const file = png()
  el.fire("paste", {...e, clipboardData: {files: [file]}})

  assert.equal(ta.value, `ab\n${P}\ncd`)
  assert.equal(ta.selectionStart, 3 + P.length + 1)
  assert.equal(ta.selectionEnd, ta.selectionStart)
  assert.deepEqual(ta.sent, ["input"])
  assert.equal(e.prevented, 1)
  assert.equal(e.stopped, 1)
  assert.equal(uploads.length, 1)
  assert.equal(uploads[0].el, el)
  assert.equal(uploads[0].upload, "images")
  assert.deepEqual(uploads[0].files, [file])
})

test("PasteImage: each image of several gets a placeholder line, so the text after starts a new line", () => {
  const {ta, el, uploads} = mountPaste("after", 0)
  const files = [png("a.png"), png("b.png")]
  el.fire("drop", {...key("drop"), dataTransfer: {files}})

  assert.equal(ta.value, `${P}\n${P}\nafter`)
  assert.equal(ta.selectionStart, 2 * (P.length + 1))
  assert.deepEqual(ta.sent, ["input", "input"])
  assert.deepEqual(uploads.map(u => u.files), [files])
})

test("PasteImage: a clipboard image is uploaded under a dated name, with its type", () => {
  const {el, uploads} = mountPaste("")
  el.fire("paste", {...key("v"), clipboardData: {files: [png("image.png")]}})

  const [sent] = uploads[0].files
  assert.match(sent.name, /^pasted-\d{4}-\d\d-\d\dT\d\d-\d\d-\d\d\.png$/)
  assert.equal(sent.type, "image/png")
})

test("PasteImage: text, another kind of file, or a disabled textarea is left to the browser", () => {
  const pdf = new File(["x"], "notes.pdf", {type: "application/pdf"})
  for (const data of [{files: []}, {files: [pdf]}, undefined]) {
    const {ta, el, uploads} = mountPaste("abcd", 2)
    const e = key("v")
    el.fire("paste", {...e, clipboardData: data})
    assert.equal(ta.value, "abcd")
    assert.deepEqual(ta.sent, [])
    assert.equal(e.prevented, 0)
    assert.equal(e.stopped, 0)
    assert.deepEqual(uploads, [])
  }

  const {ta, el, uploads} = mountPaste("abcd", 2)
  ta.disabled = true
  const e = key("v")
  el.fire("paste", {...e, clipboardData: {files: [png()]}})
  assert.equal(ta.value, "abcd")
  assert.equal(e.prevented, 0)
  assert.deepEqual(uploads, [])
})

test("PasteImage: the server's Markdown takes the placeholder's place, for this upload only", () => {
  const {ta, el, server} = mountPaste("abcd", 2)
  el.fire("paste", {...key("v"), clipboardData: {files: [png()]}})

  server.image_uploaded({upload: "other", markdown: "![a](/f/1)"})
  assert.equal(ta.value, `ab\n${P}\ncd`)

  server.image_uploaded({upload: "images", markdown: "![a](/f/1)"})
  assert.equal(ta.value, "ab\n![a](/f/1)\ncd")
  assert.equal(ta.selectionStart, "ab\n![a](/f/1)\n".length)
})

test("PasteImage: a failed upload takes the placeholder and its newline away, for this upload only", () => {
  const {ta, el, server} = mountPaste("abcd", 2)
  el.fire("paste", {...key("v"), clipboardData: {files: [png()]}})

  server.image_failed({upload: "other"})
  assert.equal(ta.value, `ab\n${P}\ncd`)

  server.image_failed({upload: "images"})
  assert.equal(ta.value, "ab\ncd")
  assert.equal(ta.selectionStart, 3)
})

test("PasteImage: dragging a file over is allowed to drop; dragging text is not touched", () => {
  const {el} = mountPaste("")
  const file = key("drag")
  el.fire("dragover", {...file, dataTransfer: {items: [{kind: "string"}, {kind: "file"}]}})
  assert.equal(file.prevented, 1)

  for (const dataTransfer of [{items: [{kind: "string"}]}, {}, undefined]) {
    const text = key("drag")
    el.fire("dragover", {...text, dataTransfer})
    assert.equal(text.prevented, 0)
  }
})
