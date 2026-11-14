// Is the user typing into something, rather than at the page?
//
// True for somewhere keys are being typed into (a field, a select, anything
// contentEditable), and for a widget that takes the keyboard for itself while
// it has focus (the wiki's tree, marked data-own-keys). Every page-wide
// shortcut stands down for it, so this is the one copy: a listener on the
// document or the window asks here rather than writing the test again.
//
// With no argument it asks about whatever holds the focus; a key handler that
// has the event can pass its target.
const FIELDS = ["input", "textarea", "select"]

export function typing(el = document.activeElement) {
  if (!el) return false
  const tag = String(el.tagName || "").toLowerCase()
  return (
    el.isContentEditable === true ||
    FIELDS.includes(tag) ||
    !!(typeof el.closest === "function" && el.closest("[data-own-keys]"))
  )
}
