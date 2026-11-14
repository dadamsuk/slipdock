// <.date_field> (core_components.ex, #1720): a date written the app's way
// ("18 Nov", or "Add date") over a hidden native <input type="date">.
//
// The native input still carries the value: it is what the form posts and
// what fires phx-change. This hook only opens its picker (showPicker(), so
// the browser still does the calendar), clears it, and keeps the words in
// step with it. Where showPicker() is missing, the wrapper gets
// data-native and the plain input is shown instead (app.css). Typing a
// digit on the display hands the keys to the native input, so a date can
// still be typed where the browser allows it.

import {localDay, short} from "./relative_time.js"

// "2026-11-18" -> "18 Nov", with the year when it isn't this one: the same
// words SlipdockWeb.Dates.short/2 writes on the server (#2881). This year is
// the one `today` falls in in `zone`, the viewer's timezone the server wrote
// into `data-zone`, not the browser's: around New Year the two can differ.
export function formatShort(iso, today = new Date(), zone = "UTC") {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(iso || "")
  if (!m) return null
  const [year, month, day] = [Number(m[1]), Number(m[2]), Number(m[3])]
  if (month < 1 || month > 12 || day < 1 || day > 31) return null
  return short({year, month, day}, localDay(today, zone))
}

export function canShowPicker(input) {
  return !!input && typeof input.showPicker === "function"
}

// Opens the picker; false when the browser can't (no showPicker, or it threw
// because the input is disabled or the call wasn't from a user gesture).
export function openPicker(input) {
  if (!canShowPicker(input) || input.disabled || input.readOnly) return false
  try {
    input.showPicker()
    return true
  } catch (_e) {
    return false
  }
}

// What a key on the display does: "open" (Enter, Space, Alt+Down), "type"
// (a digit: the native input takes over), or null.
export function keyAction(e) {
  if (e.key === "Enter" || e.key === " " || (e.altKey && e.key === "ArrowDown")) return "open"
  if (/^[0-9]$/.test(e.key) && !e.ctrlKey && !e.metaKey && !e.altKey) return "type"
  return null
}

function fire(input, type) {
  input.dispatchEvent(new Event(type, {bubbles: true}))
}

// Empties the input and tells the form, as a pick would.
export function clear(input) {
  if (input.value === "") return false
  input.value = ""
  fire(input, "input")
  fire(input, "change")
  return true
}

// Puts the words on the display and the empty/filled state on the wrapper.
export function sync(el, today = new Date()) {
  const input = el.querySelector("input[type=date]")
  const text = el.querySelector("[data-role=date-text]")
  const clearBtn = el.querySelector("[data-role=date-clear]")
  if (!input || !text) return
  const words = formatShort(input.value, today, el.dataset.zone || "UTC")
  text.textContent = words || el.dataset.placeholder || "Add date"
  if (words) el.removeAttribute("data-empty")
  else el.setAttribute("data-empty", "")
  if (clearBtn) clearBtn.hidden = !words
}

export const DateField = {
  mounted() {
    this.input = this.el.querySelector("input[type=date]")
    this.display = this.el.querySelector("[data-role=date-display]")
    if (!this.input || !this.display) return

    if (!canShowPicker(this.input)) {
      this.el.setAttribute("data-native", "")
      return
    }

    this.onClick = e => {
      e.preventDefault()
      if (!openPicker(this.input)) this.showNative()
    }
    this.onKeydown = e => {
      const action = keyAction(e)
      if (action === "open") {
        e.preventDefault()
        if (!openPicker(this.input)) this.showNative()
      } else if (action === "type") {
        this.showNative()
      }
    }
    this.onChange = () => sync(this.el)
    this.onBlur = () => this.el.removeAttribute("data-typing")
    this.onClear = e => {
      if (!e.target.closest("[data-role=date-clear]")) return
      e.preventDefault()
      clear(this.input)
      sync(this.el)
      this.display.focus()
    }

    this.display.addEventListener("click", this.onClick)
    this.display.addEventListener("keydown", this.onKeydown)
    this.input.addEventListener("input", this.onChange)
    this.input.addEventListener("change", this.onChange)
    this.input.addEventListener("blur", this.onBlur)
    this.el.addEventListener("click", this.onClear)
    sync(this.el)
  },

  // A patch may have set a new value (or put the old one back): follow it.
  updated() {
    this.input = this.el.querySelector("input[type=date]")
    if (this.input) sync(this.el)
  },

  // The native input, shown and focused: for typing, or where the picker
  // can't be opened.
  showNative() {
    this.el.setAttribute("data-typing", "")
    this.input.focus()
  },

  destroyed() {
    if (!this.display || !this.onClick) return
    this.display.removeEventListener("click", this.onClick)
    this.display.removeEventListener("keydown", this.onKeydown)
    this.el.removeEventListener("click", this.onClear)
  },
}
