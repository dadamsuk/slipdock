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
