// A board's Display options, remembered in this browser (#1879). The server
// pushes `display-prefs` on every visit to a board view (see
// `SlipdockWeb.BoardLive.DisplayPrefs`): the key for the board and mode, the
// display options in use, and whether it may restore. On a restore with
// something remembered, the hook sends it back; otherwise it remembers what
// is in use, an empty set included, so a reset to the defaults sticks.

export const PREFIX = "slipdock:"

function storage() {
  try { return globalThis.localStorage || null } catch (_) { return null }
}

// What is remembered for a key, or null: only a plain object of strings.
export function recall(key, store = storage()) {
  if (!store) return null
  let value
  try { value = JSON.parse(store.getItem(PREFIX + key)) } catch (_) { return null }
  if (!value || typeof value !== "object" || Array.isArray(value)) return null
  const entries = Object.entries(value).filter(([, v]) => typeof v === "string")
  return Object.fromEntries(entries)
}

export function remember(key, query, store = storage()) {
  if (!store) return
  try { store.setItem(PREFIX + key, JSON.stringify(query || {})) } catch (_) { /* full or refused */ }
}

// What to do with one push: the remembered set to send back, or null after
// remembering the one in use.
export function handlePrefs({key, query, restore}, store = storage()) {
  if (restore) {
    const saved = recall(key, store)
    if (saved && Object.keys(saved).length > 0) return saved
  }
  remember(key, query, store)
  return null
}

export const DisplayPrefs = {
  mounted() {
    this.handleEvent("display-prefs", payload => {
      const saved = handlePrefs(payload)
      if (saved) this.pushEvent("display_restore", {query: saved})
    })
  },
}
