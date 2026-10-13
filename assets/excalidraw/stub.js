// Stands in for optional parts of Excalidraw left out of the bundle
// (Mermaid-to-diagram), so they fail politely instead of shipping megabytes.
export function parseMermaidToExcalidraw() {
  throw new Error("Mermaid diagrams are not available here")
}
export default {}
