// node --test assets/js — the dialog here is the few things the hook touches.
import {test} from "node:test"
import assert from "node:assert/strict"
import {ModalDialog} from "./modal_dialog.js"

function dialog({showModal = true, closeEvent = "close_dialog"} = {}) {
  const listeners = {}
  const el = {
    open: false,
    isConnected: true,
    shown: 0,
    dataset: closeEvent ? {closeEvent} : {},
    addEventListener: (type, fn) => { listeners[type] = fn },
    removeEventListener: type => { delete listeners[type] },
    fire: (type, e = {}) => listeners[type] && listeners[type](e),
    listeners,
  }
  if (showModal) el.showModal = function () { this.open = true; this.shown++ }
  return el
}

function mount(el) {
  const pushed = []
  const hook = Object.create(ModalDialog)
  hook.el = el
  hook.pushEventTo = (target, event, payload) => pushed.push({target, event, payload})
  hook.mounted()
  return {hook, pushed}
}

test("mounting opens it as a modal, once", () => {
  const el = dialog()
  const {hook} = mount(el)
  assert.equal(el.open, true)
  hook.updated()
  assert.equal(el.shown, 1)
})

test("a patch that closed it opens it again", () => {
  const el = dialog()
  const {hook} = mount(el)
  el.open = false
  hook.updated()
  assert.equal(el.open, true)
  assert.equal(el.shown, 2)
})

test("closing it natively tells the server, with the dialog as the target", () => {
  const el = dialog()
  const {pushed} = mount(el)
  el.fire("close")
  assert.deepEqual(pushed, [{target: el, event: "close_dialog", payload: {}}])
})

test("a dialog the server already removed tells it nothing", () => {
  const el = dialog()
  const {pushed} = mount(el)
  el.isConnected = false
  el.fire("close")
  assert.deepEqual(pushed, [])
})

test("with no close event named, closing pushes nothing", () => {
  const el = dialog({closeEvent: null})
  const {pushed} = mount(el)
  el.fire("close")
  assert.deepEqual(pushed, [])
})

test("Escape stops at the dialog; other keys go on", () => {
  const el = dialog()
  mount(el)
  let stopped = 0
  el.fire("keydown", {key: "Escape", stopPropagation: () => stopped++})
  el.fire("keydown", {key: "a", stopPropagation: () => stopped++})
  assert.equal(stopped, 1)
})

test("a browser without <dialog> is left alone", () => {
  const el = dialog({showModal: false})
  mount(el)
  assert.equal(el.open, false)
})

test("destroyed takes its listeners away", () => {
  const el = dialog()
  const {hook} = mount(el)
  hook.destroyed()
  assert.deepEqual(Object.keys(el.listeners), [])
})
