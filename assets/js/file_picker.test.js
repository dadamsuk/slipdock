// node --test assets/js — the file picker's plain-form hook (#1722), against
// a stand-in DOM of just what file_picker.js touches.
import {test} from "node:test"
import assert from "node:assert/strict"
import {readFileSync} from "node:fs"
import {FilePicker, fileSize, show} from "./file_picker.js"

const {cases} = JSON.parse(readFileSync(new URL("./file_size_cases.json", import.meta.url)))

function target() {
  const listeners = {}
  return {
    listeners,
    addEventListener: (t, f) => { (listeners[t] ||= []).push(f) },
    removeEventListener: (t, f) => { listeners[t] = (listeners[t] || []).filter(g => g !== f) },
    dispatchEvent(e) { (listeners[e.type] || []).forEach(f => f(e)); return true },
  }
}

function picker({files = []} = {}) {
  const name = {textContent: ""}
  const size = {textContent: ""}
  const remove = {closest: s => (s === "[data-role=file-remove]" ? remove : null)}
  const row = {hidden: true, querySelector: s => ({"[data-role=file-name]": name, "[data-role=file-size]": size}[s])}
  const input = {...target(), type: "file", value: files.length ? "C:\\fakepath\\x" : "", files}
  const a = {"data-empty": ""}
  const el = {
    ...target(),
    setAttribute: (k, v) => { a[k] = v },
    removeAttribute: k => { delete a[k] },
    has: k => k in a,
    querySelector: s => ({"input[type=file]": input, "[data-role=file]": row}[s] || null),
  }
  const hook = Object.create(FilePicker)
  hook.el = el
  return {hook, el, input, row, name, size, remove}
}

test("fileSize says what file_size/1 says, case for case", () => {
  assert.ok(cases.length > 15)
  for (const c of cases) assert.equal(fileSize(c.bytes), c.says, `${c.bytes}`)
})

test("fileSize writes bytes the way the server does", () => {
  assert.equal(fileSize(0), "0 B")
  assert.equal(fileSize(512), "512 B")
  assert.equal(fileSize(1024), "1 KB")
  assert.equal(fileSize(12_800), "12.5 KB")
  assert.equal(fileSize(3_355_443), "3.2 MB")
  assert.equal(fileSize(undefined), "")
  assert.equal(fileSize(-1), "")
  assert.equal(fileSize(NaN), "")
  assert.equal(fileSize(2 * 1024 ** 3), "2 GB")
})

test("show puts the name and size in the row, or hides it", () => {
  const p = picker()
  show(p.el, {name: "boards.json", size: 2048})
  assert.equal(p.row.hidden, false)
  assert.equal(p.name.textContent, "boards.json")
  assert.equal(p.size.textContent, "2 KB")
  assert.equal(p.el.has("data-empty"), false)
  show(p.el, undefined)
  assert.equal(p.row.hidden, true)
  assert.equal(p.el.has("data-empty"), true)
})

test("choosing a file shows it; the × empties the input and hides it", () => {
  const p = picker()
  p.hook.mounted()
  assert.equal(p.row.hidden, true)

  p.input.files = [{name: "logo.svg", size: 900}]
  p.input.value = "C:\\fakepath\\logo.svg"
  p.input.dispatchEvent({type: "change"})
  assert.equal(p.row.hidden, false)
  assert.equal(p.name.textContent, "logo.svg")
  assert.equal(p.size.textContent, "900 B")

  let prevented = false
  p.input.files = []
  p.el.dispatchEvent({type: "click", target: p.remove, preventDefault: () => (prevented = true)})
  assert.equal(prevented, true)
  assert.equal(p.input.value, "")
  assert.equal(p.row.hidden, true)
})

test("a click elsewhere is not a remove", () => {
  const p = picker({files: [{name: "a.txt", size: 1}]})
  p.hook.mounted()
  assert.equal(p.row.hidden, false)
  p.el.dispatchEvent({type: "click", target: {closest: () => null}, preventDefault() {}})
  assert.notEqual(p.input.value, "")
  assert.equal(p.row.hidden, false)
})

test("a picker with no input does nothing, and destroyed unhooks", () => {
  const p = picker()
  p.el.querySelector = () => null
  p.hook.mounted()
  p.hook.updated()
  p.hook.destroyed()

  const q = picker()
  q.hook.mounted()
  q.hook.destroyed()
  assert.equal(q.input.listeners.change.length, 0)
})
