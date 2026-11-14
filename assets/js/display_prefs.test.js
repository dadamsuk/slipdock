// node --test assets/js — the board's remembered Display options (#1879),
// with localStorage faked down to what is touched.
import {test} from "node:test"
import assert from "node:assert/strict"
import {DisplayPrefs, PREFIX, handlePrefs, recall, remember} from "./display_prefs.js"

function storage(initial = {}) {
  const items = {...initial}
  return {
    items,
    getItem: k => (k in items ? items[k] : null),
    setItem: (k, v) => { items[k] = String(v) },
  }
}

const brokenStorage = {
  getItem() { throw new Error("denied") },
  setItem() { throw new Error("denied") },
}

test("a visit that may not restore remembers what is in use", () => {
  const store = storage({[PREFIX + "display:3:board"]: JSON.stringify({density: "compact"})})
  const back = handlePrefs({key: "display:3:board", query: {width: "wide"}, restore: false}, store)
  assert.equal(back, null)
  assert.deepEqual(JSON.parse(store.items[PREFIX + "display:3:board"]), {width: "wide"})
})

test("a restoring visit sends back what is remembered and leaves it alone", () => {
  const saved = {density: "compact", show_compact: "tags,id"}
  const store = storage({[PREFIX + "display:3:board"]: JSON.stringify(saved)})
  const back = handlePrefs({key: "display:3:board", query: {}, restore: true}, store)
  assert.deepEqual(back, saved)
  assert.deepEqual(JSON.parse(store.items[PREFIX + "display:3:board"]), saved)
})

test("a restoring visit with nothing remembered remembers the defaults", () => {
  const store = storage()
  assert.equal(handlePrefs({key: "display:3:table", query: {}, restore: true}, store), null)
  assert.equal(store.items[PREFIX + "display:3:table"], "{}")
})

test("a remembered reset to the defaults restores nothing", () => {
  const store = storage({[PREFIX + "display:3:board"]: "{}"})
  assert.equal(handlePrefs({key: "display:3:board", query: {}, restore: true}, store), null)
})

test("each board and mode keeps its own", () => {
  const store = storage()
  remember("display:3:board", {width: "wide"}, store)
  remember("display:4:board", {width: "narrow"}, store)
  assert.deepEqual(recall("display:3:board", store), {width: "wide"})
  assert.deepEqual(recall("display:4:board", store), {width: "narrow"})
  assert.equal(recall("display:3:table", store), null)
})

test("recall ignores junk: bad JSON, arrays, non-string values", () => {
  const store = storage({
    [PREFIX + "a"]: "{not json",
    [PREFIX + "b"]: "[1,2]",
    [PREFIX + "c"]: JSON.stringify({density: "compact", width: 3, show: null}),
    [PREFIX + "d"]: "null",
  })
  assert.equal(recall("a", store), null)
  assert.equal(recall("b", store), null)
  assert.deepEqual(recall("c", store), {density: "compact"})
  assert.equal(recall("d", store), null)
})

test("a storage that refuses everything neither throws nor restores", () => {
  assert.equal(recall("display:3:board", brokenStorage), null)
  assert.doesNotThrow(() => remember("display:3:board", {width: "wide"}, brokenStorage))
  assert.equal(handlePrefs({key: "display:3:board", query: {}, restore: true}, brokenStorage), null)
})

test("the hook pushes display_restore only when something is remembered", () => {
  const saved = {density: "compact"}
  const original = globalThis.localStorage
  globalThis.localStorage = storage({[PREFIX + "display:3:board"]: JSON.stringify(saved)})
  try {
    const pushed = []
    const handlers = {}
    const hook = {
      handleEvent: (name, fn) => { handlers[name] = fn },
      pushEvent: (name, payload) => pushed.push([name, payload]),
    }
    DisplayPrefs.mounted.call(hook)
    handlers["display-prefs"]({key: "display:3:board", query: {}, restore: true})
    handlers["display-prefs"]({key: "display:3:board", query: {width: "wide"}, restore: false})
    assert.deepEqual(pushed, [["display_restore", {query: saved}]])
    assert.deepEqual(recall("display:3:board"), {width: "wide"})
  } finally {
    globalThis.localStorage = original
  }
})

// Where storage is blocked, reading the `localStorage` property itself throws
// (#2882): runs `fn` with such a getter in place.
function whileStorageBlocked(fn) {
  const before = Object.getOwnPropertyDescriptor(globalThis, "localStorage")
  Object.defineProperty(globalThis, "localStorage", {configurable: true, get() { throw new Error("SecurityError") }})
  try { return fn() } finally {
    if (before) Object.defineProperty(globalThis, "localStorage", before)
    else delete globalThis.localStorage
  }
}

test("where reading localStorage throws, a push neither throws nor restores", () => {
  whileStorageBlocked(() => {
    assert.equal(recall("display:3:board"), null)
    assert.doesNotThrow(() => remember("display:3:board", {width: "wide"}))
    assert.equal(handlePrefs({key: "display:3:board", query: {}, restore: true}), null)
  })
})
