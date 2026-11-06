// Where a dropdown's menu opens (#1926). Start-aligned under its button when
// it fits, end-aligned when it doesn't, and then held inside the screen: on a
// phone a button mid-toolbar has room on neither side for a 288px menu, and
// end-aligning alone left the Display menu's first 66px off the left edge.

export const MARGIN = 8

// The menu's left edge, relative to the button's: `button` is its left and
// right in the viewport, `width` the menu's, `viewport` the screen's.
export function menuOffset(button, width, viewport, margin = MARGIN) {
  let left = button.left
  if (left + width > viewport - margin) left = button.right - width
  left = Math.min(left, viewport - margin - width)
  left = Math.max(left, margin)
  return Math.round(left - button.left)
}

export const DropdownAlign = {
  mounted() {
    this.align()
    this.el.addEventListener("focusin", () => this.align())
    window.addEventListener("resize", this.onResize = () => this.align())
  },
  // A patch drops the style set here, so set it again after one.
  updated() { this.align() },
  destroyed() { window.removeEventListener("resize", this.onResize) },
  align() {
    const menu = this.el.querySelector(".dropdown-content")
    if (!menu) return
    const width = menu.offsetWidth || parseFloat(getComputedStyle(menu).width) || 288
    const viewport = Math.min(window.innerWidth, document.documentElement.clientWidth || Infinity)
    const offset = menuOffset(this.el.getBoundingClientRect(), width, viewport)
    menu.style.left = `${offset}px`
    menu.style.right = "auto"
  },
}
