// The wiki's tree pane, on a wide screen: folded away, or dragged wider or
// narrower (#737). Both are a reader's preference for this browser, so they
// live in localStorage rather than on the server, and are put on <html> —
// `data-wiki-tree="collapsed"` and `--wiki-tree-width` — where LiveView's
// patches never reach (see the `#wiki-tree` rules in app.css). theme.js
// restores them before the first paint, so the pane never jumps.
//
// On a phone the tree is a drawer (`toggle_tree_drawer`), and neither applies.

export const WIDTH_KEY = "slipdock:wiki-tree-width"
export const COLLAPSED_KEY = "slipdock:wiki-tree-collapsed"
export const DEFAULT_WIDTH = 256
export const MIN_WIDTH = 180
export const MAX_WIDTH = 640
// How far one arrow key press moves the handle.
export const STEP = 16

export function clampWidth(px) {
  const n = Math.round(Number(px))
  if (!Number.isFinite(n)) return DEFAULT_WIDTH
  return Math.min(MAX_WIDTH, Math.max(MIN_WIDTH, n))
}

// localStorage can throw (private windows, storage turned off); a preference
// that cannot be kept is still worth having for this visit.
function read(storage, key) {
  try { return storage.getItem(key) } catch (_e) { return null }
}

function write(storage, key, value) {
  try {
    if (value === null) storage.removeItem(key)
    else storage.setItem(key, value)
  } catch (_e) {}
}

export function savedWidth(storage) {
  const saved = read(storage, WIDTH_KEY)
  return saved === null ? null : clampWidth(saved)
}

export function isCollapsed(root) {
  return root.getAttribute("data-wiki-tree") === "collapsed"
}

export function setWidth(root, storage, px, {save = true} = {}) {
  const width = clampWidth(px)
  root.style.setProperty("--wiki-tree-width", `${width}px`)
  if (save) write(storage, WIDTH_KEY, String(width))
  return width
}

// Back to the width the pane started with.
export function resetWidth(root, storage) {
  root.style.removeProperty("--wiki-tree-width")
  write(storage, WIDTH_KEY, null)
  return DEFAULT_WIDTH
}

export function setCollapsed(root, storage, collapsed) {
  if (collapsed) root.setAttribute("data-wiki-tree", "collapsed")
  else root.removeAttribute("data-wiki-tree")
  write(storage, COLLAPSED_KEY, collapsed ? "1" : null)
  return collapsed
}

// What theme.js runs before the first paint.
export function restorePane(root, storage) {
  const width = savedWidth(storage)
  if (width !== null) setWidth(root, storage, width, {save: false})
  if (read(storage, COLLAPSED_KEY) === "1") root.setAttribute("data-wiki-tree", "collapsed")
}

function currentWidth(root) {
  const set = parseInt(root.style.getPropertyValue("--wiki-tree-width"), 10)
  return Number.isFinite(set) ? set : DEFAULT_WIDTH
}

// The button that folds the pane away and brings it back. It sits in a
// `phx-update="ignore"` box, so the aria-expanded set here stays set.
export const WikiTreeCollapse = {
  mounted() {
    this.root = this.root || document.documentElement
    this.storage = this.storage || localStorage
    this.sync()
    this.onClick = () => {
      setCollapsed(this.root, this.storage, !isCollapsed(this.root))
      this.sync()
    }
    this.el.addEventListener("click", this.onClick)
  },
  destroyed() {
    this.el.removeEventListener("click", this.onClick)
  },
  sync() {
    const open = !isCollapsed(this.root)
    this.el.setAttribute("aria-expanded", String(open))
    this.el.setAttribute("title", open ? "Hide the page tree" : "Show the page tree")
  },
}

// The handle on the pane's right edge: drag it, or focus it and use the
// arrow keys (Home and End for the narrowest and widest); a double-click or
// Enter puts the width back.
export const WikiTreeResize = {
  mounted() {
    this.root = this.root || document.documentElement
    this.storage = this.storage || localStorage
    if (this.pane === undefined) this.pane = document.getElementById(this.el.dataset.pane || "wiki-tree")
    this.el.setAttribute("aria-valuemin", String(MIN_WIDTH))
    this.el.setAttribute("aria-valuemax", String(MAX_WIDTH))
    this.announce(currentWidth(this.root))

    this.onDown = e => {
      if (e.button !== undefined && e.button !== 0) return
      e.preventDefault()
      const start = this.pane ? this.pane.getBoundingClientRect().width : currentWidth(this.root)
      this.drag = {x: e.clientX, start}
      if (this.el.setPointerCapture && e.pointerId !== undefined) this.el.setPointerCapture(e.pointerId)
      this.el.setAttribute("data-dragging", "")
    }
    this.onMove = e => {
      if (!this.drag) return
      const width = setWidth(this.root, this.storage, this.drag.start + e.clientX - this.drag.x, {save: false})
      this.announce(width)
    }
    this.onUp = () => {
      if (!this.drag) return
      this.drag = null
      this.el.removeAttribute("data-dragging")
      setWidth(this.root, this.storage, currentWidth(this.root))
    }
    this.onKey = e => {
      const now = currentWidth(this.root)
      const to = {
        ArrowLeft: now - STEP,
        ArrowRight: now + STEP,
        Home: MIN_WIDTH,
        End: MAX_WIDTH,
      }[e.key]
      if (to !== undefined) {
        e.preventDefault()
        this.announce(setWidth(this.root, this.storage, to))
      } else if (e.key === "Enter") {
        e.preventDefault()
        this.announce(resetWidth(this.root, this.storage))
      }
    }
    this.onReset = () => this.announce(resetWidth(this.root, this.storage))

    this.el.addEventListener("pointerdown", this.onDown)
    this.el.addEventListener("pointermove", this.onMove)
    this.el.addEventListener("pointerup", this.onUp)
    this.el.addEventListener("pointercancel", this.onUp)
    this.el.addEventListener("keydown", this.onKey)
    this.el.addEventListener("dblclick", this.onReset)
  },
  destroyed() {
    this.el.removeEventListener("pointerdown", this.onDown)
    this.el.removeEventListener("pointermove", this.onMove)
    this.el.removeEventListener("pointerup", this.onUp)
    this.el.removeEventListener("pointercancel", this.onUp)
    this.el.removeEventListener("keydown", this.onKey)
    this.el.removeEventListener("dblclick", this.onReset)
  },
  announce(width) {
    this.el.setAttribute("aria-valuenow", String(width))
  },
}

// The tree pane's Tree / Recent switch (#738). The server draws both and
// does the switching; this keeps which one the reader last chose, for this
// browser, and asks for it again when the wiki opens. Only "recent" is
// stored: the tree is the default.
export const VIEW_KEY = "slipdock:wiki-tree-view"

export const WikiTreeView = {
  mounted() {
    this.storage = this.storage || localStorage
    if (read(this.storage, VIEW_KEY) === "recent") this.pushEvent("tree_view", {view: "recent"})
    this.handleEvent("wiki-tree:view", ({view}) =>
      write(this.storage, VIEW_KEY, view === "recent" ? "recent" : null))
  },
}
