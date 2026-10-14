// Stands in for @codemirror/lang-html, which lang-markdown pulls in only to
// highlight raw HTML inside Markdown (and, with it, the CSS and JavaScript
// parsers: 150 KB). Without it raw HTML is shown as plain text.
export function html() {
  return {support: [], language: {parser: undefined}}
}
export function htmlCompletionSource() {
  return null
}
