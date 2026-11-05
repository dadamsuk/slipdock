// Keyboard moves for `<.tabs>` (#1740, `core_components.ex`): the arrow
// keys go to the next or previous tab (round the ends), Home to the first
// and End to the last. The tab landed on is focused and activated, so a
// button tab sends its event and a link tab patches. The server marks the
// active tab `tabindex="0"` and the rest "-1"; this sets the same while it
// waits, so Tab out of the bar and back lands where you left it.

// Where `key` moves from tab `current` of `count`, or null for a key that
// isn't a tab move (or no tabs to move along).
export function nextIndex(key, current, count) {
  if (count <= 0) return null
  switch (key) {
    case "ArrowRight":
    case "ArrowDown":
      return (current + 1) % count
    case "ArrowLeft":
    case "ArrowUp":
      return (current - 1 + count) % count
    case "Home":
      return 0
    case "End":
      return count - 1
    default:
      return null
  }
}

// The tabs of `list`: its own role=tab children, not a nested bar's.
export function tabsOf(list) {
  return Array.from(list.querySelectorAll("[role=tab]")).filter(
    t => t.closest("[role=tablist]") === list,
  )
}

// Focus and activate tab `index` of `tabs`, making it the one in the Tab order.
export function moveTo(tabs, index) {
  tabs.forEach((t, i) => t.setAttribute("tabindex", i === index ? "0" : "-1"))
  const tab = tabs[index]
  tab.focus()
  tab.click()
}

export const Tabs = {
  mounted() {
    this.onKey = e => {
      if (e.altKey || e.ctrlKey || e.metaKey || e.shiftKey) return
      const tabs = tabsOf(this.el)
      const current = tabs.indexOf(e.target.closest("[role=tab]"))
      if (current < 0) return
      const next = nextIndex(e.key, current, tabs.length)
      if (next === null) return
      e.preventDefault()
      if (next !== current) moveTo(tabs, next)
    }
    this.el.addEventListener("keydown", this.onKey)
  },

  destroyed() {
    this.el.removeEventListener("keydown", this.onKey)
  },
}
