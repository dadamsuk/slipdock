// node --test assets/js — the Markdown editor's bridge to its textarea. The
// editor is a real CodeMirror state behind a fake view (no DOM here), and the
// textarea, wrapper and document are faked down to what the hook touches.
import {test} from "node:test"
import assert from "node:assert/strict"
import {EditorState} from "../vendor/codemirror.js"
import {MarkdownEditor, catchUp, diff, forwardedKey, insertion, selectionFor} from "./markdown_editor.js"

function textarea({value = "", attrs = {}, disabled = false} = {}) {
  const listeners = {}
  const ta = {
    value, attrs, hidden: false, id: attrs.id || "",
    selectionStart: value.length, selectionEnd: value.length, selectionDirection: "none",
    events: [],
    getAttribute: k => (k in attrs ? attrs[k] : null),
    hasAttribute: k => k in attrs,
    matches: sel => sel === ":disabled" && disabled,
    setSelectionRange(start, end, dir) {
      this.selectionStart = start
      this.selectionEnd = end
      this.selectionDirection = dir
    },
    addEventListener: (t, fn) => { (listeners[t] ||= []).push(fn) },
    dispatchEvent(e) {
      ta.events.push(e)
      for (const fn of listeners[e.type] || []) fn(e)
      return true
    },
    insertAdjacentElement(_where, el) { ta.after = el },
  }
  return ta
}

// A view over a real EditorState: dispatch applies the spec and reports it
// the way the editor's update listener does.
function fakeMount(log) {
  return (host, options) => {
    log.options = options
    log.host = host
    const view = {
      state: EditorState.create({doc: options.doc, selection: {anchor: options.anchor}}),
      focused: 0,
      destroyed: false,
      dispatch(spec) {
        const tr = this.state.update(spec)
        this.state = tr.state
        log.dispatched.push(spec)
      },
      focus() { this.focused++ },
      destroy() { this.destroyed = true },
      coordsAtPos: pos => ({left: pos, right: pos, top: 10, bottom: 20}),
      // What typing into the editor does: change the state, then tell the hook.
      type(spec) {
        const tr = this.state.update(spec)
        this.state = tr.state
        options.onChange(tr.state.doc.toString(), {state: tr.state})
      },
    }
    log.view = view
    return view
  }
}

function setup(taOpts = {}) {
  const documentListeners = {}
  globalThis.document = {
    createElement: () => ({className: "", getBoundingClientRect: () => ({left: 1, bottom: 2})}),
    addEventListener: (t, fn) => { documentListeners[t] = fn },
    removeEventListener: t => { delete documentListeners[t] },
  }
  const ta = textarea(taOpts)
  const log = {dispatched: []}
  const hook = Object.create(MarkdownEditor)
  hook.el = {dataset: {editorClass: "md-editor-field"}, querySelector: () => ta}
  hook.mountEditor = fakeMount(log)
  hook.handleEvent = (name, fn) => { log[name] = fn }
  hook.mounted()
  return {hook, ta, log, documentListeners}
}

test("diff keeps what the two texts share at each end", () => {
  assert.equal(diff("same", "same"), null)
  assert.deepEqual(diff("hello world", "hello brave world"), {from: 6, to: 6, insert: "brave "})
  assert.deepEqual(diff("abc", ""), {from: 0, to: 3, insert: ""})
  assert.deepEqual(diff("", "abc"), {from: 0, to: 0, insert: "abc"})
  // A repeated letter is not counted twice from both ends.
  assert.deepEqual(diff("aa", "aaa"), {from: 2, to: 2, insert: "a"})
  assert.deepEqual(diff("x ![Uploading image…]() y", "x ![a](/i.png) y"),
    {from: 4, to: 22, insert: "a](/i.png"})
})

test("diff applied to the first text gives the second", () => {
  const pairs = [["", ""], ["abc", "abd"], ["abcabc", "abc"], ["one\ntwo", "one\nthree\ntwo"], ["ab", "ba"]]
  for (const [a, b] of pairs) {
    const c = diff(a, b)
    const out = c ? a.slice(0, c.from) + c.insert + a.slice(c.to) : a
    assert.equal(out, b, `${JSON.stringify(a)} -> ${JSON.stringify(b)}`)
  }
})

test("a textarea's selection is clamped to the document", () => {
  assert.deepEqual([selectionFor(5, 2, 4).main.from, selectionFor(5, 2, 4).main.to], [2, 4])
  assert.equal(selectionFor(5, 99, 99).main.head, 5)
  assert.equal(selectionFor(5, -3).main.head, 0)
  assert.equal(selectionFor(5, undefined).main.head, 5)
})

test("catchUp is nothing when the editor already agrees", () => {
  const state = EditorState.create({doc: "abc", selection: {anchor: 1}})
  assert.equal(catchUp(state, "abc", 1, 1), null)
  assert.deepEqual(catchUp(state, "abc", 3, 3).changes, undefined)
  const spec = catchUp(state, "abXc", 3, 3)
  const next = state.update(spec).state
  assert.equal(next.doc.toString(), "abXc")
  assert.equal(next.selection.main.head, 3)
})

test("only keys the textarea's phx-keydown answers are handed back", () => {
  assert.equal(forwardedKey(textarea(), "Escape"), false)
  const esc = textarea({attrs: {"phx-keydown": "stop", "phx-key": "Escape"}})
  assert.equal(forwardedKey(esc, "Escape"), true)
  assert.equal(forwardedKey(esc, "escape"), true)
  assert.equal(forwardedKey(esc, "Enter"), false)
  assert.equal(forwardedKey(textarea({attrs: {"phx-keydown": "any"}}), "Enter"), true)
})

test("mounting starts the editor on the textarea's text and hides the textarea", () => {
  const {ta, log} = setup({value: "# Title", attrs: {placeholder: "Add more detail…"}})
  assert.equal(log.options.doc, "# Title")
  assert.equal(log.options.anchor, 7)
  assert.equal(log.options.placeholder, "Add more detail…")
  assert.equal(log.options.readOnly, false)
  assert.equal(log.host.className, "md-editor md-editor-field")
  assert.equal(ta.after, log.host)
  assert.equal(ta.hidden, true)
  assert.equal(log.view.focused, 0)
})

test("an autofocus field puts the caret in the editor; a disabled one is read-only", () => {
  assert.equal(setup({attrs: {autofocus: ""}}).log.view.focused, 1)
  assert.equal(setup({disabled: true}).log.options.readOnly, true)
})

test("typing in the editor writes the textarea and raises one input event", () => {
  const {ta, log} = setup({value: "hi"})
  log.view.type({changes: {from: 2, insert: " @an"}, selection: {anchor: 6}})
  assert.equal(ta.value, "hi @an")
  assert.equal(ta.selectionStart, 6)
  assert.equal(ta.selectionEnd, 6)
  assert.deepEqual(ta.events.map(e => [e.type, e.bubbles]), [["input", true]])
  // The echo is not taken for the textarea changing under the editor.
  assert.equal(log.dispatched.length, 0)
})

test("the caret is mirrored before the input event, for Mention to read", () => {
  const {ta, log} = setup({value: ""})
  let seen = null
  ta.addEventListener("input", () => { seen = ta.selectionStart })
  log.view.type({changes: {from: 0, insert: "@a"}, selection: {anchor: 2}})
  assert.equal(seen, 2)
})

test("a backward selection is mirrored backward", () => {
  const {hook, ta} = setup({value: "abcdef"})
  hook.selected({from: 1, to: 4, anchor: 4, head: 1})
  assert.deepEqual([ta.selectionStart, ta.selectionEnd, ta.selectionDirection], [1, 4, "backward"])
})

test("another hook changing the textarea is copied into the editor, caret and all", () => {
  const {ta, log} = setup({value: "before after"})
  ta.value = "before ![Uploading image…]()\n after"
  ta.selectionStart = ta.selectionEnd = 29
  ta.dispatchEvent(new Event("input", {bubbles: true}))
  assert.equal(log.view.state.doc.toString(), "before ![Uploading image…]()\n after")
  assert.equal(log.view.state.selection.main.head, 29)
  assert.deepEqual(log.dispatched[0].changes, {from: 7, to: 7, insert: "![Uploading image…]()\n "})
  assert.equal(log.dispatched[0].scrollIntoView, true)
})

test("an input event that changes nothing dispatches nothing", () => {
  const {ta, log} = setup({value: "same"})
  ta.dispatchEvent(new Event("input", {bubbles: true}))
  assert.equal(log.dispatched.length, 0)
})

test("focusing the textarea focuses the editor", () => {
  const {ta, log} = setup()
  ta.focus()
  assert.equal(log.view.focused, 1)
})

test("an empty required field points at the editor instead of the hidden textarea", () => {
  const {ta, log} = setup()
  const e = new Event("invalid", {cancelable: true})
  ta.dispatchEvent(e)
  assert.equal(e.defaultPrevented, true)
  assert.equal(log.view.focused, 1)
})

test("a click on the field's label focuses the editor; other labels are left alone", () => {
  const {log, documentListeners} = setup({attrs: {id: "page_body"}})
  const click = htmlFor => {
    const e = {prevented: false, preventDefault() { this.prevented = true },
      target: {closest: () => (htmlFor === null ? null : {htmlFor})}}
    documentListeners.click(e)
    return e.prevented
  }
  assert.equal(click("page_body"), true)
  assert.equal(click("other"), false)
  assert.equal(click(null), false)
  assert.equal(log.view.focused, 1)
})

test("Escape goes back to the textarea when its phx-keydown wants it", () => {
  const {ta, log} = setup({attrs: {"phx-keydown": "stop_editing_description", "phx-key": "Escape"}})
  assert.equal(log.options.keys("Escape"), true)
  const sent = ta.events.at(-1)
  assert.equal(sent.type, "keydown")
  assert.equal(sent.key, "Escape")
  assert.equal(sent.bubbles, true)
})

test("Escape is left to the editor when the textarea has no use for it", () => {
  const {ta, log} = setup()
  assert.equal(log.options.keys("Escape"), false)
  assert.equal(ta.events.length, 0)
})

test("the caret's place on screen is the editor's", () => {
  const {hook, log} = setup({value: "abc"})
  assert.deepEqual(hook.caretRect(), log.view.coordsAtPos(3))
  log.view.coordsAtPos = () => null
  assert.deepEqual(hook.caretRect(), {left: 1, bottom: 2})
})

test("destroying the hook takes the editor and its document listener down", () => {
  const {hook, log, documentListeners} = setup()
  hook.destroyed()
  assert.equal(log.view.destroyed, true)
  assert.equal(documentListeners.click, undefined)
})

test("a wrapper without a textarea is left alone", () => {
  const hook = Object.create(MarkdownEditor)
  hook.el = {dataset: {}, querySelector: () => null}
  hook.mounted()
  assert.equal(hook.view, undefined)
  hook.destroyed()
})

test("insertion makes a paragraph of its own, wherever the caret is", () => {
  assert.deepEqual(insertion("", 0, "Hi"), {changes: {from: 0, insert: "Hi\n"}, selection: {anchor: 3}})
  assert.equal(insertion("Words", 5, "Hi").changes.insert, "\n\nHi\n")
  assert.equal(insertion("Words\n", 6, "Hi").changes.insert, "\nHi\n")
  assert.equal(insertion("Words\n\n", 7, "Hi").changes.insert, "Hi\n")
  assert.equal(insertion("Words", 5, "Hi").selection.anchor, 5 + "\n\nHi\n".length)
})

test("only the page editor takes text from the AI tools", () => {
  assert.equal(setup({attrs: {id: "comment_body"}}).log["wiki-editor:insert"], undefined)
  assert.equal(typeof setup({attrs: {id: "page_body"}}).log["wiki-editor:insert"], "function")
})
