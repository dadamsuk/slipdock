// node --test assets/js — theme.js, which runs as it loads, before the first
// paint (#2882): where storage is blocked, reading the `localStorage`
// property itself throws, and the theme must still be set and its listeners
// registered. <html>, matchMedia and the window are faked down to what is
// touched; each test loads a fresh copy of the module.
import {test} from "node:test"
import assert from "node:assert/strict"

let copies = 0

// `then` runs with the fakes still in place, for a listener to be fired.
async function load({localStorage, dark = true}, then = () => {}) {
  const attrs = {}
  const listeners = {}
  const html = {
    style: {setProperty() {}, removeProperty() {}, getPropertyValue: () => ""},
    getAttribute: k => (k in attrs ? attrs[k] : null),
    setAttribute: (k, v) => { attrs[k] = String(v) },
    removeAttribute: k => { delete attrs[k] },
    hasAttribute: k => k in attrs,
  }
  const saved = {
    document: globalThis.document, matchMedia: globalThis.matchMedia, window: globalThis.window,
    getComputedStyle: globalThis.getComputedStyle,
    localStorage: Object.getOwnPropertyDescriptor(globalThis, "localStorage"),
  }
  globalThis.document = {documentElement: html, querySelector: () => null}
  globalThis.matchMedia = () => ({matches: dark, addEventListener() {}})
  globalThis.getComputedStyle = () => ({getPropertyValue: () => ""})
  globalThis.window = {addEventListener: (type, fn) => { listeners[type] = fn }}
  Object.defineProperty(globalThis, "localStorage", {configurable: true, ...localStorage})
  try {
    await import(`./theme.js?copy=${++copies}`)
    then(listeners)
  } finally {
    for (const k of ["document", "matchMedia", "window", "getComputedStyle"]) globalThis[k] = saved[k]
    if (saved.localStorage) Object.defineProperty(globalThis, "localStorage", saved.localStorage)
    else delete globalThis.localStorage
  }
  return {attrs, listeners}
}

function fake(initial = {}) {
  const items = {...initial}
  return {
    items,
    getItem: k => (k in items ? items[k] : null),
    setItem: (k, v) => { items[k] = String(v) },
    removeItem: k => { delete items[k] },
  }
}

test("where reading localStorage throws, the system theme is set and the listeners registered", async () => {
  const {attrs, listeners} = await load({localStorage: {get() { throw new Error("SecurityError") }}})
  assert.equal(attrs["data-theme"], "dark")
  assert.equal(attrs["data-theme-source"], "system")
  assert.equal(typeof listeners.storage, "function")
  assert.equal(typeof listeners["phx:set-theme"], "function")
})

test("a theme kept in storage is put back, one chosen is kept, and system forgets it", async () => {
  const store = fake({"phx:theme": "light"})
  const {attrs} = await load({localStorage: {value: store}}, listeners => {
    assert.equal(store.items["phx:theme"], "light")
    listeners["phx:set-theme"]({target: {dataset: {phxTheme: "dark"}}})
    assert.equal(store.items["phx:theme"], "dark")
    listeners["phx:set-theme"]({target: {dataset: {phxTheme: "system"}}})
    assert.equal("phx:theme" in store.items, false)
  })
  assert.equal(attrs["data-theme"], "dark")
  assert.equal(attrs["data-theme-source"], "system")
})

test("where reading localStorage throws, choosing a theme still sets it", async () => {
  const {attrs} = await load({localStorage: {get() { throw new Error("SecurityError") }}, dark: false}, listeners => {
    assert.doesNotThrow(() => listeners["phx:set-theme"]({target: {dataset: {phxTheme: "dark"}}}))
  })
  assert.equal(attrs["data-theme"], "dark")
  assert.equal(attrs["data-theme-source"], "user")
})
