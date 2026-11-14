// Typing @ in a card's description or a comment offers the board's members
// (data-people, from SlipdockWeb.Mention). The list is a caretMenu
// (caret_menu.js), as the [[page picker is.
import {caretMenu} from "./caret_menu.js"

// The "@word" the caret is at the end of: where the @ is, and the word in
// lower case. Not after a letter, a digit, another @ or a slash, so an email
// address or a path is left alone.
export function mentionQuery(text, caret) {
  const upto = text.slice(0, caret)
  const m = upto.match(/(^|[^\w@\/])@([\w.\-]{0,62})$/)
  return m ? {start: upto.length - m[2].length - 1, text: m[2].toLowerCase()} : null
}

// The people whose handle, email or any one of their names starts with the
// word, eight at most.
export function mentionMatches(people, word) {
  return people.filter(p =>
    [p.handle, p.email, ...(p.name || "").split(/\s+/)].some(w => w && w.toLowerCase().startsWith(word))
  ).slice(0, 8)
}

// `text` with "@handle " written over the "@word" from `start` to `caret`,
// and the caret after the space.
export function applyMention(text, start, caret, person) {
  const insert = "@" + person.handle + " "
  return {value: text.slice(0, start) + insert + text.slice(caret), caret: start + insert.length}
}

export function people(el) {
  try { return JSON.parse(el.dataset.people || "[]") } catch (_) { return [] }
}

export function renderPerson(p, a) {
  const name = document.createElement("span")
  name.textContent = p.name || p.email
  const handle = document.createElement("span")
  handle.className = "text-base-content/60"
  handle.textContent = "@" + p.handle
  a.append(name, handle)
}

export const Mention = caretMenu({
  query: mentionQuery,
  fetch: (hook, q) => mentionMatches(people(hook.el), q.text),
  renderRow: renderPerson,
  apply: applyMention,
  width: 256,
  dataset: {mentionMenu: ""},
})
