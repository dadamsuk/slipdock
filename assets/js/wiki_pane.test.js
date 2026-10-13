// node --test assets/js — the wiki tree pane's fold and width (#737), with
// <html>, localStorage and the two elements faked down to what is touched.
import {test} from "node:test"
import assert from "node:assert/strict"
import {
  clampWidth, restorePane, setCollapsed, setWidth, resetWidth, savedWidth,
  WikiTreeCollapse, WikiTreeResize, WikiTreeView, VIEW_KEY,
  WIDTH_KEY, COLLAPSED_KEY, DEFAULT_WIDTH, MIN_WIDTH, MAX_WIDTH, STEP,
} from "./wiki_pane.js"

function storage(initial = {}) {
  const items = {...initial}
  return {
    items,
    getItem: k => (k in items ? items[k] : null),
    setItem: (k, v) => { items[k] = String(v) },
    removeItem: k => { delete items[k] },
  }
}

// A storage that refuses everything, as a locked-down browser's does.
const brokenStorage = {
  getItem() { throw new Error("denied") },
  setItem() { throw new Error("denied") },
  removeItem() { throw new Error("denied") },
}

function element() {
  const attrs = {}
  const props = {}
  const listeners = {}
  return {
    attrs, listeners, dataset: {},
    getAttribute: k => (k in attrs ? attrs[k] : null),
    setAttribute: (k, v) => { attrs[k] = String(v) },
    removeAttribute: k => { delete attrs[k] },
    hasAttribute: k => k in attrs,
    style: {
      props,
      setProperty: (k, v) => { props[k] = v },
      removeProperty: k => { delete props[k] },
      getPropertyValue: k => props[k] || "",
    },
    addEventListener: (t, fn) => { listeners[t] = fn },
    removeEventListener: t => { delete listeners[t] },
    fire(t, e = {}) { listeners[t]({preventDefault() { this.prevented = true }, ...e}) },
  }
}

function mount(hookDef, extra = {}) {
  const hook = Object.create(hookDef)
  Object.assign(hook, {el: element(), root: element(), storage: storage()}, extra)
  hook.mounted()
  return hook
}

test("widths are clamped, rounded, and nonsense falls back to the default", () => {
  assert.equal(clampWidth(10), MIN_WIDTH)
  assert.equal(clampWidth(5000), MAX_WIDTH)
  assert.equal(clampWidth("300.6"), 301)
  assert.equal(clampWidth("wide"), DEFAULT_WIDTH)
  assert.equal(clampWidth(undefined), DEFAULT_WIDTH)
})

test("restorePane puts back a saved width and fold, and saves nothing itself", () => {
  const root = element()
  const store = storage({[WIDTH_KEY]: "9999", [COLLAPSED_KEY]: "1"})
  restorePane(root, store)
  assert.equal(root.style.props["--wiki-tree-width"], `${MAX_WIDTH}px`)
  assert.equal(root.attrs["data-wiki-tree"], "collapsed")
  assert.equal(store.items[WIDTH_KEY], "9999")
})

test("restorePane with nothing saved, or storage refused, leaves the pane alone", () => {
  for (const store of [storage(), brokenStorage]) {
    const root = element()
    restorePane(root, store)
    assert.deepEqual(root.style.props, {})
    assert.equal(root.getAttribute("data-wiki-tree"), null)
  }
  assert.equal(savedWidth(brokenStorage), null)
})

test("setting and resetting width and fold write through to storage", () => {
  const root = element()
  const store = storage()
  assert.equal(setWidth(root, store, 320), 320)
  assert.equal(store.items[WIDTH_KEY], "320")
  assert.equal(resetWidth(root, store), DEFAULT_WIDTH)
  assert.equal(root.style.props["--wiki-tree-width"], undefined)
  assert.equal(store.items[WIDTH_KEY], undefined)

  setCollapsed(root, store, true)
  assert.equal(store.items[COLLAPSED_KEY], "1")
  setCollapsed(root, store, false)
  assert.equal(root.getAttribute("data-wiki-tree"), null)
  assert.equal(store.items[COLLAPSED_KEY], undefined)
})

test("a storage that throws still lets the pane change for this visit", () => {
  const root = element()
  assert.equal(setWidth(root, brokenStorage, 400), 400)
  assert.equal(root.style.props["--wiki-tree-width"], "400px")
  setCollapsed(root, brokenStorage, true)
  assert.equal(root.attrs["data-wiki-tree"], "collapsed")
})

test("the button folds the pane away and back, saying which on itself", () => {
  const hook = mount(WikiTreeCollapse)
  assert.equal(hook.el.attrs["aria-expanded"], "true")

  hook.el.fire("click")
  assert.equal(hook.root.attrs["data-wiki-tree"], "collapsed")
  assert.equal(hook.el.attrs["aria-expanded"], "false")
  assert.equal(hook.el.attrs.title, "Show the page tree")
  assert.equal(hook.storage.items[COLLAPSED_KEY], "1")

  hook.el.fire("click")
  assert.equal(hook.root.getAttribute("data-wiki-tree"), null)
  assert.equal(hook.el.attrs["aria-expanded"], "true")
  assert.equal(hook.storage.items[COLLAPSED_KEY], undefined)

  hook.destroyed()
  assert.equal(hook.el.listeners.click, undefined)
})

test("the button mounts showing a fold restored before it", () => {
  const root = element()
  root.setAttribute("data-wiki-tree", "collapsed")
  const hook = mount(WikiTreeCollapse, {root})
  assert.equal(hook.el.attrs["aria-expanded"], "false")
})

test("dragging the handle sets the width live and saves it on release", () => {
  const pane = {getBoundingClientRect: () => ({width: 256})}
  const hook = mount(WikiTreeResize, {pane})
  assert.equal(hook.el.attrs["aria-valuenow"], String(DEFAULT_WIDTH))
  assert.equal(hook.el.attrs["aria-valuemin"], String(MIN_WIDTH))

  hook.el.fire("pointerdown", {clientX: 300, button: 0})
  assert.ok(hook.el.hasAttribute("data-dragging"))
  hook.el.fire("pointermove", {clientX: 400})
  assert.equal(hook.root.style.props["--wiki-tree-width"], "356px")
  assert.equal(hook.el.attrs["aria-valuenow"], "356")
  assert.equal(hook.storage.items[WIDTH_KEY], undefined)

  hook.el.fire("pointermove", {clientX: -1000})
  assert.equal(hook.root.style.props["--wiki-tree-width"], `${MIN_WIDTH}px`)

  hook.el.fire("pointerup")
  assert.equal(hook.storage.items[WIDTH_KEY], String(MIN_WIDTH))
  assert.ok(!hook.el.hasAttribute("data-dragging"))

  // Moving with nothing held changes nothing.
  hook.el.fire("pointermove", {clientX: 900})
  assert.equal(hook.root.style.props["--wiki-tree-width"], `${MIN_WIDTH}px`)
})

test("a right-button press does not start a drag", () => {
  const hook = mount(WikiTreeResize, {pane: {getBoundingClientRect: () => ({width: 256})}})
  hook.el.fire("pointerdown", {clientX: 300, button: 2})
  hook.el.fire("pointermove", {clientX: 500})
  assert.equal(hook.root.style.props["--wiki-tree-width"], undefined)
})

test("the arrow keys, Home and End move the handle; Enter and a double-click reset it", () => {
  const hook = mount(WikiTreeResize, {pane: null})
  hook.el.fire("keydown", {key: "ArrowRight"})
  assert.equal(hook.storage.items[WIDTH_KEY], String(DEFAULT_WIDTH + STEP))
  hook.el.fire("keydown", {key: "ArrowLeft"})
  hook.el.fire("keydown", {key: "ArrowLeft"})
  assert.equal(hook.storage.items[WIDTH_KEY], String(DEFAULT_WIDTH - STEP))
  hook.el.fire("keydown", {key: "End"})
  assert.equal(hook.el.attrs["aria-valuenow"], String(MAX_WIDTH))
  hook.el.fire("keydown", {key: "Home"})
  assert.equal(hook.el.attrs["aria-valuenow"], String(MIN_WIDTH))

  hook.el.fire("keydown", {key: "Enter"})
  assert.equal(hook.storage.items[WIDTH_KEY], undefined)
  assert.equal(hook.el.attrs["aria-valuenow"], String(DEFAULT_WIDTH))

  hook.el.fire("keydown", {key: "End"})
  hook.el.fire("dblclick")
  assert.equal(hook.root.style.props["--wiki-tree-width"], undefined)

  // Other keys are left to the page.
  hook.el.fire("keydown", {key: "a"})
  assert.equal(hook.el.attrs["aria-valuenow"], String(DEFAULT_WIDTH))
})

test("the handle picks up a width restored before it mounted, and lets go on destroy", () => {
  const root = element()
  root.style.setProperty("--wiki-tree-width", "420px")
  const hook = mount(WikiTreeResize, {root, pane: null})
  assert.equal(hook.el.attrs["aria-valuenow"], "420")
  hook.el.fire("keydown", {key: "ArrowRight"})
  assert.equal(hook.root.style.props["--wiki-tree-width"], `${420 + STEP}px`)
  hook.destroyed()
  assert.deepEqual(Object.keys(hook.el.listeners), [])
})

// The Tree / Recent switch (#738): the server switches, the hook remembers.
function viewHook(store) {
  const hook = Object.create(WikiTreeView)
  const pushed = []
  const handlers = {}
  Object.assign(hook, {
    el: element(), storage: store, pushed, handlers,
    pushEvent: (name, payload) => pushed.push([name, payload]),
    handleEvent: (name, fn) => { handlers[name] = fn },
  })
  hook.mounted()
  return hook
}

test("the Recent view chosen last time is asked for again on mount", () => {
  const hook = viewHook(storage({[VIEW_KEY]: "recent"}))
  assert.deepEqual(hook.pushed, [["tree_view", {view: "recent"}]])
})

test("with nothing saved, or storage refused, the tree stays and nothing is asked", () => {
  for (const store of [storage(), storage({[VIEW_KEY]: "nonsense"}), brokenStorage]) {
    assert.deepEqual(viewHook(store).pushed, [])
  }
})

test("the server's word on the view is what is kept, and the tree is kept as nothing", () => {
  const store = storage()
  const hook = viewHook(store)
  hook.handlers["wiki-tree:view"]({view: "recent"})
  assert.equal(store.items[VIEW_KEY], "recent")
  hook.handlers["wiki-tree:view"]({view: "tree"})
  assert.equal(store.items[VIEW_KEY], undefined)
  // A storage that throws loses the choice, not the page.
  viewHook(brokenStorage).handlers["wiki-tree:view"]({view: "recent"})
})
