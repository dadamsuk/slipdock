// node --test assets/js — desktop toasts for waits and mentions (#2101),
// with Notification, localStorage and the window faked down to what is
// touched.
import {test} from "node:test"
import assert from "node:assert/strict"
import {
  DesktopNotify, DesktopNotifyToggle, KEY, enabled, maybeNotify, permission,
  setEnabled, shouldShow, show, showingCard, statusText, turnOn,
} from "./desktop_notify.js"

function storage(initial = {}) {
  const items = {...initial}
  return {
    items,
    getItem: k => (k in items ? items[k] : null),
    setItem: (k, v) => { items[k] = String(v) },
    removeItem: k => { delete items[k] },
  }
}

// A Notification class with a given permission, remembering what it made.
function fakeNotification(perm = "granted", answer = perm) {
  class N {
    constructor(title, opts) {
      this.title = title
      this.opts = opts
      this.closed = false
      N.made.push(this)
    }
    close() { this.closed = true }
  }
  N.permission = perm
  N.made = []
  N.asked = 0
  N.requestPermission = async () => { N.asked += 1; N.permission = answer; return answer }
  return N
}

function fakeWindow(pathname = "/boards/3", search = "") {
  return {
    focused: 0,
    went: [],
    focus() { this.focused += 1 },
    location: {pathname, search, assign(path) { this.went.push(path) }, went: []},
  }
}

const event = {
  id: "notify-abc", kind: "mention", user_id: 1, by_id: 2, card_id: 42, board_id: 3,
  path: "/boards/3/cards/42", title: "Ann mentioned you on “Pricing”", body: "@you look",
}

const on = () => storage({[KEY]: "on"})

test("off by default: nothing remembered means off, and no toast", () => {
  const store = storage()
  assert.equal(enabled(store), false)
  assert.equal(shouldShow(event, {userId: "1", store, N: fakeNotification()}), false)
})

test("toggle off shows nothing even with permission", () => {
  const store = on()
  setEnabled(false, store)
  assert.equal(store.items[KEY], undefined)
  const N = fakeNotification()
  assert.equal(maybeNotify(event, {userId: "1", store, N, win: fakeWindow(), focused: false}), null)
  assert.equal(N.made.length, 0)
})

test("no storage at all reads as off, and setting it is harmless", () => {
  assert.equal(enabled(null), false)
  setEnabled(true, null)
  const broken = {getItem() { throw new Error("denied") }, setItem() { throw new Error("denied") }}
  assert.equal(enabled(broken), false)
  setEnabled(true, broken)
})

test("on with permission granted: shows title, body and the event id as tag", () => {
  const N = fakeNotification()
  const toast = maybeNotify(event, {userId: "1", store: on(), N, win: fakeWindow(), focused: false})
  assert.ok(toast)
  assert.equal(N.made.length, 1)
  assert.equal(toast.title, event.title)
  assert.deepEqual(toast.opts, {body: "@you look", tag: "notify-abc"})
})

test("the same event in two tabs carries the same tag", () => {
  const N = fakeNotification()
  maybeNotify(event, {userId: "1", store: on(), N, win: fakeWindow(), focused: false})
  maybeNotify(event, {userId: "1", store: on(), N, win: fakeWindow("/work"), focused: false})
  assert.deepEqual(N.made.map(t => t.opts.tag), ["notify-abc", "notify-abc"])
})

test("clicking the toast focuses the tab, closes it and opens the card", () => {
  const N = fakeNotification()
  const win = fakeWindow()
  const toast = show(event, {N, win})
  toast.onclick()
  assert.equal(win.focused, 1)
  assert.equal(toast.closed, true)
  assert.deepEqual(win.location.went, ["/boards/3/cards/42"])
})

test("permission denied: no toast, and turning on stays off without asking", async () => {
  const N = fakeNotification("denied")
  assert.equal(shouldShow(event, {userId: "1", store: on(), N}), false)
  const store = storage()
  assert.equal(await turnOn({N, store}), "denied")
  assert.equal(N.asked, 0)
  assert.equal(enabled(store), false)
})

test("turning on asks for permission, and keeps it on only when given", async () => {
  const yes = fakeNotification("default", "granted")
  const store = storage()
  assert.equal(await turnOn({N: yes, store}), "granted")
  assert.equal(yes.asked, 1)
  assert.equal(enabled(store), true)

  const no = fakeNotification("default", "denied")
  const store2 = storage()
  assert.equal(await turnOn({N: no, store: store2}), "denied")
  assert.equal(enabled(store2), false)
})

test("unsupported: no Notification API reads as such, and can't be turned on", async () => {
  assert.equal(permission(null), "unsupported")
  const store = on()
  assert.equal(shouldShow(event, {userId: "1", store, N: null}), false)
  assert.equal(await turnOn({N: null, store}), "unsupported")
  assert.equal(enabled(store), false)
})

test("the reader's own doing never toasts", () => {
  const N = fakeNotification()
  assert.equal(shouldShow({...event, by_id: 1}, {userId: "1", store: on(), N}), false)
  assert.equal(shouldShow({...event, by_id: null}, {userId: "1", store: on(), N}), true)
})

test("a focused tab already showing the card stays quiet; a background one doesn't", () => {
  const N = fakeNotification()
  const loc = {pathname: "/boards/3/cards/42", search: ""}
  assert.equal(shouldShow(event, {userId: "1", store: on(), N, focused: true, loc}), false)
  assert.equal(shouldShow(event, {userId: "1", store: on(), N, focused: false, loc}), true)
  const elsewhere = {pathname: "/boards/3", search: ""}
  assert.equal(shouldShow(event, {userId: "1", store: on(), N, focused: true, loc: elsewhere}), true)
})

test("showingCard knows the card's path, a nested one and ?card=", () => {
  assert.equal(showingCard(event, {pathname: "/boards/3/cards/42"}), true)
  assert.equal(showingCard(event, {pathname: "/boards/9/cards/42"}), true)
  assert.equal(showingCard(event, {pathname: "/work", search: "?card=42"}), true)
  assert.equal(showingCard(event, {pathname: "/boards/3/cards/421"}), false)
  assert.equal(showingCard(event, null), false)
})

test("an event without an id is ignored", () => {
  assert.equal(shouldShow({...event, id: undefined}, {store: on(), N: fakeNotification()}), false)
})

test("statusText says denied and unsupported beside the toggle", () => {
  assert.match(statusText("denied", false), /blocked/)
  assert.match(statusText("unsupported", false), /can't show/)
  assert.equal(statusText("granted", true), "On in this browser.")
  assert.equal(statusText("granted", false), "Off in this browser.")
  assert.equal(statusText("default", false), "Off in this browser.")
})

test("the DesktopNotify hook shows what the server pushes, with the page's user", () => {
  const N = fakeNotification()
  const saved = {N: globalThis.Notification, ls: globalThis.localStorage, doc: globalThis.document}
  globalThis.Notification = N
  Object.defineProperty(globalThis, "localStorage", {value: on(), configurable: true})
  globalThis.document = {hasFocus: () => false}
  try {
    const handlers = {}
    const hook = {
      ...DesktopNotify,
      el: {dataset: {userId: "1"}},
      handleEvent(name, fn) { handlers[name] = fn },
    }
    hook.mounted()
    handlers["desktop-notify"](event)
    handlers["desktop-notify"]({...event, id: "notify-own", by_id: 1})
    assert.deepEqual(N.made.map(t => t.opts.tag), ["notify-abc"])
  } finally {
    globalThis.Notification = saved.N
    Object.defineProperty(globalThis, "localStorage", {value: saved.ls, configurable: true})
    globalThis.document = saved.doc
  }
})

test("the toggle hook draws the state and turns on through the permission prompt", async () => {
  const N = fakeNotification("default", "granted")
  const saved = {N: globalThis.Notification, ls: globalThis.localStorage}
  const store = storage()
  globalThis.Notification = N
  Object.defineProperty(globalThis, "localStorage", {value: store, configurable: true})
  try {
    let onChange
    const input = {checked: false, disabled: false, addEventListener: (_, fn) => { onChange = fn }}
    const status = {textContent: ""}
    const el = {dataset: {}, querySelector: sel => (sel.startsWith("input") ? input : status)}
    const hook = {...DesktopNotifyToggle, el}
    hook.mounted()
    assert.equal(input.checked, false)
    assert.equal(status.textContent, "Off in this browser.")

    input.checked = true
    await onChange()
    assert.equal(N.asked, 1)
    assert.equal(store.items[KEY], "on")
    assert.equal(input.checked, true)
    assert.equal(status.textContent, "On in this browser.")

    input.checked = false
    await onChange()
    assert.equal(enabled(store), false)
    assert.equal(input.checked, false)
  } finally {
    globalThis.Notification = saved.N
    Object.defineProperty(globalThis, "localStorage", {value: saved.ls, configurable: true})
  }
})

test("the toggle hook says denied, and disables itself where unsupported", () => {
  const saved = globalThis.Notification
  try {
    for (const [N, state, disabled] of [[fakeNotification("denied"), "denied", false], [undefined, "unsupported", true]]) {
      globalThis.Notification = N
      const input = {checked: true, disabled: false, addEventListener() {}}
      const status = {textContent: ""}
      const el = {dataset: {}, querySelector: sel => (sel.startsWith("input") ? input : status)}
      const hook = {...DesktopNotifyToggle, el}
      hook.mounted()
      assert.equal(el.dataset.state, state)
      assert.equal(input.checked, false)
      assert.equal(input.disabled, disabled)
      assert.equal(status.textContent, statusText(state, false))
    }
  } finally {
    globalThis.Notification = saved
  }
})
