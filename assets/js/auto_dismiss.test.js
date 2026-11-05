// node --test assets/js — the self-closing toast (#1847) runs its own
// phx-click instead of clicking, so an open modal never sees a click outside.
// tools/e2e/toast-modal.sh checks it in a browser.
import {test, mock} from "node:test"
import assert from "node:assert/strict"
import {AutoDismiss, DISMISS_AFTER, dismiss} from "./auto_dismiss.js"

const CLEAR = '[["push",{"event":"lv:clear-flash","value":{"key":"info"}}]]'

function toast(phxClick = CLEAR) {
  return {
    clicks: 0,
    getAttribute: name => (name === "phx-click" ? phxClick : null),
    click() { this.clicks++ },
  }
}

function hook(el) {
  const ran = []
  return {ran, el, js: () => ({exec: js => ran.push(js)}), ...AutoDismiss}
}

test("dismiss runs the toast's own phx-click on the toast", () => {
  const el = toast()
  const ran = []
  dismiss(el, js => ran.push(js))
  assert.deepEqual(ran, [CLEAR])
  assert.equal(el.clicks, 0)
})

test("dismiss leaves a toast with no phx-click alone", () => {
  const ran = []
  dismiss(toast(null), (...args) => ran.push(args))
  assert.deepEqual(ran, [])
})

test("the hook dismisses after DISMISS_AFTER, never by a click", () => {
  mock.timers.enable({apis: ["setTimeout"]})
  try {
    const el = toast()
    const h = hook(el)
    h.mounted()

    mock.timers.tick(DISMISS_AFTER - 1)
    assert.deepEqual(h.ran, [])

    mock.timers.tick(1)
    assert.deepEqual(h.ran, [CLEAR])
    assert.equal(el.clicks, 0, "a real click would close any open modal")
  } finally {
    mock.timers.reset()
  }
})

test("a toast removed before its time is never dismissed", () => {
  mock.timers.enable({apis: ["setTimeout"]})
  try {
    const h = hook(toast())
    h.mounted()
    h.destroyed()
    mock.timers.tick(DISMISS_AFTER * 2)
    assert.deepEqual(h.ran, [])
  } finally {
    mock.timers.reset()
  }
})

test("closes after four and a half seconds", () => {
  assert.equal(DISMISS_AFTER, 4500)
})
