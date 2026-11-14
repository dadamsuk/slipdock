// The handful of DOM a caretMenu touches, for the node tests of the list
// itself (caret_menu.test.js) and of the hooks built on it (mention.test.js,
// page_link.test.js). No browser under `node --test`, so this stands in.
// Not a test file: node --test only runs *.test.js.

export function listeners() {
  const on = {}
  return {
    on,
    addEventListener: (type, fn) => { (on[type] ||= []).push(fn) },
    fire(type, e = {}) { (on[type] || []).forEach(fn => fn(e)) },
  }
}

export function element(tag) {
  const classes = new Set()
  const l = listeners()
  return {
    tag, children: [], dataset: {}, style: {}, textContent: "", offsetHeight: 0, removed: false,
    get className() { return [...classes].join(" ") },
    set className(v) { classes.clear(); v.split(/\s+/).filter(Boolean).forEach(c => classes.add(c)) },
    classList: {add: c => classes.add(c), remove: c => classes.delete(c), contains: c => classes.has(c)},
    ...l,
    appendChild(c) { this.children.push(c); return c },
    append(...cs) { this.children.push(...cs) },
    replaceChildren(...cs) { this.children = cs },
    remove() { this.removed = true },
  }
}

// A fresh document, window, Event and setTimeout; returns the body and the
// timers setTimeout was given, to run by hand.
export function fakeDom() {
  const body = element("body")
  const timers = []
  globalThis.document = {createElement: element, body}
  globalThis.window = {innerWidth: 1000, innerHeight: 800}
  globalThis.Event = class { constructor(type, o) { this.type = type; Object.assign(this, o) } }
  globalThis.setTimeout = fn => timers.push(fn)
  return {body, timers}
}

export function textarea(value, caret = value.length) {
  return {
    value, selectionStart: caret, selectionEnd: caret, sent: [], focused: 0,
    ...listeners(),
    dispatchEvent(e) { this.sent.push(e.type); this.fire(e.type, e) },
    focus() { this.focused++ },
    getBoundingClientRect: () => ({left: 100, bottom: 200}),
  }
}

// Mounts `hook` (a caretMenu) on a wrapper holding a textarea of `value`,
// with `extra` on the hook (a pushEvent, say) and `dataset` on the wrapper.
export function mountHook(hook, value, {dataset = {}, extra = {}, body} = {}) {
  const ta = textarea(value)
  const el = {...listeners(), dataset, querySelector: () => ta}
  const h = Object.assign(Object.create(null), hook, extra, {el})
  h.mounted()
  return {h, ta, el, menu: body && body.children[body.children.length - 1]}
}

// Sets the text and caret, as typing does, and sends the input event.
export function type(ta, value, caret = value.length) {
  ta.value = value
  ta.selectionStart = ta.selectionEnd = caret
  ta.fire("input")
}

export function key(k) {
  const e = {key: k, prevented: 0, stopped: 0}
  e.preventDefault = () => e.prevented++
  e.stopPropagation = () => e.stopped++
  return e
}

// Each row's link, and which one is picked.
export const links = menu => menu.children.map(li => li.children[0])
export const active = menu => links(menu).findIndex(a => a.classList.contains("menu-active"))
