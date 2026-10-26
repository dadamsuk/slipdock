// Typing [[ in a Markdown editor (a wiki page, a card's description, a
// comment) opens a picker of the wiki's pages (#1302): the ones changed most
// lately at first, then whatever matches what follows the brackets — a
// title, a folder, or a code like W-31. The server does the matching
// (SlipdockWeb.PageLinkHook) and says what link to write for each page.
// Arrow keys pick, Enter or Tab takes, Escape closes, as the @mention list
// does. The list lives on <body> so a LiveView patch cannot take it away.

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

export const PageLink = {
  mounted() {
    this.textarea = this.el.querySelector("textarea")
    if (!this.textarea) return
    this.menu = document.createElement("ul")
    this.menu.className = "menu menu-sm fixed z-[100] hidden w-80 rounded-box border border-base-300 bg-base-100 p-1 shadow-lg"
    this.menu.dataset.pageLinkMenu = ""
    document.body.appendChild(this.menu)
    this.matches = []
    this.open = null
    this.asked = 0
    this.textarea.addEventListener("input", () => this.refresh())
    this.el.addEventListener("click", () => this.refresh())
    this.el.addEventListener("focusout", () => setTimeout(() => this.close(), 150))
    this.el.addEventListener("keydown", e => this.key(e), true)
  },
  destroyed() { this.menu && this.menu.remove() },
  refresh() {
    const ta = this.textarea
    const q = linkQuery(ta.value, ta.selectionStart)
    if (!q) return this.close()
    // A new [[ gathers the pages afresh; the rest of its word reuses them.
    const fresh = this.open === null || this.open !== q.start
    this.open = q.start
    this.at = q
    const asked = ++this.asked
    this.pushEvent("page_link_suggest", {q: q.text, board: this.el.dataset.board || "", fresh}, reply => {
      // An answer to an older keystroke is stale.
      if (asked !== this.asked || this.open === null) return
      this.matches = (reply && reply.pages) || []
      if (this.matches.length === 0) return this.hide()
      this.selected = 0
      this.render()
    })
  },
  render() {
    this.menu.replaceChildren(...this.matches.map((p, i) => {
      const li = document.createElement("li")
      const a = document.createElement("a")
      a.className = "flex items-center gap-2"
      if (i === this.selected) a.classList.add("menu-active")
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
      a.addEventListener("mousedown", e => { e.preventDefault(); this.take(p) })
      li.appendChild(a)
      return li
    }))
    const r = this.textarea.markdownEditor?.caretRect() || this.textarea.getBoundingClientRect()
    this.menu.style.left = Math.min(r.left, window.innerWidth - 328) + "px"
    this.menu.style.top = Math.min(r.bottom + 4, window.innerHeight - 360) + "px"
    this.menu.classList.remove("hidden")
  },
  hide() { this.matches = []; this.menu && this.menu.classList.add("hidden") },
  close() { this.open = null; this.hide() },
  key(e) {
    if (this.matches.length === 0) return
    if (e.key === "ArrowDown" || e.key === "ArrowUp") {
      const n = this.matches.length
      this.selected = (this.selected + (e.key === "ArrowDown" ? 1 : n - 1)) % n
      this.render()
    } else if (e.key === "Enter" || e.key === "Tab") {
      this.take(this.matches[this.selected])
    } else if (e.key === "Escape") {
      this.close()
    } else {
      return
    }
    e.preventDefault()
    e.stopPropagation()
  },
  take(page) {
    const ta = this.textarea
    const {value, caret} = applyLink(ta.value, this.at.start, ta.selectionStart, page.insert)
    ta.value = value
    ta.selectionStart = ta.selectionEnd = caret
    this.close()
    ta.dispatchEvent(new Event("input", {bubbles: true}))
    ta.focus()
  },
}
