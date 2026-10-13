// The Excalidraw editor, as one module the page loads only when a drawing is
// opened (assets/js/excalidraw_editor.js). Built by build.sh into
// priv/static/vendor/excalidraw/, never by the app's own esbuild.
import React from "react"
import { createRoot } from "react-dom/client"
import { Excalidraw, serializeAsJSON } from "@excalidraw/excalidraw"
import "@excalidraw/excalidraw/index.css"

// Mounts the editor in `el` with `scene` (a parsed .excalidraw scene) and
// returns what the hook needs: the scene as JSON, and a way to take it down.
export function mount(el, { scene, files = {}, viewOnly = false, theme = "light", onChange }) {
  let api = null
  const root = createRoot(el)
  const appState = { ...(scene.appState || {}) }
  delete appState.collaborators

  root.render(
    React.createElement(Excalidraw, {
      initialData: {
        elements: scene.elements || [],
        appState,
        files: { ...(scene.files || {}), ...files },
        scrollToContent: true,
      },
      excalidrawAPI: (instance) => {
        api = instance
      },
      viewModeEnabled: viewOnly,
      theme: appState.theme || theme,
      onChange: (elements) => onChange && onChange(elements),
      UIOptions: { canvasActions: { loadScene: false, saveToActiveFile: false } },
    }),
  )

  return {
    serialize() {
      return serializeAsJSON(api.getSceneElements(), api.getAppState(), api.getFiles(), "local")
    },
    ready() {
      return api !== null
    },
    unmount() {
      root.unmount()
    },
  }
}
