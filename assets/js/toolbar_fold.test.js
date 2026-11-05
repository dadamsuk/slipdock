// node --test assets/js — a board view's toolbar folding its own controls
// into View options (#1711), against a stand-in DOM: only what
// toolbar_fold.js touches. tools/e2e/toolbar-one-row.sh measures the real
// thing in Chromium.
import {test, beforeEach} from "node:test"
import assert from "node:assert/strict"
import {ToolbarFold, WIDE, isWrapped, shouldFold, overflowsRight, rowItems} from "./toolbar_fold.js"

const box = (top, height = 32, width = 40) => ({top, bottom: top + height, height, width})

test("WIDE is the sm breakpoint", () => {
  assert.equal(WIDE, "(min-width: 40rem)")
})

test("a row whose boxes all overlap is not wrapped", () => {
  assert.equal(isWrapped([box(8), box(10, 28), box(6, 36)]), false)
})

test("a box starting below the first row is wrapped", () => {
  assert.equal(isWrapped([box(8), box(10, 28), box(48)]), true)
  // Touching the bottom edge, within half a pixel, counts as the next row.
  assert.equal(isWrapped([box(8), box(39.6)]), true)
  assert.equal(isWrapped([box(8), box(39)]), false)
})

test("fewer than two drawn boxes never wrap; empty or missing ones are left out", () => {
  assert.equal(isWrapped([]), false)
  assert.equal(isWrapped([box(8)]), false)
  assert.equal(isWrapped([box(8), null, {top: 90, bottom: 90, height: 0, width: 0}]), false)
  assert.equal(isWrapped([box(8), {top: 90, bottom: 120, height: 30, width: 0}]), false)
})

test("folds only when wide, wrapping and with something to fold", () => {
  assert.equal(shouldFold({wide: true, wraps: true, foldable: true}), true)
  assert.equal(shouldFold({wide: false, wraps: true, foldable: true}), false)
  assert.equal(shouldFold({wide: true, wraps: false, foldable: true}), false)
  assert.equal(shouldFold({wide: true, wraps: true, foldable: false}), false)
  assert.equal(shouldFold({}), false)
})

test("a popover past the right edge, less a margin, overflows", () => {
  assert.equal(overflowsRight({right: 1000}, 1280), false)
  assert.equal(overflowsRight({right: 1273}, 1280), true)
  assert.equal(overflowsRight({right: 1272}, 1280), false)
  assert.equal(overflowsRight({right: 1275}, 1280, 0), false)
})

test("rowItems looks through display: contents and skips what is out of the flow", () => {
  const el = (name, display = "flex", position = "static", children = []) => ({name, display, position, children})
  const bar = el("bar", "flex", "static", [
    el("switcher"),
    el("form", "contents", "static", [el("search"), el("tb", "contents", "static", [el("filter")]), el("hidden", "none")]),
    el("panel", "flex", "absolute"),
    el("fixed", "block", "fixed"),
    el("right"),
  ])
  const style = e => ({display: e.display, position: e.position})
  assert.deepEqual(rowItems(bar, style).map(e => e.name), ["switcher", "search", "filter", "right"])
  assert.deepEqual(rowItems(el("empty"), style), [])
})

// A stand-in toolbar for the hook: attributes, a toggle, a panel and the
// row's items, whose boxes `rows` decides (one row, or wrapped).
function toolbar({wrapped = false, foldable = true, panelRight = 600} = {}) {
  const attrs = (initial = {}) => {
    const a = {...initial}
    return {
      a,
      setAttribute: (k, v) => { a[k] = String(v) },
      removeAttribute: k => { delete a[k] },
      hasAttribute: k => k in a,
      getAttribute: k => (k in a ? a[k] : null),
    }
  }
  const toggle = {...attrs({"aria-expanded": "false"}), focused: false, focus() { this.focused = true }}
  toggle.closest = sel => (sel === "#view-options-toggle" ? toggle : null)
  const panel = {getBoundingClientRect: () => ({right: panelRight})}
  const optionsBox = {contains: t => t === toggle || t === panel}
  const item = top => ({display: "flex", position: "static", children: [], getBoundingClientRect: () => box(top)})
  const listeners = {}
  const el = {
    ...attrs(),
    clientWidth: 1280,
    children: [item(8), item(8), item(wrapped ? 48 : 8)],
    addEventListener: (t, f) => { listeners[t] = f },
    contains: t => t === toggle || t === panel,
    querySelector: sel =>
      ({"#view-options-toggle": toggle, ".view-own": foldable ? panel : null, "[data-tb=view-options]": optionsBox})[sel] ?? null,
  }
  return {el, toggle, panel, listeners}
}

let doc
beforeEach(() => {
  doc = {}
  globalThis.document = {
    addEventListener: (t, f) => { doc[t] = f },
    removeEventListener: (t, f) => { if (doc[t] === f) delete doc[t] },
    fonts: undefined,
  }
  globalThis.window = {innerWidth: 1280, matchMedia: () => ({matches: true})}
  globalThis.getComputedStyle = e => ({display: e.display, position: e.position})
  globalThis.ResizeObserver = class { observe() {} disconnect() { this.gone = true } }
})

function mount(opts, wide = true) {
  window.matchMedia = () => ({matches: wide})
  const t = toolbar(opts)
  const ignored = []
  const hook = Object.create(ToolbarFold)
  hook.el = t.el
  hook.js = () => ({ignoreAttributes: (el, names) => ignored.push([el, names])})
  hook.mounted()
  return {hook, ignored, ...t}
}

test("a wrapping wide toolbar folds, and asks LiveView to keep its attributes", () => {
  const {el, ignored, toggle} = mount({wrapped: true})
  assert.equal(el.hasAttribute("data-folded"), true)
  assert.deepEqual(ignored[0], [el, ["data-folded", "data-options-open", "data-options-end"]])
  assert.ok(ignored.some(([e, names]) => e === toggle && names.includes("aria-expanded")))
})

test("a toolbar that fits, a phone's, or one with nothing to fold does not", () => {
  assert.equal(mount({wrapped: false}).el.hasAttribute("data-folded"), false)
  assert.equal(mount({wrapped: true}, false).el.hasAttribute("data-folded"), false)
  assert.equal(mount({wrapped: true, foldable: false}).el.hasAttribute("data-folded"), false)
})

test("the toggle opens and closes View options, with aria-expanded to match", () => {
  const {el, toggle, listeners} = mount({wrapped: true})
  let prevented = 0
  const click = () => listeners.click({target: toggle, preventDefault: () => prevented++})
  click()
  assert.equal(el.hasAttribute("data-options-open"), true)
  assert.equal(toggle.getAttribute("aria-expanded"), "true")
  assert.equal(el.hasAttribute("data-options-end"), false)
  click()
  assert.equal(el.hasAttribute("data-options-open"), false)
  assert.equal(toggle.getAttribute("aria-expanded"), "false")
  assert.equal(prevented, 2)
  // A click anywhere else in the toolbar is not the toggle's.
  listeners.click({target: {closest: () => null}, preventDefault: () => prevented++})
  assert.equal(prevented, 2)
})

test("near the right edge it opens towards the left", () => {
  const {el, toggle, listeners} = mount({wrapped: true, panelRight: 1279})
  listeners.click({target: toggle, preventDefault() {}})
  assert.equal(el.hasAttribute("data-options-end"), true)
})

test("Escape closes it and gives the toggle focus; other keys don't", () => {
  const {el, hook, toggle} = mount({wrapped: true})
  hook.setOpen(true)
  doc.keydown({key: "a"})
  assert.equal(el.hasAttribute("data-options-open"), true)
  doc.keydown({key: "Escape"})
  assert.equal(el.hasAttribute("data-options-open"), false)
  assert.equal(toggle.focused, true)
  // Closed already: Escape does nothing, and focus is left alone.
  toggle.focused = false
  doc.keydown({key: "Escape"})
  assert.equal(toggle.focused, false)
})

test("a press outside closes it; a press inside the popover doesn't", () => {
  const {el, hook, panel} = mount({wrapped: true})
  hook.setOpen(true)
  doc.pointerdown({target: panel})
  assert.equal(el.hasAttribute("data-options-open"), true)
  doc.pointerdown({target: {}})
  assert.equal(el.hasAttribute("data-options-open"), false)
})

test("a patch that makes room unfolds and closes it; one that doesn't keeps it open", () => {
  const t = mount({wrapped: true})
  t.hook.setOpen(true)
  t.hook.updated()
  assert.equal(t.el.hasAttribute("data-folded"), true)
  assert.equal(t.el.hasAttribute("data-options-open"), true)
  t.el.children = t.el.children.slice(0, 2)
  t.hook.updated()
  assert.equal(t.el.hasAttribute("data-folded"), false)
  assert.equal(t.el.hasAttribute("data-options-open"), false)
  assert.equal(t.toggle.getAttribute("aria-expanded"), "false")
})

test("destroyed lets go of the document and the observer", () => {
  const {hook} = mount({wrapped: true})
  assert.ok(doc.keydown && doc.pointerdown)
  hook.destroyed()
  assert.equal(doc.keydown, undefined)
  assert.equal(doc.pointerdown, undefined)
  assert.equal(hook.ro.gone, true)
})
