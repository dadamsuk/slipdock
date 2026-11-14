// "Card from selection" on a wiki page (#3101): what of the selection may be
// sent to the server. Text decrypted in this browser (an open Meld block,
// `[data-meld-open]` holding a `.meld-plain`) never is: it is the only thing
// between that plaintext and a card description stored in the clear.

const PLAINTEXT = "[data-meld-open], .meld-plain"

// True when the range starts in, ends in or spans decrypted text.
export function touchesPlaintext(range) {
  const inside = node => (node.nodeType === 1 ? node : node.parentElement)?.closest("[data-meld-open]")
  return Boolean(inside(range.startContainer) || inside(range.endContainer) ||
    range.cloneContents().querySelector(PLAINTEXT))
}

// The selected text to make a card from, or null: nothing selected, a
// selection outside `el`, one touching decrypted text, or under 3 characters.
export function selectedText(el, sel) {
  if (!sel || sel.isCollapsed || sel.rangeCount === 0) return null
  const range = sel.getRangeAt(0)
  if (!el.contains(range.commonAncestorContainer)) return null
  if (touchesPlaintext(range)) return null
  const text = sel.toString().trim()
  return text.length > 2 ? text : null
}

// The button's press: sends the selection as `card_from_selection` through
// `push(event, payload)` when selectedText allows it. True when it sent.
export function sendSelection(el, sel, push) {
  const text = selectedText(el, sel)
  if (!text) return false
  push("card_from_selection", {text})
  return true
}
