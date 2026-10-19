// The phone's floating navigation button can be dragged out of the way (#1130).
//
// It sits in the bottom-left corner, and sometimes that corner is where the
// thing you want to read is. Press and drag the round button and the whole
// navigation follows the finger; let go and it settles against the nearer
// side of the screen, at the height it was dropped. The row then opens away
// from that side, and the Menu opens downwards when the button is in the top
// half, so neither runs off the screen. Where it was put is kept in
// localStorage, per device, and survives a turn of the phone.
//
// A tap is still a tap: the button only starts to move once the finger has
// travelled DRAG_START pixels, and the click that ends a drag is swallowed so
// it does not open the row as well.

export const DRAG_START = 8
export const MARGIN = 12
// The Menu's distance from the row (mt-2).
const MENU_GAP = 8
export const STORE_KEY = "slipdock.dock"

export function isDrag(dx, dy) {
  return Math.hypot(dx, dy) >= DRAG_START
}

// Where a button of `size` dropped with its top-left at (x, y) settles: the
// side its centre is nearer, and a top that keeps it wholly on the screen.
export function settle({x, y}, size, viewport) {
  const side = x + size / 2 < viewport.width / 2 ? "left" : "right"
  return {side, top: clampTop(y, size, viewport)}
}

export function clampTop(top, size, viewport) {
  const max = Math.max(MARGIN, viewport.height - size - MARGIN)
  return Math.min(Math.max(top, MARGIN), max)
}

// The inline style and data attributes for a settled position. The top half
// of the screen opens the Menu downwards (data-edge="top"), the bottom half
// upwards, and --dock-room is the height it has that way: from the button to
// MARGIN off the edge of the screen.
export function placement({side, top}, size, viewport) {
  const t = Math.round(clampTop(top, size, viewport))
  const x = side === "right" ? `right:${MARGIN}px;left:auto` : `left:${MARGIN}px;right:auto`
  const edge = t + size / 2 < viewport.height / 2 ? "top" : "bottom"
  const room = Math.max(0, edge === "top" ? viewport.height - t - size - MENU_GAP - MARGIN : t - MENU_GAP - MARGIN)
  return {style: `top:${t}px;bottom:auto;${x};--dock-room:${room}px`, side, edge}
}

// Kept as a fraction of the screen's height, so a phone turned on its side
// puts the button at the same place along the edge rather than off it.
export function save(storage, {side, top}, viewport) {
  try {
    storage.setItem(STORE_KEY, JSON.stringify({side, y: top / viewport.height}))
  } catch (_) {
    // Private browsing, or storage full: it just won't be remembered.
  }
}

export function load(storage, viewport) {
  try {
    const raw = JSON.parse(storage.getItem(STORE_KEY))
    if (!raw || !["left", "right"].includes(raw.side) || !Number.isFinite(raw.y)) return null
    return {side: raw.side, top: raw.y * viewport.height}
  } catch (_) {
    return null
  }
}

const viewportNow = () => ({width: window.innerWidth, height: window.innerHeight})

// On the `<nav id="mobile-bar">`; the handle is its `#mobile-fab`.
export const DockDrag = {
  mounted() {
    this.fab = this.el.querySelector("#mobile-fab")
    if (!this.fab) return
    // The server renders none of these, so a patch must not take them away.
    this.js().ignoreAttributes(this.el, ["style", "data-side", "data-edge", "data-dragging"])

    this.pos = load(window.localStorage, viewportNow())
    this.apply()

    this.onDown = e => this.down(e)
    this.onMove = e => this.move(e)
    this.onUp = e => this.up(e)
    this.onClick = e => {
      if (!this.swallow) return
      this.swallow = false
      e.preventDefault()
      e.stopImmediatePropagation()
    }
    this.onResize = () => this.apply()
    this.fab.addEventListener("pointerdown", this.onDown)
    this.fab.addEventListener("pointermove", this.onMove)
    this.fab.addEventListener("pointerup", this.onUp)
    this.fab.addEventListener("pointercancel", this.onUp)
    this.fab.addEventListener("click", this.onClick, true)
    window.addEventListener("resize", this.onResize)
  },

  destroyed() {
    window.removeEventListener("resize", this.onResize)
  },

  apply() {
    if (!this.pos) return
    const size = this.fab.offsetHeight || 56
    const p = placement(this.pos, size, viewportNow())
    this.el.setAttribute("style", p.style)
    this.el.dataset.side = p.side
    this.el.dataset.edge = p.edge
  },

  down(e) {
    if (e.button !== 0) return
    this.swallow = false
    const r = this.fab.getBoundingClientRect()
    this.press = {x: e.clientX, y: e.clientY, dx: e.clientX - r.left, dy: e.clientY - r.top, dragging: false}
  },

  move(e) {
    const p = this.press
    if (!p) return
    if (!p.dragging) {
      if (!isDrag(e.clientX - p.x, e.clientY - p.y)) return
      p.dragging = true
      this.fab.setPointerCapture?.(e.pointerId)
      // Fold the row first: it is the button that moves.
      this.js().exec(this.el, this.el.getAttribute("phx-click-away"))
      this.el.dataset.dragging = ""
    }
    e.preventDefault()
    this.el.setAttribute("style", `left:${e.clientX - p.dx}px;top:${e.clientY - p.dy}px;right:auto;bottom:auto`)
  },

  up(e) {
    const p = this.press
    this.press = null
    if (!p || !p.dragging) return
    delete this.el.dataset.dragging
    const vp = viewportNow()
    this.pos = settle({x: e.clientX - p.dx, y: e.clientY - p.dy}, this.fab.offsetHeight || 56, vp)
    save(window.localStorage, this.pos, vp)
    this.apply()
    // A drag ends in a click on the button; that click is not a tap.
    this.swallow = e.type === "pointerup"
    setTimeout(() => { this.swallow = false }, 400)
  },
}
