// node --test assets/js — no browser, so the DOM here is the handful of
// methods confirm.js actually touches, and nothing more.
import {test} from "node:test"
import assert from "node:assert/strict"
import {confirmLabel, confirmTone, ask, proceed, installConfirm} from "./confirm.js"

function element({attrs = {}, text = "", connected = true, onClick} = {}) {
  const a = {...attrs}
  return {
    textContent: text,
    isConnected: connected,
    clicks: [],
    getAttribute: k => (k in a ? a[k] : null),
    setAttribute: (k, v) => { a[k] = v },
    removeAttribute: k => { delete a[k] },
    click() {
      this.clicks.push(a["data-confirm"] ?? null)
      if (onClick) onClick()
    },
    closest(sel) { return sel === "[data-confirm]" && "data-confirm" in a ? this : null },
  }
}

function classList() {
  const set = new Set(["btn", "btn-primary"])
  return {set, toggle: (c, on) => (on ? set.add(c) : set.delete(c))}
}

function dialog() {
  const listeners = {}
  const focused = []
  const parts = {
    "#confirm-dialog-message": {textContent: ""},
    "[data-confirm-ok]": {textContent: "OK", classList: classList(), focus: () => focused.push("ok")},
    "[data-confirm-cancel]": {focus: () => focused.push("cancel")},
  }
  return {
    open: false,
    returnValue: "stale",
    focused,
    parts,
    querySelector: sel => parts[sel],
    addEventListener: (type, fn) => { listeners[type] = fn },
    showModal() { this.open = true },
    // What the browser does when a method=dialog button is pressed, or Escape.
    close(value) {
      this.open = false
      if (value !== undefined) this.returnValue = value
      listeners.close()
    },
  }
}

function fakeWindow(dlg) {
  const handlers = []
  return {
    handlers,
    document: {getElementById: id => (id === "confirm-dialog" ? dlg : null)},
    addEventListener: (type, fn, capture) => handlers.push({type, fn, capture}),
  }
}

function clickEvent(target) {
  return {
    target,
    prevented: false,
    stopped: false,
    preventDefault() { this.prevented = true },
    stopImmediatePropagation() { this.stopped = true },
  }
}

const tick = () => new Promise(r => setImmediate(r))

test("the button's own short words become the confirm label", () => {
  assert.equal(confirmLabel(element({text: "\n   Delete\n "})), "Delete")
  assert.equal(confirmLabel(element({text: "Revoke  token"})), "Revoke token")
})

test("data-confirm-label wins over the element's text", () => {
  assert.equal(confirmLabel(element({attrs: {"data-confirm-label": "Publish"}, text: "Go"})), "Publish")
})

test("an icon-only or wordy element falls back to aria-label, title, then OK", () => {
  assert.equal(confirmLabel(element({attrs: {"aria-label": "Delete comment"}})), "Delete comment")
  assert.equal(confirmLabel(element({attrs: {title: "Remove"}})), "Remove")
  assert.equal(confirmLabel(element({text: "a".repeat(25)})), "OK")
  assert.equal(confirmLabel(element()), "OK")
})

test("irreversible actions are danger; archive and publish are not", () => {
  assert.equal(confirmTone("Delete this card permanently?", "OK"), "danger")
  assert.equal(confirmTone("Are you sure?", "Revoke"), "danger")
  assert.equal(confirmTone("Withdraw the public link?", "OK"), "danger")
  assert.equal(confirmTone("Archive “Inbox”? Nothing on it is lost.", "Archive"), "normal")
  assert.equal(confirmTone("Publish this page?", "Publish"), "normal")
  assert.equal(confirmTone(null, null), "normal")
  // "Deleted" or "Removal" mid-sentence is not the verb that starts the action.
  assert.equal(confirmTone("Put back what was deleted?", "Restore"), "normal")
})

test("ask fills in the dialog and resolves true only on the confirm button", async () => {
  const dlg = dialog()
  const answer = ask(dlg, "Delete tag “x”?", "Delete", "danger")

  assert.equal(dlg.open, true)
  assert.equal(dlg.returnValue, "", "a stale returnValue must not count as a yes")
  assert.equal(dlg.parts["#confirm-dialog-message"].textContent, "Delete tag “x”?")
  assert.equal(dlg.parts["[data-confirm-ok]"].textContent, "Delete")
  assert.ok(dlg.parts["[data-confirm-ok]"].classList.set.has("btn-error"))
  assert.ok(!dlg.parts["[data-confirm-ok]"].classList.set.has("btn-primary"))
  assert.deepEqual(dlg.focused, ["cancel"], "a destructive yes is never the default")

  dlg.close("confirm")
  assert.equal(await answer, true)
})

test("ask resolves false on Cancel, the backdrop or Escape", async () => {
  for (const value of ["cancel", undefined]) {
    const dlg = dialog()
    const answer = ask(dlg, "Publish this page?", "Publish", "normal")
    assert.deepEqual(dlg.focused, ["ok"])
    assert.ok(dlg.parts["[data-confirm-ok]"].classList.set.has("btn-primary"))
    dlg.close(value)
    assert.equal(await answer, false)
  }
})

test("proceed clicks once with data-confirm lifted, then puts it back", () => {
  const el = element({attrs: {"data-confirm": "Delete?"}})
  assert.equal(proceed(el), true)
  assert.deepEqual(el.clicks, [null])
  assert.equal(el.getAttribute("data-confirm"), "Delete?")
})

test("proceed puts data-confirm back even when the click throws", () => {
  const el = element({attrs: {"data-confirm": "Delete?"}, onClick: () => { throw new Error("boom") }})
  assert.throws(() => proceed(el), /boom/)
  assert.equal(el.getAttribute("data-confirm"), "Delete?")
})

test("proceed does nothing for an element no longer on the page", () => {
  const el = element({attrs: {"data-confirm": "Delete?"}, connected: false})
  assert.equal(proceed(el), false)
  assert.deepEqual(el.clicks, [])
})

test("installConfirm listens for clicks in the capture phase", () => {
  const win = fakeWindow(dialog())
  installConfirm(win)
  assert.equal(win.handlers.length, 1)
  assert.equal(win.handlers[0].type, "click")
  assert.equal(win.handlers[0].capture, true)
})

test("a confirmed click is stopped, asked, and replayed on yes", async () => {
  const dlg = dialog()
  const win = fakeWindow(dlg)
  installConfirm(win)
  const el = element({attrs: {"data-confirm": "Delete this card permanently?"}, text: "Delete"})
  const e = clickEvent(el)

  win.handlers[0].fn(e)
  assert.ok(e.prevented && e.stopped, "phoenix_html and LiveView must not see the first click")
  assert.equal(dlg.open, true)
  assert.deepEqual(el.clicks, [])

  dlg.close("confirm")
  await tick()
  assert.deepEqual(el.clicks, [null])
})

test("a declined click is never replayed", async () => {
  const dlg = dialog()
  const win = fakeWindow(dlg)
  installConfirm(win)
  const el = element({attrs: {"data-confirm": "Delete?"}})

  win.handlers[0].fn(clickEvent(el))
  dlg.close("cancel")
  await tick()
  assert.deepEqual(el.clicks, [])
})

test("a second click while the box is open is swallowed, not asked twice", () => {
  const dlg = dialog()
  const win = fakeWindow(dlg)
  installConfirm(win)
  const el = element({attrs: {"data-confirm": "Delete?"}})

  win.handlers[0].fn(clickEvent(el))
  dlg.parts["#confirm-dialog-message"].textContent = "marker"
  const again = clickEvent(el)
  win.handlers[0].fn(again)
  assert.ok(again.prevented && again.stopped)
  assert.equal(dlg.parts["#confirm-dialog-message"].textContent, "marker")
})

test("clicks on anything without data-confirm pass straight through", () => {
  const win = fakeWindow(dialog())
  installConfirm(win)
  const e = clickEvent(element())
  win.handlers[0].fn(e)
  assert.ok(!e.prevented && !e.stopped)

  const textNode = clickEvent({})
  win.handlers[0].fn(textNode)
  assert.ok(!textNode.prevented)
})

test("with no dialog on the page the browser's confirm is left to ask", () => {
  const win = fakeWindow(null)
  installConfirm(win)
  const e = clickEvent(element({attrs: {"data-confirm": "Delete?"}}))
  win.handlers[0].fn(e)
  assert.ok(!e.prevented && !e.stopped)
})

test("a browser without <dialog> support is left to window.confirm too", () => {
  const dlg = dialog()
  dlg.showModal = undefined
  const win = fakeWindow(dlg)
  installConfirm(win)
  const e = clickEvent(element({attrs: {"data-confirm": "Delete?"}}))
  win.handlers[0].fn(e)
  assert.ok(!e.prevented)
})
