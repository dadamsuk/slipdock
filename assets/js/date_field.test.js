// node --test assets/js — the date field's hook (#1720) against a stand-in
// DOM: just the elements and methods date_field.js touches.
// tools/e2e/date-field.sh drives the real thing in Chromium.
import {test} from "node:test"
import assert from "node:assert/strict"
import {DateField, canShowPicker, clear, formatShort, keyAction, openPicker, sync} from "./date_field.js"

function attrs() {
  const a = {}
  return {
    a,
    getAttribute: k => (k in a ? a[k] : null),
    setAttribute: (k, v) => { a[k] = String(v) },
    removeAttribute: k => { delete a[k] },
    hasAttribute: k => k in a,
  }
}

function target() {
  const listeners = {}
  return {
    listeners,
    addEventListener: (t, f) => { (listeners[t] ||= []).push(f) },
    removeEventListener: (t, f) => { listeners[t] = (listeners[t] || []).filter(g => g !== f) },
    dispatchEvent(e) { (listeners[e.type] || []).forEach(f => f(e)); return true },
  }
}

function field({value = "", picker = true, throws = false, disabled = false, placeholder} = {}) {
  const events = []
  const input = {
    ...target(),
    type: "date",
    value,
    disabled,
    readOnly: false,
    opened: 0,
    focused: 0,
    focus() { this.focused++ },
  }
  if (picker) input.showPicker = function () { if (throws) throw new Error("NotAllowedError"); this.opened++ }
  const origDispatch = input.dispatchEvent
  input.dispatchEvent = e => { events.push(e.type); return origDispatch.call(input, e) }

  const text = {textContent: ""}
  const clearBtn = {hidden: false, closest: s => (s === "[data-role=date-clear]" ? clearBtn : null)}
  const display = {...target(), focused: 0, focus() { this.focused++ }, closest: () => null}
  const el = {
    ...attrs(),
    ...target(),
    dataset: placeholder ? {placeholder} : {},
    querySelector(sel) {
      return {
        "input[type=date]": input,
        "[data-role=date-text]": text,
        "[data-role=date-clear]": clearBtn,
        "[data-role=date-display]": display,
      }[sel] || null
    },
  }
  const hook = Object.create(DateField)
  hook.el = el
  return {hook, el, input, text, clearBtn, display, events}
}

const key = (k, extra = {}) => ({key: k, prevented: false, preventDefault() { this.prevented = true }, ...extra})
const click = (t = {closest: () => null}) => ({target: t, prevented: false, preventDefault() { this.prevented = true }})

test("formatShort writes the server's short date", () => {
  const today = new Date(2026, 10, 18)
  assert.equal(formatShort("2026-11-18", today), "18 Nov")
  assert.equal(formatShort("2026-01-03", today), "3 Jan")
  assert.equal(formatShort("2025-12-24", today), "24 Dec 2025")
  assert.equal(formatShort("", today), null)
  assert.equal(formatShort(null, today), null)
  assert.equal(formatShort("2026-13-01", today), null)
  assert.equal(formatShort("18/11/2026", today), null)
})

test("keyAction: Enter, Space and Alt+Down open; a digit types", () => {
  assert.equal(keyAction(key("Enter")), "open")
  assert.equal(keyAction(key(" ")), "open")
  assert.equal(keyAction(key("ArrowDown", {altKey: true})), "open")
  assert.equal(keyAction(key("ArrowDown")), null)
  assert.equal(keyAction(key("1")), "type")
  assert.equal(keyAction(key("1", {ctrlKey: true})), null)
  assert.equal(keyAction(key("Tab")), null)
})

test("openPicker uses showPicker when there is one, and says when it can't", () => {
  const {input} = field()
  assert.equal(canShowPicker(input), true)
  assert.equal(openPicker(input), true)
  assert.equal(input.opened, 1)

  assert.equal(openPicker(field({picker: false}).input), false)
  assert.equal(openPicker(field({throws: true}).input), false)
  const off = field({disabled: true}).input
  assert.equal(openPicker(off), false)
  assert.equal(off.opened, 0)
})

test("with showPicker: a click on the display opens the picker", () => {
  const {hook, el, input, display} = field({value: "2026-11-18"})
  hook.mounted()
  assert.equal(el.hasAttribute("data-native"), false)
  const e = click()
  display.dispatchEvent({type: "click", ...e})
  assert.equal(input.opened, 1)
})

test("with showPicker: Enter and Space on the display open it", () => {
  const {hook, input, display} = field()
  hook.mounted()
  for (const k of ["Enter", " "]) {
    const e = key(k)
    display.dispatchEvent({type: "keydown", ...e, preventDefault: () => (e.prevented = true)})
    assert.equal(e.prevented, true, k)
  }
  assert.equal(input.opened, 2)
})

test("a digit hands the keys to the native input", () => {
  const {hook, el, input, display} = field()
  hook.mounted()
  display.dispatchEvent({type: "keydown", ...key("2")})
  assert.equal(el.hasAttribute("data-typing"), true)
  assert.equal(input.focused, 1)
  assert.equal(input.opened, 0)
  input.dispatchEvent({type: "blur"})
  assert.equal(el.hasAttribute("data-typing"), false)
})

test("a picker that refuses (throws) falls back to the native input", () => {
  const {hook, el, input, display} = field({throws: true})
  hook.mounted()
  display.dispatchEvent({type: "click", ...click()})
  assert.equal(el.hasAttribute("data-typing"), true)
  assert.equal(input.focused, 1)
})

test("without showPicker the native input is shown and nothing is wired", () => {
  const {hook, el, display} = field({picker: false})
  hook.mounted()
  assert.equal(el.hasAttribute("data-native"), true)
  assert.equal(display.listeners.click, undefined)
  hook.destroyed()
})

test("sync shows the date or the placeholder, and the clear button only with a date", () => {
  const today = new Date(2026, 10, 18)
  const f = field({value: "2026-11-18"})
  sync(f.el, today)
  assert.equal(f.text.textContent, "18 Nov")
  assert.equal(f.el.hasAttribute("data-empty"), false)
  assert.equal(f.clearBtn.hidden, false)

  f.input.value = ""
  sync(f.el, today)
  assert.equal(f.text.textContent, "Add date")
  assert.equal(f.el.hasAttribute("data-empty"), true)
  assert.equal(f.clearBtn.hidden, true)

  const g = field({placeholder: "No end"})
  sync(g.el, today)
  assert.equal(g.text.textContent, "No end")
})

test("a pick updates the words", () => {
  const {hook, input, text} = field()
  hook.mounted()
  assert.equal(text.textContent, "Add date")
  input.value = `${new Date().getFullYear()}-03-04`
  input.dispatchEvent({type: "change"})
  assert.equal(text.textContent, "4 Mar")
})

test("clear empties the input and fires input and change, once", () => {
  const {input, events} = field({value: "2026-11-18"})
  assert.equal(clear(input), true)
  assert.equal(input.value, "")
  assert.deepEqual(events, ["input", "change"])
  assert.equal(clear(input), false)
  assert.deepEqual(events, ["input", "change"])
})

test("the clear button clears, updates the words and keeps focus on the field", () => {
  const {hook, el, input, text, clearBtn, display, events} = field({value: "2026-11-18"})
  hook.mounted()
  el.dispatchEvent({type: "click", ...click(clearBtn)})
  assert.equal(input.value, "")
  assert.deepEqual(events, ["input", "change"])
  assert.equal(text.textContent, "Add date")
  assert.equal(display.focused, 1)

  // A click elsewhere in the wrapper is not a clear.
  input.value = "2026-11-18"
  el.dispatchEvent({type: "click", ...click()})
  assert.equal(input.value, "2026-11-18")
})

test("updated() follows a value the server put back", () => {
  const {hook, input, text} = field({value: "2026-11-18"})
  hook.mounted()
  input.value = ""
  hook.updated()
  assert.equal(text.textContent, "Add date")
})
