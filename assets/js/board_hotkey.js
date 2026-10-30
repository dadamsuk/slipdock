// Board hotkeys (#1101): Ctrl-Shift and a digit opens the board given that
// digit in its settings. Cmd-Shift does on a Mac, and the number pad counts as
// well as the top row. The digit comes from the key itself (e.code), because
// Shift turns the character into "!" or "@" — or "£" — depending on layout.
//
// The digit as a string, or null for any other key.
export function boardHotkey(e) {
  if (!(e.ctrlKey || e.metaKey) || !e.shiftKey || e.altKey) return null
  const m = /^(?:Digit|Numpad)([0-9])$/.exec(e.code || "")
  return m ? m[1] : null
}

// Shift-Alt-S (#1533): search everything. It goes by the letter typed, as Ctrl-P
// and Ctrl-O do, so it follows the layout. Option on a Mac turns the letter into
// "Í", so anything that is not a plain letter falls back to the key itself.
// Ctrl is ruled out because AltGr reports as Ctrl-Alt.
export function searchHotkey(e) {
  if (!e.shiftKey || !e.altKey || e.ctrlKey || e.metaKey) return false
  const key = (e.key || "").toLowerCase()
  return /^[a-z]$/.test(key) ? key === "s" : e.code === "KeyS"
}
