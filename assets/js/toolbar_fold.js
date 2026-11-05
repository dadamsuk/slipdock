// A board view's toolbar stays one row (#1711).
//
// Every view's toolbar (`view_toolbar/1`) runs view switcher, search, Filter,
// the view's own controls, Display, then count, Select, Views and the board's
// buttons. Some views have a lot of their own (the narrative's group, span,
// from, to and sort), and at 1280 or 1440 the row would wrap. So from `sm` up
// this hook measures the row: when it wraps, it sets `data-folded` on the
// toolbar and CSS draws the view's own controls as a View options popover
// instead. They never leave the form, so they still post.
//
// The server renders neither `data-folded` nor `data-options-open`, so the
// hook asks LiveView to leave them be across patches, and measures again
// after each patch (a longer date title, a saved view's pill) and whenever
// the toolbar changes width.

// Wider than this the toolbar is a row; narrower it is the phone's, with its
// Options drawer (the `sm` breakpoint, 40rem).
export const WIDE = "(min-width: 40rem)"

// Whether boxes laid out by a wrapping flex row went onto a second row. Items
// in one row are centred on it, so each one overlaps the shortest item's
// span; an item that starts below the bottom of that one is on a new row.
export function isWrapped(rects) {
  const boxes = rects.filter(r => r && r.height > 0 && r.width > 0)
  if (boxes.length < 2) return false
  const firstBottom = Math.min(...boxes.map(r => r.bottom))
  return boxes.some(r => r.top >= firstBottom - 0.5)
}

// Whether the toolbar should fold, given whether it is wide and whether its
// row wraps with everything unfolded. A toolbar with nothing of the view's
// own to fold never does.
export function shouldFold({wide, wraps, foldable}) {
  return Boolean(wide && wraps && foldable)
}

// Whether an open popover at `rect` runs off a viewport `width` wide, so it
// should open towards the left instead.
export function overflowsRight(rect, width, margin = 8) {
  return rect.right > width - margin
}

// The boxes the toolbar's row is made of: its flex items, looking through
// `display: contents` wrappers (forms, the `data-tb` parts) to what they
// hold, and leaving out what is hidden or taken out of the flow.
export function rowItems(el, style = e => getComputedStyle(e)) {
  const items = []
  for (const child of el.children) {
    const s = style(child)
    if (s.display === "none" || s.position === "absolute" || s.position === "fixed") continue
    if (s.display === "contents") items.push(...rowItems(child, style))
    else items.push(child)
  }
  return items
}

export const ToolbarFold = {
  mounted() {
    this.js().ignoreAttributes(this.el, ["data-folded", "data-options-open", "data-options-end"])
    this.wide = window.matchMedia(WIDE)

    this.onClick = e => {
      const toggle = e.target.closest("#view-options-toggle")
      if (!toggle || !this.el.contains(toggle)) return
      e.preventDefault()
      this.setOpen(!this.el.hasAttribute("data-options-open"))
    }
    // A press anywhere but the popover and its button closes it.
    this.onDown = e => {
      if (!this.el.hasAttribute("data-options-open")) return
      const box = this.el.querySelector("[data-tb=view-options]")
      if (box && box.contains(e.target)) return
      this.setOpen(false)
    }
    this.onKey = e => {
      if (e.key !== "Escape" || !this.el.hasAttribute("data-options-open")) return
      this.setOpen(false)
      this.el.querySelector("#view-options-toggle")?.focus()
    }
    this.el.addEventListener("click", this.onClick)
    document.addEventListener("pointerdown", this.onDown)
    document.addEventListener("keydown", this.onKey)

    // Only a change of width can change what fits; folding changes the
    // height, which must not set off another measure.
    this.width = this.el.clientWidth
    this.ro = new ResizeObserver(() => {
      if (this.el.clientWidth === this.width) return
      this.width = this.el.clientWidth
      this.fit()
    })
    this.ro.observe(this.el)
    document.fonts?.ready.then(() => this.fit())
    this.fit()
  },

  updated() {
    this.fit()
  },

  destroyed() {
    this.ro?.disconnect()
    document.removeEventListener("pointerdown", this.onDown)
    document.removeEventListener("keydown", this.onKey)
  },

  // Unfold, measure, and fold again if the row wrapped: all before the
  // browser paints, so nothing flickers.
  fit() {
    const toggle = this.el.querySelector("#view-options-toggle")
    if (toggle) this.js().ignoreAttributes(toggle, ["aria-expanded"])
    const wasFolded = this.el.hasAttribute("data-folded")
    this.el.removeAttribute("data-folded")
    const fold = shouldFold({
      wide: this.wide.matches,
      foldable: Boolean(this.el.querySelector(".view-own")),
      wraps: isWrapped(rowItems(this.el).map(item => item.getBoundingClientRect())),
    })
    if (fold) this.el.setAttribute("data-folded", "")
    else if (wasFolded || this.el.hasAttribute("data-options-open")) this.setOpen(false)
  },

  setOpen(open) {
    const toggle = this.el.querySelector("#view-options-toggle")
    this.el.removeAttribute("data-options-end")
    if (open) this.el.setAttribute("data-options-open", "")
    else this.el.removeAttribute("data-options-open")
    toggle?.setAttribute("aria-expanded", open ? "true" : "false")
    if (!open) return
    const panel = this.el.querySelector(".view-own")
    if (panel && overflowsRight(panel.getBoundingClientRect(), window.innerWidth)) {
      this.el.setAttribute("data-options-end", "")
    }
  },
}
