// This browser's localStorage, guarded (#2882). Where storage is blocked
// (a private window, cookies turned off, a sandboxed frame), reading the
// `localStorage` property itself throws, and so can `getItem` and `setItem`
// (a full quota). A preference that can't be kept is still worth having for
// the visit, so nothing here throws: a read gives null, a write gives false.
//
// Every function takes the store last, defaulting to `storage()`, so a test
// (or a hook given one) can pass its own. A null store reads as empty.
//
// The keys are the callers' own and have drifted (`slipdock:…`,
// `slipdock.dock`, `phx:theme`); they are kept as they are, since renaming
// one would forget what every browser has saved under it.

// localStorage, or null where there is none or reading it throws.
export function storage() {
  try { return globalThis.localStorage || null } catch (_e) { return null }
}

// The string kept under `key`, or null.
export function read(key, store = storage()) {
  if (!store) return null
  try {
    const value = store.getItem(key)
    return value === undefined ? null : value
  } catch (_e) {
    return null
  }
}

// Keeps `value` under `key` (as a string), or forgets the key when it is null
// or undefined. Whether it was kept.
export function write(key, value, store = storage()) {
  if (!store) return false
  try {
    if (value === null || value === undefined) store.removeItem(key)
    else store.setItem(key, String(value))
    return true
  } catch (_e) {
    return false
  }
}

// What JSON kept under `key` parses to, or null (nothing kept, or not JSON).
export function readJSON(key, store = storage()) {
  const raw = read(key, store)
  if (raw === null) return null
  try { return JSON.parse(raw) } catch (_e) { return null }
}

// Keeps `value` as JSON under `key`; null or undefined forgets it.
export function writeJSON(key, value, store = storage()) {
  if (value === null || value === undefined) return write(key, null, store)
  let json
  try { json = JSON.stringify(value) } catch (_e) { return false }
  return write(key, json, store)
}
