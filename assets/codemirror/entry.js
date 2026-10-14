// CodeMirror 6 with atomic-editor's Obsidian-style live preview: Markdown
// is shown rendered on every line except the ones being edited, which show
// their source. Built by build.sh into assets/vendor/codemirror.js, never by
// the app's own esbuild; assets/js/markdown_editor.js is what uses it.
import {EditorSelection, EditorState} from "@codemirror/state"
import {
  EditorView, drawSelection, dropCursor, highlightSpecialChars, keymap, placeholder as placeholderText,
} from "@codemirror/view"
import {defaultKeymap, history, historyKeymap, indentWithTab} from "@codemirror/commands"
import {indentOnInput, syntaxTree} from "@codemirror/language"
import {closeBrackets, closeBracketsKeymap} from "@codemirror/autocomplete"
import {search, searchKeymap} from "@codemirror/search"
import {markdown, markdownKeymap, markdownLanguage} from "@codemirror/lang-markdown"
import {
  atomicEditorTheme, atomicMarkdownSyntax, autoCloseCodeFence, extendEmphasisPair, highlightMarkdown,
  imageBlocks, inlinePreview, startAsteriskList, tables,
} from "@atomic-editor/editor"

export {EditorSelection, EditorState, EditorView, syntaxTree}

// The extensions every Slipdock Markdown field gets. `onChange` hears the
// whole document after each edit, `onSelect` the main selection after each
// move. `keys` is offered Escape before the editor's own bindings, and
// returns true if it took it. `extra` is appended last.
export function extensions({
  placeholder = "", onChange, onSelect, onLinkClick, keys, readOnly = false, extra = [],
} = {}) {
  return [
    // Before the keymaps, and stopped here when taken: a key handed back to
    // the page must not also reach the page's window-wide bindings (Escape
    // closing the card the description is being written in).
    keys ? EditorView.domEventHandlers({
      keydown(event) {
        if (event.key !== "Escape" || !keys(event.key)) return false
        event.preventDefault()
        event.stopPropagation()
        return true
      },
    }) : [],
    readOnly ? [EditorState.readOnly.of(true), EditorView.editable.of(false)] : [],
    highlightSpecialChars(),
    history(),
    drawSelection(),
    dropCursor(),
    indentOnInput(),
    closeBrackets(),
    startAsteriskList,
    extendEmphasisPair,
    autoCloseCodeFence,
    EditorView.lineWrapping,
    search({top: true}),
    markdown({base: markdownLanguage, extensions: highlightMarkdown, completeHTMLTags: false}),
    markdownLanguage.data.of({closeBrackets: {brackets: ["(", "[", "{", "\"", "`"]}}),
    atomicMarkdownSyntax,
    atomicEditorTheme,
    keymap.of([
      ...closeBracketsKeymap,
      ...historyKeymap,
      ...searchKeymap,
      ...markdownKeymap,
      indentWithTab,
      ...defaultKeymap,
    ]),
    tables({onLinkClick}),
    imageBlocks(),
    inlinePreview({onLinkClick}),
    placeholder ? placeholderText(placeholder) : [],
    EditorView.updateListener.of(update => {
      if (update.docChanged && onChange) onChange(update.state.doc.toString(), update)
      if ((update.docChanged || update.selectionSet) && onSelect) onSelect(update.state.selection.main, update)
    }),
    ...extra,
  ]
}

// An editor in `parent` holding `doc`, with the caret at `anchor`..`head`.
export function mount(parent, {doc = "", anchor = 0, head = anchor, ...options} = {}) {
  const length = doc.length
  const clamp = n => Math.max(0, Math.min(n, length))
  parent.classList.add("atomic-cm-editor")
  return new EditorView({
    parent,
    state: EditorState.create({
      doc,
      selection: EditorSelection.single(clamp(anchor), clamp(head)),
      extensions: extensions(options),
    }),
  })
}
