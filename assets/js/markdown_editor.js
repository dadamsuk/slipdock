// The Markdown editor for wiki pages, card descriptions and comments:
// CodeMirror 6 with atomic-editor's Obsidian-style live preview, so a line
// shows rendered until the caret is on it, and then shows its Markdown.
//
// The textarea stays. It is still the form's field — phx-change, the
// debounce, the submit and the hooks around it (PasteImage, Mention,
// MeldEditor) all keep talking to it — and is only hidden once the editor is
// up. The two are kept in step both ways:
//
//   - every edit in the editor is written into the textarea, caret and all,
//     followed by an "input" event, as typing into the textarea would send;
//   - an "input" event someone else raises on the textarea (an image's
//     placeholder, a picked @mention, a block encrypted) is the textarea
//     having changed under the editor, and is copied into it.
//
// The hook sits on a phx-update="ignore" wrapper round the textarea, so a
// LiveView patch never resets the field under the editor; a field whose text
// the server means to replace is given a new id instead, and so a new editor.

import {mount, EditorSelection} from "../vendor/codemirror.js"

// The smallest change that turns `from` into `to`, as a CodeMirror change:
// what the two share at each end is left alone, so the caret, the undo
// history and the live preview of the rest of the document are untouched.
export function diff(from, to) {
  if (from === to) return null
  const max = Math.min(from.length, to.length)
  let start = 0
  while (start < max && from.charCodeAt(start) === to.charCodeAt(start)) start++
  let end = 0
  while (end < max - start && from.charCodeAt(from.length - 1 - end) === to.charCodeAt(to.length - 1 - end)) end++
  return {from: start, to: from.length - end, insert: to.slice(start, to.length - end)}
}

// A selection within a document of `length`, for positions a textarea gave.
export function selectionFor(length, start, end) {
  const clamp = n => Math.max(0, Math.min(Number.isFinite(n) ? n : length, length))
  return EditorSelection.single(clamp(start), clamp(end ?? start))
}

// The transaction that brings the editor's `state` up to the textarea's
// `value`, with the textarea's selection; null if they already agree.
export function catchUp(state, value, start, end) {
  const change = diff(state.doc.toString(), value)
  const selection = selectionFor(value.length, start, end)
  if (!change && state.selection.main.eq(selection.main)) return null
  return change ? {changes: change, selection} : {selection}
}

// The key events the textarea's own phx-keydown answers (Escape stops
// editing a card's description). LiveView only hears a key binding from the
// element that has it, and the keys now land in the editor, so they are
// handed back to the textarea.
export function forwardedKey(textarea, key) {
  if (!textarea.getAttribute("phx-keydown")) return false
  const wanted = textarea.getAttribute("phx-key")
  return !wanted || wanted.toLowerCase() === key.toLowerCase()
}

function keyEvent(key) {
  const Kind = globalThis.KeyboardEvent || Event
  const event = new Kind("keydown", {key, bubbles: true, cancelable: true})
  if (event.key !== key) Object.defineProperty(event, "key", {value: key})
  return event
}

// Links in the editor open in a new tab; a link to the board's own pages
// would be a navigation away from unsaved text.
function openLink(url) {
  try {
    window.open(url, "_blank", "noopener,noreferrer")
  } catch (_e) {}
}

export const MarkdownEditor = {
  mounted() {
    const ta = this.el.querySelector("textarea")
    if (!ta) return
    this.textarea = ta
    this.echoing = false

    const host = document.createElement("div")
    host.className = ["md-editor", this.el.dataset.editorClass].filter(Boolean).join(" ")
    ta.insertAdjacentElement("afterend", host)
    this.host = host

    const make = this.mountEditor || mount
    this.view = make(host, {
      doc: ta.value,
      anchor: ta.value.length,
      placeholder: ta.getAttribute("placeholder") || "",
      onChange: (text, update) => this.edited(text, update.state.selection.main),
      onSelect: range => this.selected(range),
      onLinkClick: openLink,
      readOnly: ta.matches?.(":disabled") || false,
      keys: key => this.key(key),
    })

    ta.hidden = true
    ta.markdownEditor = this

    // Whatever focused the textarea now focuses the editor: Mention and
    // MeldEditor call focus() after changing the text, and a label for the
    // field should still put the caret in it.
    ta.focus = () => this.view.focus()
    this.onLabel = e => {
      if (e.target.closest?.("label")?.htmlFor === ta.id && ta.id) {
        e.preventDefault()
        this.view.focus()
      }
    }
    document.addEventListener("click", this.onLabel)

    this.onInput = () => {
      if (!this.echoing) this.pull()
    }
    ta.addEventListener("input", this.onInput)

    // A required field that is empty stops the form; the browser would point
    // at the hidden textarea, so the editor is pointed at instead.
    this.onInvalid = e => {
      e.preventDefault()
      this.view.focus()
    }
    ta.addEventListener("invalid", this.onInvalid)

    if (ta.hasAttribute("autofocus")) this.view.focus()
  },

  destroyed() {
    document.removeEventListener("click", this.onLabel)
    this.view?.destroy()
  },

  // An edit in the editor: into the textarea, then told about as typing is.
  edited(text, range) {
    const ta = this.textarea
    ta.value = text
    this.selected(range)
    this.echoing = true
    try {
      ta.dispatchEvent(new Event("input", {bubbles: true}))
    } finally {
      this.echoing = false
    }
  },

  selected(range) {
    try {
      this.textarea.setSelectionRange(range.from, range.to, range.head < range.anchor ? "backward" : "forward")
    } catch (_e) {}
  },

  // The textarea changed under the editor; take its text and caret.
  pull() {
    const ta = this.textarea
    const spec = catchUp(this.view.state, ta.value, ta.selectionStart, ta.selectionEnd)
    if (spec) this.view.dispatch({...spec, scrollIntoView: true})
  },

  key(key) {
    if (!forwardedKey(this.textarea, key)) return false
    this.textarea.dispatchEvent(keyEvent(key))
    return true
  },

  // Where the caret is on screen, for a menu that opens beside it (Mention).
  caretRect() {
    const head = this.view.state.selection.main.head
    return this.view.coordsAtPos(head) || this.host.getBoundingClientRect()
  },
}
