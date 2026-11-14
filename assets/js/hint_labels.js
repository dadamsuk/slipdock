// The labels a board draws on its cards and lists for picking one from the
// keyboard, and what typing does to them. `BoardKeys` in app.js draws the
// labels and sends the pick; what is here touches no DOM.

// Labels, the way a Vim browser plugin does links: they favour the home keys,
// and only grow to pairs once the board shows more things than there are
// characters. The pairs reuse the home keys first in both positions, and the
// set stays prefix-free so no label swallows another.
export const HINT_CHARS = "asdfkjlghwertyuiopvbcnmxzq".split("")

export function hintLabels(count) {
  if (count <= HINT_CHARS.length) return HINT_CHARS.slice(0, count)
  const labels = [""]
  let offset = 0
  while (labels.length - offset < count) {
    const prefix = labels[offset++]
    for (const c of HINT_CHARS) labels.push(prefix + c)
  }
  return labels.slice(offset, offset + count)
}

// What a key does while the labels are up, given the labels and what has been
// typed so far: `{typed, remaining, picked}`. `remaining` is the labels still
// in the running, in their order, and `picked` the label the key completed
// (else null).
//
// A label's letter, in either case, is added when some label goes on that
// way, and picks the label once it is typed in full. Backspace takes the last
// letter back. A letter no label goes on with, and any other key, change
// nothing.
export function narrowHints(labels, typed, key) {
  const left = so => labels.filter(label => label.startsWith(so))
  const same = () => ({typed, remaining: left(typed), picked: null})

  if (key === "Backspace") {
    const back = typed.slice(0, -1)
    return {typed: back, remaining: left(back), picked: null}
  }
  if (!HINT_CHARS.includes(key.toLowerCase())) return same()

  const next = typed + key.toLowerCase()
  const remaining = left(next)
  if (!remaining.length) return same()
  const picked = remaining.length === 1 && remaining[0] === next ? next : null
  return {typed: next, remaining, picked}
}

// A key while a board's labels are up. `board` is BoardKeys as far as this
// goes: `hints` (each a `{label, id}`), `typed`, `paint()` to redraw what is
// left and `pick(id)` to act on a card or list. A key that completes a label
// picks its target; any other leaves `typed` as `narrowHints` says and
// redraws.
export function typeHint(board, key) {
  const {typed, picked} = narrowHints(board.hints.map(h => h.label), board.typed, key)
  board.typed = typed
  if (picked === null) return board.paint()
  board.pick(board.hints.find(h => h.label === picked).id)
}
