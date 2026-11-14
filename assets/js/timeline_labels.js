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

import {widthPref, resizeHandle} from "./pane_controls.js"

export const LABEL_WIDTH_KEY = "slipdock:timeline-label-width"
export const DEFAULT_LABEL_WIDTH = 256
export const MIN_LABEL_WIDTH = 160
export const MAX_LABEL_WIDTH = 640
// How far one arrow key press moves the handle.
export const LABEL_STEP = 16

const width = widthPref({
  prop: "--tl-label-width", key: LABEL_WIDTH_KEY,
  min: MIN_LABEL_WIDTH, max: MAX_LABEL_WIDTH, def: DEFAULT_LABEL_WIDTH,
})

export const clampLabelWidth = width.clamp
export const setLabelWidth = width.set
export const resetLabelWidth = width.reset
export const labelWidth = width.current
// What theme.js runs before the first paint.
export const restoreLabelWidth = width.restore

// The handle on the title column's edge (see resizeHandle). A press stops
// here, so it never starts a bar's drag underneath, and the lines are redrawn
// as the bars move with it.
export const TimelineLabelResize = resizeHandle({
  pref: width,
  step: LABEL_STEP,
  stopPropagation: true,
  onChange: hook => (hook.redraw || (() => window.dispatchEvent(new Event("resize"))))(),
})

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
