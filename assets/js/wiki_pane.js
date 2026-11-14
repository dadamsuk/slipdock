// The wiki's tree pane, on a wide screen: folded away, or dragged wider or
// narrower (#737). Both are a reader's preference for this browser, so they
// live in localStorage rather than on the server, and are put on <html> —
// `data-wiki-tree="collapsed"` and `--wiki-tree-width` — where LiveView's
// patches never reach (see the `#wiki-tree` rules in app.css). theme.js
// restores them before the first paint, so the pane never jumps.
//
// On a phone the tree is a drawer (`toggle_tree_drawer`), and neither applies.
//
// The page beside it is read in a column, or across the whole width
// (#748): `data-wiki-width="full"` on <html>, kept the same way.

import {read, write, widthPref, rootFlag, resizeHandle, rootToggle} from "./pane_controls.js"

export const WIDTH_KEY = "slipdock:wiki-tree-width"
export const COLLAPSED_KEY = "slipdock:wiki-tree-collapsed"
export const FULL_WIDTH_KEY = "slipdock:wiki-full-width"
// Wide enough for a 28-character name a folder down (#1745).
export const DEFAULT_WIDTH = 320
export const MIN_WIDTH = 180
export const MAX_WIDTH = 640
// How far one arrow key press moves the handle.
export const STEP = 16

const width = widthPref({
  prop: "--wiki-tree-width", key: WIDTH_KEY, min: MIN_WIDTH, max: MAX_WIDTH, def: DEFAULT_WIDTH,
})
const collapsed = rootFlag({attr: "data-wiki-tree", value: "collapsed", key: COLLAPSED_KEY})
const fullWidth = rootFlag({attr: "data-wiki-width", value: "full", key: FULL_WIDTH_KEY})

export const clampWidth = width.clamp
export const savedWidth = width.saved
export const setWidth = width.set
export const resetWidth = width.reset
export const isCollapsed = collapsed.is
export const setCollapsed = collapsed.set
export const isFullWidth = fullWidth.is
export const setFullWidth = fullWidth.set

// What theme.js runs before the first paint.
export function restorePane(root, storage) {
  width.restore(root, storage)
  collapsed.restore(root, storage)
  fullWidth.restore(root, storage)
}

// The button that folds the pane away and brings it back.
export const WikiTreeCollapse = rootToggle({
  flag: collapsed, aria: "aria-expanded", invert: true,
  titles: {on: "Show the page tree", off: "Hide the page tree"},
})

// The button that widens the page to the whole width and back to a column
// (#748).
export const WikiWidthToggle = rootToggle({
  flag: fullWidth, aria: "aria-pressed",
  titles: {on: "Read in a column", off: "Read across the full width"},
})

// The handle on the pane's right edge (see resizeHandle). A drag starts from
// the pane's drawn width, which is the variable's unless the screen squeezes
// it.
export const WikiTreeResize = resizeHandle({
  pref: width,
  step: STEP,
  startWidth: hook => {
    if (hook.pane === undefined) hook.pane = document.getElementById(hook.el.dataset.pane || "wiki-tree")
    return hook.pane ? hook.pane.getBoundingClientRect().width : width.current(hook.root)
  },
})

// The tree pane's Tree / Recent switch (#738). The server draws both and
// does the switching; this keeps which one the reader last chose, for this
// browser, and asks for it again when the wiki opens. Only "recent" is
// stored: the tree is the default.
export const VIEW_KEY = "slipdock:wiki-tree-view"

export const WikiTreeView = {
  mounted() {
    this.storage = this.storage || localStorage
    if (read(VIEW_KEY, this.storage) === "recent") this.pushEvent("tree_view", {view: "recent"})
    this.handleEvent("wiki-tree:view", ({view}) =>
      write(VIEW_KEY, view === "recent" ? "recent" : null, this.storage))
  },
}

// A link to a wiki file opens it in a panel beside the page (#768) rather
// than on a page of its own: the tree's file rows and a page's [[file]]
// links both go to `/files/<id>`, so one listener on the wiki takes them
// all. A click with a modifier, or any other button, is the browser's: a
// new tab still gets the page of its own, and so does a link marked
// `data-own-page` (the panel's own "open on a page of its own").
export function fileLinkId(e) {
  if (e.defaultPrevented || e.button !== 0) return null
  if (e.ctrlKey || e.metaKey || e.shiftKey || e.altKey) return null
  const link = e.target && e.target.closest && e.target.closest("a[href]")
  if (!link || link.target === "_blank") return null
  if (link.hasAttribute("download") || link.hasAttribute("data-own-page")) return null
  const match = /^\/files\/(\d+)$/.exec(link.getAttribute("href") || "")
  return match ? match[1] : null
}

export const WikiFileOpen = {
  mounted() {
    this.onClick = e => {
      const id = fileLinkId(e)
      if (id === null) return
      e.preventDefault()
      this.pushEvent("open_file", {id})
    }
    this.el.addEventListener("click", this.onClick)
  },
  destroyed() {
    this.el.removeEventListener("click", this.onClick)
  },
}

// The editor's Preview pane (#1744). The editor renders as you type, so it
// opens alone at the whole width; a writer who turns the Preview pane on has
// it on every page in this browser. Only "on" is kept: a browser that once
// stored "off" (when the pane was the default) reads as off, as it was.
export const PREVIEW_KEY = "slipdock:wiki-preview"

export function savedPreview(storage) {
  return read(PREVIEW_KEY, storage) === "on"
}

export function savePreview(storage, on) {
  write(PREVIEW_KEY, on ? "on" : null, storage)
  return on
}

// On the Preview button: tells the server what this browser last chose, and
// keeps each new choice the server reports back.
export const EditorPrefs = {
  mounted() {
    const storage = this.storage || localStorage
    if (savedPreview(storage)) this.pushEvent("restore_preview", {on: true})
    this.handleEvent("wiki-editor:preview", ({on}) => savePreview(storage, on))
  },
}
