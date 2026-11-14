// The controls a reader uses to shape a page's panes, for this browser
// (#2883): a handle dragged (or keyed) to make a pane wider or narrower, and
// a button that turns a layout on and off. Both keep the reader's choice in
// localStorage and put it on <html> (a CSS variable, an attribute), where
// LiveView's patches never reach, so theme.js can restore it before the first
// paint. The wiki's tree pane (wiki_pane.js) and the timeline's title column
// (timeline_labels.js) are configurations of these, so a fix to dragging or
// to the keys is made once.

// localStorage can throw (private windows, storage turned off); a preference
// that cannot be kept is still worth having for this visit. The store is the
// last argument, as storage.js (#2882) has it.
export function read(key, store) {
  try { return store.getItem(key) } catch (_e) { return null }
}

export function write(key, value, store) {
  try {
    if (value === null) store.removeItem(key)
    else store.setItem(key, value)
  } catch (_e) {}
}

// A width kept as the CSS variable `prop` on the root and under `key` in
// storage, between `min` and `max`, `def` when nothing is set.
export function widthPref({prop, key, min, max, def}) {
  const clamp = px => {
    const n = Math.round(Number(px))
    if (!Number.isFinite(n)) return def
    return Math.min(max, Math.max(min, n))
  }
  const set = (root, storage, px, {save = true} = {}) => {
    const width = clamp(px)
    root.style.setProperty(prop, `${width}px`)
    if (save) write(key, String(width), storage)
    return width
  }
  // Back to the width the pane started with.
  const reset = (root, storage) => {
    root.style.removeProperty(prop)
    write(key, null, storage)
    return def
  }
  const current = root => {
    const n = parseInt(root.style.getPropertyValue(prop), 10)
    return Number.isFinite(n) ? n : def
  }
  const saved = storage => {
    const kept = read(key, storage)
    return kept === null ? null : clamp(kept)
  }
  // What theme.js runs before the first paint: puts back a kept width, and
  // saves nothing itself.
  const restore = (root, storage) => {
    const width = saved(storage)
    if (width !== null) set(root, storage, width, {save: false})
  }
  return {prop, key, min, max, def, clamp, set, reset, current, saved, restore}
}

// A layout that is on or off: `attr="value"` on the root when on, "1" under
// `key` in storage.
export function rootFlag({attr, value, key}) {
  const is = root => root.getAttribute(attr) === value
  const set = (root, storage, on) => {
    if (on) root.setAttribute(attr, value)
    else root.removeAttribute(attr)
    write(key, on ? "1" : null, storage)
    return on
  }
  const restore = (root, storage) => {
    if (read(key, storage) === "1") root.setAttribute(attr, value)
  }
  return {attr, value, key, is, set, restore}
}

// The hook for a handle on a pane's edge, over a `widthPref`: drag it, or
// focus it and use the arrow keys (`step` a press; Home and End for the
// narrowest and widest); a double-click or Enter puts the width back. The
// width is shown live while dragging and saved on release.
//
// - `startWidth(hook)`: where a drag starts from (the variable's width by
//   default).
// - `onChange(hook)`: run after every change the handle makes.
// - `stopPropagation`: keep the press from reaching what is under the handle.
//
// The hook reads `this.root` and `this.storage` if they are set before it
// mounts (as the tests do), else <html> and localStorage.
export function resizeHandle({pref, step, startWidth, onChange = () => {}, stopPropagation = false}) {
  const from = startWidth || (hook => pref.current(hook.root))
  return {
    mounted() {
      this.root = this.root || document.documentElement
      this.storage = this.storage || localStorage
      this.el.setAttribute("aria-valuemin", String(pref.min))
      this.el.setAttribute("aria-valuemax", String(pref.max))
      this.announce(pref.current(this.root))

      const changed = width => {
        this.announce(width)
        onChange(this)
      }

      this.onDown = e => {
        if (e.button !== undefined && e.button !== 0) return
        e.preventDefault()
        if (stopPropagation) e.stopPropagation()
        this.drag = {x: e.clientX, start: from(this)}
        if (this.el.setPointerCapture && e.pointerId !== undefined) this.el.setPointerCapture(e.pointerId)
        this.el.setAttribute("data-dragging", "")
      }
      this.onMove = e => {
        if (!this.drag) return
        changed(pref.set(this.root, this.storage, this.drag.start + e.clientX - this.drag.x, {save: false}))
      }
      this.onUp = () => {
        if (!this.drag) return
        this.drag = null
        this.el.removeAttribute("data-dragging")
        changed(pref.set(this.root, this.storage, pref.current(this.root)))
      }
      this.onKey = e => {
        const now = pref.current(this.root)
        const to = {
          ArrowLeft: now - step,
          ArrowRight: now + step,
          Home: pref.min,
          End: pref.max,
        }[e.key]
        if (to !== undefined) {
          e.preventDefault()
          changed(pref.set(this.root, this.storage, to))
        } else if (e.key === "Enter") {
          e.preventDefault()
          changed(pref.reset(this.root, this.storage))
        }
      }
      this.onReset = () => changed(pref.reset(this.root, this.storage))

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
}

// The hook for a button that turns a `rootFlag` on and off, saying which on
// itself: `aria` is the state attribute it sets (`aria-pressed`, or
// `aria-expanded` with `invert` when on means hidden), and `titles` its
// title `{on, off}`. It sits in a `phx-update="ignore"` box, so what it sets
// stays set.
export function rootToggle({flag, aria, invert = false, titles}) {
  return {
    mounted() {
      this.root = this.root || document.documentElement
      this.storage = this.storage || localStorage
      this.sync()
      this.onClick = () => {
        flag.set(this.root, this.storage, !flag.is(this.root))
        this.sync()
      }
      this.el.addEventListener("click", this.onClick)
    },
    destroyed() {
      this.el.removeEventListener("click", this.onClick)
    },
    sync() {
      const on = flag.is(this.root)
      this.el.setAttribute(aria, String(invert ? !on : on))
      this.el.setAttribute("title", on ? titles.on : titles.off)
    },
  }
}
