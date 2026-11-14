// A list that opens at the caret of a textarea as a word is typed: the
// @mention list (mention.js) and the [[page picker (page_link.js) are both
// built from it (#2884). Arrow keys pick (round the ends), Enter or Tab
// takes, Escape closes, and a click on a row takes it. The list lives on
// <body> so a LiveView patch of the form cannot take it away mid-word.
//
//   caretMenu({
//     query(text, caret)          -> {start, text} for the word at the caret, or null
//     fetch(hook, q, {fresh})     -> the rows, or a promise of them; `fresh` when
//                                    the word starts at a new place
//     renderRow(row, a)           -> fills the row's <a> (selection is done for you)
//     apply(text, start, caret, row) -> {value, caret}, the text once the row is taken
//     width                       -> the list's width in px
//     dataset                     -> data-* to put on the list, for tests and CSS
//   })
//
// returns a LiveView hook.

// Write `value` into the textarea with the caret at `caret`, and tell the
// form: its input event is what the Markdown editor and phx-change hear.
export function writeAt(textarea, value, caret) {
  textarea.value = value
  textarea.selectionStart = textarea.selectionEnd = caret
  textarea.dispatchEvent(new Event("input", {bubbles: true}))
}

const MARGIN = 8
const GAP = 4

// Where the list goes: under the caret, held on screen with a margin on the
// right and the bottom, never off the top or the left.
export function placeMenu(caret, size, view) {
  return {
    left: Math.max(0, Math.min(caret.left, view.width - size.width - MARGIN)),
    top: Math.max(0, Math.min(caret.bottom + GAP, view.height - size.height - MARGIN)),
  }
}

// The row after (or before) `selected`, round the ends.
export function step(selected, n, key) {
  return (selected + (key === "ArrowDown" ? 1 : n - 1)) % n
}

export function caretMenu({query, fetch, renderRow, apply, width, dataset = {}}) {
  return {
    mounted() {
      this.textarea = this.el.querySelector("textarea")
      if (!this.textarea) return
      this.menu = document.createElement("ul")
      this.menu.className = "menu menu-sm fixed z-[100] hidden rounded-box border border-base-300 bg-base-100 p-1 shadow-lg"
      this.menu.style.width = width + "px"
      Object.assign(this.menu.dataset, dataset)
      document.body.appendChild(this.menu)
      this.matches = []
      this.open = null
      this.asked = 0
      // Clicks and focus on the wrapper, so they are heard from the Markdown
      // editor over the textarea too; its edits arrive as the textarea's input.
      this.textarea.addEventListener("input", () => this.refresh())
      this.el.addEventListener("click", () => this.refresh())
      this.el.addEventListener("focusout", () => setTimeout(() => this.close(), 150))
      // On the wrapper, so a key the list uses never reaches the textarea's
      // own bindings (Escape there stops editing the description).
      this.el.addEventListener("keydown", e => this.key(e), true)
    },
    destroyed() { this.menu && this.menu.remove() },
    refresh() {
      const ta = this.textarea
      const q = query(ta.value, ta.selectionStart)
      if (!q) return this.close()
      const fresh = this.open !== q.start
      this.open = q.start
      this.at = q
      const asked = ++this.asked
      const show = rows => {
        // An answer to an older keystroke, or one after the list closed, is stale.
        if (asked !== this.asked || this.open === null) return
        this.matches = rows || []
        if (this.matches.length === 0) return this.hide()
        this.selected = 0
        this.render()
      }
      const rows = fetch(this, q, {fresh})
      if (rows && typeof rows.then === "function") rows.then(show)
      else show(rows)
    },
    render() {
      this.menu.replaceChildren(...this.matches.map((row, i) => {
        const li = document.createElement("li")
        const a = document.createElement("a")
        renderRow(row, a)
        if (i === this.selected) a.classList.add("menu-active")
        a.addEventListener("mousedown", e => { e.preventDefault(); this.take(row) })
        li.appendChild(a)
        return li
      }))
      this.menu.classList.remove("hidden")
      const r = this.textarea.markdownEditor?.caretRect() || this.textarea.getBoundingClientRect()
      const {left, top} = placeMenu(r, {width, height: this.menu.offsetHeight || 0},
        {width: window.innerWidth, height: window.innerHeight})
      this.menu.style.left = left + "px"
      this.menu.style.top = top + "px"
    },
    hide() { this.matches = []; this.menu && this.menu.classList.add("hidden") },
    close() { this.open = null; this.hide() },
    key(e) {
      if (this.matches.length === 0) return
      if (e.key === "ArrowDown" || e.key === "ArrowUp") {
        this.selected = step(this.selected, this.matches.length, e.key)
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
    // Closed before the write, so the refresh its input event starts has the
    // last word: the list opens again only if what was written leaves a word
    // at the caret.
    take(row) {
      const ta = this.textarea
      const {value, caret} = apply(ta.value, this.at.start, ta.selectionStart, row)
      this.close()
      writeAt(ta, value, caret)
      ta.focus()
    },
  }
}
