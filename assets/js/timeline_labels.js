// The timeline's titles (#1732).
//
// The title column can be dragged wider or narrower, as the wiki's tree pane
// can (wiki_pane.js). The width is a reader's preference for this browser, so
// it lives in localStorage and is put on <html> as `--tl-label-width`, where
// LiveView's patches never reach; the grid's `--tl-cols` reads it (see
// timeline_components.ex). theme.js restores it before the first paint.
//
// And a dependency line leaves or arrives at a bar's top or bottom edge when
// a title sits beside it on that side, so it never runs through the title
// (linkPath).

export const LABEL_WIDTH_KEY = "slipdock:timeline-label-width"
export const DEFAULT_LABEL_WIDTH = 256
export const MIN_LABEL_WIDTH = 160
export const MAX_LABEL_WIDTH = 640
// How far one arrow key press moves the handle.
export const LABEL_STEP = 16
const PROP = "--tl-label-width"

export function clampLabelWidth(px) {
  const n = Math.round(Number(px))
  if (!Number.isFinite(n)) return DEFAULT_LABEL_WIDTH
  return Math.min(MAX_LABEL_WIDTH, Math.max(MIN_LABEL_WIDTH, n))
}

// localStorage can throw (private windows, storage turned off); a width that
// cannot be kept is still worth having for this visit.
function read(storage, key) {
  try { return storage.getItem(key) } catch (_e) { return null }
}

function write(storage, key, value) {
  try {
    if (value === null) storage.removeItem(key)
    else storage.setItem(key, value)
  } catch (_e) {}
}

export function setLabelWidth(root, storage, px, {save = true} = {}) {
  const width = clampLabelWidth(px)
  root.style.setProperty(PROP, `${width}px`)
  if (save) write(storage, LABEL_WIDTH_KEY, String(width))
  return width
}

export function resetLabelWidth(root, storage) {
  root.style.removeProperty(PROP)
  write(storage, LABEL_WIDTH_KEY, null)
  return DEFAULT_LABEL_WIDTH
}

export function labelWidth(root) {
  const set = parseInt(root.style.getPropertyValue(PROP), 10)
  return Number.isFinite(set) ? set : DEFAULT_LABEL_WIDTH
}

// What theme.js runs before the first paint.
export function restoreLabelWidth(root, storage) {
  const saved = read(storage, LABEL_WIDTH_KEY)
  if (saved !== null) setLabelWidth(root, storage, saved, {save: false})
}

// The handle on the title column's edge: drag it, or focus it and use the
// arrow keys (Home and End for the narrowest and widest); a double-click or
// Enter puts the width back. Lines are redrawn as the bars move with it.
export const TimelineLabelResize = {
  mounted() {
    this.root = this.root || document.documentElement
    this.storage = this.storage || localStorage
    this.redraw = this.redraw || (() => window.dispatchEvent(new Event("resize")))
    this.el.setAttribute("aria-valuemin", String(MIN_LABEL_WIDTH))
    this.el.setAttribute("aria-valuemax", String(MAX_LABEL_WIDTH))
    this.announce(labelWidth(this.root))

    this.onDown = e => {
      if (e.button !== undefined && e.button !== 0) return
      e.preventDefault()
      e.stopPropagation()
      this.drag = {x: e.clientX, start: labelWidth(this.root)}
      if (this.el.setPointerCapture && e.pointerId !== undefined) this.el.setPointerCapture(e.pointerId)
      this.el.setAttribute("data-dragging", "")
    }
    this.onMove = e => {
      if (!this.drag) return
      this.announce(setLabelWidth(this.root, this.storage, this.drag.start + e.clientX - this.drag.x, {save: false}))
      this.redraw()
    }
    this.onUp = () => {
      if (!this.drag) return
      this.drag = null
      this.el.removeAttribute("data-dragging")
      setLabelWidth(this.root, this.storage, labelWidth(this.root))
      this.redraw()
    }
    this.onKey = e => {
      const now = labelWidth(this.root)
      const to = {
        ArrowLeft: now - LABEL_STEP,
        ArrowRight: now + LABEL_STEP,
        Home: MIN_LABEL_WIDTH,
        End: MAX_LABEL_WIDTH,
      }[e.key]
      if (to !== undefined) {
        e.preventDefault()
        this.announce(setLabelWidth(this.root, this.storage, to))
        this.redraw()
      } else if (e.key === "Enter") {
        e.preventDefault()
        this.announce(resetLabelWidth(this.root, this.storage))
        this.redraw()
      }
    }
    this.onReset = () => {
      this.announce(resetLabelWidth(this.root, this.storage))
      this.redraw()
    }

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

// A dependency line, in the grid's coordinates (`box` is the grid's client
// rect): a curve from the right end of the blocker's bar to the left end of
// the bar it blocks, leaving and arriving sideways. A bar whose title sits
// beside it on that side has no room there, so the line leaves (or arrives
// at) the bar's bottom or top edge instead, going up or down to the other
// bar, and never runs through the title. `from` and `to` are the bars'
// rects; `fromBeside` says the blocker's title is on its right, `toBeside`
// that the blocked card's title is on its left. Returns the path's `d` and
// the end point, where the arrowhead dot goes.
export function linkPath(box, from, to, fromBeside = false, toBeside = false) {
  const fy = from.top + from.height / 2 - box.top
  const ty = to.top + to.height / 2 - box.top
  const down = ty >= fy
  let x1 = from.right - box.left, y1 = fy, c1
  let x2 = to.left - box.left, y2 = ty, c2
  const dx = Math.max(16, Math.abs(x2 - x1) / 2)
  const dy = Math.max(12, Math.abs(ty - fy) / 2)
  if (fromBeside) {
    x1 -= Math.min(4, from.width / 2)
    y1 = (down ? from.bottom : from.top) - box.top
    c1 = [x1, y1 + (down ? dy : -dy)]
  } else {
    c1 = [x1 + dx, y1]
  }
  if (toBeside) {
    x2 += Math.min(4, to.width / 2)
    y2 = (down ? to.top : to.bottom) - box.top
    c2 = [x2, y2 + (down ? -dy : dy)]
  } else {
    c2 = [x2 - dx, y2]
  }
  return {d: `M${x1},${y1} C${c1[0]},${c1[1]} ${c2[0]},${c2[1]} ${x2},${y2}`, x2, y2}
}
