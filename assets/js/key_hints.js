// The card panel's key hints (#1728): each section heading marks the letter
// that jumps to it, and the mark is drawn only while Alt (Option) is held,
// as menu accelerators are. `data-show-keys` (on <html>, while a card is
// open) is the switch; app.css underlines `.keyed-key` under it.

// Whether the hints show after `event`, given whether they showed before:
// Alt pressed shows them, Alt let go hides them, anything else leaves them.
export function hintsAfter(event, showing) {
  if (event.key !== "Alt") return showing
  return event.type === "keydown"
}

// Watches the keyboard for `el` and returns the function that stops it.
export function installKeyHints(el, win = window) {
  let showing = false
  const set = on => {
    if (on === showing) return
    showing = on
    if (on) el.setAttribute("data-show-keys", "")
    else el.removeAttribute("data-show-keys")
  }
  const onKey = e => set(hintsAfter(e, showing))
  // A held Alt is never let go here if the window loses focus on it
  // (Alt-Tab), so losing focus hides them too.
  const onBlur = () => set(false)

  win.addEventListener("keydown", onKey, true)
  win.addEventListener("keyup", onKey, true)
  win.addEventListener("blur", onBlur)
  return () => {
    win.removeEventListener("keydown", onKey, true)
    win.removeEventListener("keyup", onKey, true)
    win.removeEventListener("blur", onBlur)
    set(false)
  }
}
