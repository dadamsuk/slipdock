// Typing [[ in a Markdown editor (a wiki page, a card's description, a
// comment) opens a picker of the wiki's pages (#1302): the ones changed most
// lately at first, then whatever matches what follows the brackets — a
// title, a folder, or a code like W-31. The server does the matching
// (SlipdockWeb.PageLinkHook) and says what link to write for each page.
// The list is a caretMenu (caret_menu.js), as the @mention list is.
import {caretMenu} from "./caret_menu.js"

// The `[[word` the caret is at the end of: where the brackets start, and the
// word. Null once the link is closed, the line ends, or a `|` or `#` shows
// the link is being given a label or an anchor by hand.
export function linkQuery(text, caret) {
  const upto = text.slice(0, caret)
  const m = upto.match(/\[\[([^\[\]\n|#]{0,80})$/)
  return m ? {start: upto.length - m[1].length - 2, text: m[1]} : null
}

// `text` with the link written over the `[[word` from `start` to `caret`,
// and the caret after it. Closing brackets the editor already put after the
// caret are taken in, so the link is not left with a spare `]]`.
export function applyLink(text, start, caret, insert) {
  const after = text.slice(caret)
  const closing = after.startsWith("]]") ? 2 : after.startsWith("]") ? 1 : 0
  const value = text.slice(0, start) + insert + after.slice(closing)
  return {value, caret: start + insert.length}
}

export function renderPage(p, a) {
  a.className = "flex items-center gap-2"
  const text = document.createElement("span")
  text.className = "min-w-0 flex-1"
  const title = document.createElement("span")
  title.className = "block truncate"
  title.textContent = p.title
  text.appendChild(title)
  if (p.path) {
    const path = document.createElement("span")
    path.className = "block truncate text-xs opacity-60"
    path.textContent = p.path
    text.appendChild(path)
  }
  const code = document.createElement("span")
  code.className = "shrink-0 font-mono text-xs opacity-60"
  code.textContent = p.code
  a.append(text, code)
}

// A new [[ gathers the pages afresh; the rest of its word reuses them.
export function suggestPages(hook, q, {fresh}) {
  return new Promise(resolve =>
    hook.pushEvent("page_link_suggest", {q: q.text, board: hook.el.dataset.board || "", fresh},
      reply => resolve((reply && reply.pages) || [])))
}

export const PageLink = caretMenu({
  query: linkQuery,
  fetch: suggestPages,
  renderRow: renderPage,
  apply: (text, start, caret, page) => applyLink(text, start, caret, page.insert),
  width: 320,
  dataset: {pageLinkMenu: ""},
})
