// The text edits behind Hooks.PasteImage, as pure functions over a textarea's
// value and caret, so they can be tested without a browser. The hook in
// app.js reads the textarea, calls these, and writes the result back.

// Left at the cursor while an image uploads, and replaced by its Markdown.
export const PLACEHOLDER = "![Uploading image…]()"

// The image files among what was pasted or dropped; none when the textarea
// is disabled, so the paste is left to the browser.
export function imageFiles(files, disabled) {
  if (disabled) return []
  return Array.from(files || []).filter(f => (f.type || "").startsWith("image/"))
}

// Puts `text` in place of the selection, on a line of its own: a newline goes
// before it unless the text before the cursor already ends one. The caret
// goes after what was put in.
export function insertAtCursor(value, {start, end} = {}, text) {
  const from = start ?? value.length
  const to = end ?? from
  const before = value.slice(0, from)
  const pad = before.length > 0 && !before.endsWith("\n") ? "\n" : ""
  return {value: before + pad + text + value.slice(to), caret: from + pad.length + text.length}
}

// Swaps the first placeholder for `markdown`. An empty `markdown` (a failed
// upload) removes the placeholder and the newline it was given. A caret after
// the placeholder moves with the text; one before it stays. With the
// placeholder gone (the user deleted it meanwhile), the Markdown goes on a
// line of its own at the end, and a failure changes nothing.
export function replacePlaceholder(value, caret, markdown, placeholder = PLACEHOLDER) {
  const at = value.indexOf(placeholder)
  if (at >= 0) {
    const gone = placeholder.length + (!markdown && value[at + placeholder.length] === "\n" ? 1 : 0)
    const next = value.slice(0, at) + markdown + value.slice(at + gone)
    return {value: next, caret: caret > at ? caret + markdown.length - gone : caret}
  }
  if (!markdown) return {value, caret}
  const next = value.replace(/\s*$/, "") + (value.trim() ? "\n" : "") + markdown + "\n"
  return {value: next, caret: next.length}
}

// The name a pasted file is uploaded under. A clipboard image comes as
// "image.png" or "blob" (or nameless), so it gets a dated name with an
// extension from its type; a file with a real name keeps it.
export function pastedName(file, now = new Date()) {
  if (file.name && file.name !== "image.png" && file.name !== "blob") return file.name
  const ext = ((file.type || "").split("/")[1] || "png").replace("jpeg", "jpg")
  const stamp = now.toISOString().replace(/[:.]/g, "-").slice(0, 19)
  return `pasted-${stamp}.${ext}`
}
