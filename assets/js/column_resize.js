// A column heading's right edge, dragged to make the column wider or
// narrower (#3665): the table's, the outline's and Prioritise's. The width is
// part of the view (its URL and saved views), so it is the server's: while
// the edge is dragged the hook only sets the column's CSS variable (`--cw-…`,
// data-var) on the element that holds the widths (data-target), and when it
// is let go it sends `col_width`, whose patch draws the same width. A
// double-click (or Enter) sends no width, which puts the column back to its
// own; ←/→ move the edge a step at a time.

export const MIN_WIDTH = 48
export const MAX_WIDTH = 960
export const STEP = 16

export function clampWidth(px) {
  const n = Math.round(Number(px))
  if (!Number.isFinite(n)) return null
  return Math.min(MAX_WIDTH, Math.max(MIN_WIDTH, n))
}

// The width a drag that started at `start` (the heading's width) and moved
// `dx` pixels gives.
export function dragWidth(start, dx) {
  return clampWidth(start + dx)
}

export const ColumnResize = {
  mounted() {
    const el = this.el
    const target = () => document.querySelector(el.dataset.target)
    const heading = () => el.parentElement
    const show = width => {
      const t = target()
      if (!t) return
      if (width === null) t.style.removeProperty(el.dataset.var)
      else t.style.setProperty(el.dataset.var, `${width}px`)
    }
    const send = width => {
      el.setAttribute("aria-valuenow", width === null ? "" : String(width))
      this.pushEvent("col_width", {view: el.dataset.view, col: el.dataset.col, width})
    }
    const now = () => Math.round(heading().getBoundingClientRect().width)

    this.onDown = e => {
      if (e.button !== undefined && e.button !== 0) return
      e.preventDefault()
      // A press on the edge is not a press on the heading's sort button.
      e.stopPropagation()
      this.drag = {x: e.clientX, start: now(), width: null}
      if (el.setPointerCapture && e.pointerId !== undefined) el.setPointerCapture(e.pointerId)
      el.setAttribute("data-dragging", "")
    }
    this.onMove = e => {
      if (!this.drag) return
      this.drag.width = dragWidth(this.drag.start, e.clientX - this.drag.x)
      show(this.drag.width)
    }
    this.onUp = () => {
      if (!this.drag) return
      const {width} = this.drag
      this.drag = null
      el.removeAttribute("data-dragging")
      // A press without a move is a click: nothing to keep.
      if (width !== null) send(width)
    }
    this.onKey = e => {
      if (e.key === "ArrowLeft" || e.key === "ArrowRight") {
        e.preventDefault()
        const width = clampWidth(now() + (e.key === "ArrowLeft" ? -STEP : STEP))
        show(width)
        send(width)
      } else if (e.key === "Enter") {
        e.preventDefault()
        this.onReset()
      }
    }
    this.onReset = () => {
      show(null)
      send(null)
    }
    this.onClick = e => e.stopPropagation()

    el.addEventListener("pointerdown", this.onDown)
    el.addEventListener("pointermove", this.onMove)
    el.addEventListener("pointerup", this.onUp)
    el.addEventListener("pointercancel", this.onUp)
    el.addEventListener("keydown", this.onKey)
    el.addEventListener("dblclick", this.onReset)
    el.addEventListener("click", this.onClick)
  },
  destroyed() {
    const el = this.el
    el.removeEventListener("pointerdown", this.onDown)
    el.removeEventListener("pointermove", this.onMove)
    el.removeEventListener("pointerup", this.onUp)
    el.removeEventListener("pointercancel", this.onUp)
    el.removeEventListener("keydown", this.onKey)
    el.removeEventListener("dblclick", this.onReset)
    el.removeEventListener("click", this.onClick)
  },
}
