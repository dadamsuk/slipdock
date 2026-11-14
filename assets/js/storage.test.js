// node --test assets/js — the one guarded localStorage (#2882): where storage
// is blocked, reading the `localStorage` property itself throws, and nothing
// here may.
import {test} from "node:test"
import assert from "node:assert/strict"
import {storage, read, write, readJSON, writeJSON} from "./storage.js"

function fake(initial = {}) {
  const items = {...initial}
  return {
    items,
    getItem: k => (k in items ? items[k] : null),
    setItem: (k, v) => { items[k] = String(v) },
    removeItem: k => { delete items[k] },
  }
}

// A storage that refuses everything, as a full or locked-down one does.
const refusing = {
  getItem() { throw new Error("denied") },
  setItem() { throw new Error("quota") },
  removeItem() { throw new Error("denied") },
}

// Runs `fn` with globalThis.localStorage replaced by `descriptor`, then puts
// the original back.
function withGlobalStorage(descriptor, fn) {
  const before = Object.getOwnPropertyDescriptor(globalThis, "localStorage")
  Object.defineProperty(globalThis, "localStorage", {configurable: true, ...descriptor})
  try { return fn() } finally {
    if (before) Object.defineProperty(globalThis, "localStorage", before)
    else delete globalThis.localStorage
  }
}

const blocked = {get() { throw new DOMException("The operation is insecure.", "SecurityError") }}

test("storage() is the browser's localStorage", () => {
  const store = fake()
  withGlobalStorage({value: store}, () => assert.equal(storage(), store))
})

test("storage() is null where reading localStorage throws, or there is none", () => {
  withGlobalStorage(blocked, () => assert.equal(storage(), null))
  withGlobalStorage({value: undefined}, () => assert.equal(storage(), null))
})

test("with the getter throwing, every call gives its empty answer and none throws", () => {
  withGlobalStorage(blocked, () => {
    assert.equal(read("k"), null)
    assert.equal(write("k", "v"), false)
    assert.equal(write("k", null), false)
    assert.equal(readJSON("k"), null)
    assert.equal(writeJSON("k", {a: 1}), false)
  })
})

test("read and write default to the browser's storage", () => {
  const store = fake()
  withGlobalStorage({value: store}, () => {
    assert.equal(write("k", "v"), true)
    assert.equal(read("k"), "v")
  })
  assert.deepEqual(store.items, {k: "v"})
})

test("write keeps a string, and null or undefined forgets the key", () => {
  const store = fake({gone: "x", also: "y"})
  assert.equal(write("n", 42, store), true)
  assert.equal(store.items.n, "42")
  assert.equal(write("gone", null, store), true)
  assert.equal(write("also", undefined, store), true)
  assert.deepEqual(store.items, {n: "42"})
})

test("write hands the store a string, as Storage keeps one", () => {
  const kept = {}
  write("n", 42, {setItem: (k, v) => { kept[k] = v }})
  assert.equal(kept.n, "42")
})

test("read gives null for a missing key, even from a store that says undefined", () => {
  assert.equal(read("nothing", fake()), null)
  assert.equal(read("k", {getItem: () => undefined}), null)
})

test("a null store reads as empty and keeps nothing", () => {
  assert.equal(read("k", null), null)
  assert.equal(write("k", "v", null), false)
  assert.equal(readJSON("k", null), null)
  assert.equal(writeJSON("k", 1, null), false)
})

test("calls that throw (a full quota, a refusal) give the empty answer", () => {
  assert.equal(read("k", refusing), null)
  assert.equal(write("k", "v", refusing), false)
  assert.equal(write("k", null, refusing), false)
  assert.equal(readJSON("k", refusing), null)
  assert.equal(writeJSON("k", {a: 1}, refusing), false)
})

test("JSON goes in and comes back; null forgets it", () => {
  const store = fake()
  assert.equal(writeJSON("j", {side: "left", y: 0.5}, store), true)
  assert.equal(store.items.j, '{"side":"left","y":0.5}')
  assert.deepEqual(readJSON("j", store), {side: "left", y: 0.5})
  assert.equal(writeJSON("j", null, store), true)
  assert.equal("j" in store.items, false)
})

test("readJSON gives null for text that isn't JSON", () => {
  assert.equal(readJSON("j", fake({j: "{not json"})), null)
})

test("writeJSON of something that can't be JSON keeps nothing and doesn't throw", () => {
  const store = fake()
  const loop = {}
  loop.self = loop
  assert.equal(writeJSON("j", loop, store), false)
  assert.deepEqual(store.items, {})
})
