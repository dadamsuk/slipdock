// The Excalidraw editor, as one module the page loads only when a drawing is
// opened (assets/js/excalidraw_editor.js). Built by build.sh into
// priv/static/vendor/excalidraw/, never by the app's own esbuild.
import React from "react"
import { createRoot } from "react-dom/client"
import {
  Excalidraw,
  serializeAsJSON,
  reconcileElements,
  restoreElements,
  CaptureUpdateAction,
} from "@excalidraw/excalidraw"
import "@excalidraw/excalidraw/index.css"

// Mounts the editor in `el` with `scene` (a parsed .excalidraw scene) and
// returns what the hook needs: the scene as it stands, a way to take in what
// other people drew, and a way to take it down.
export function mount(el, { scene, files = {}, viewOnly = false, theme = "light", onChange, onPointer }) {
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
      isCollaborating: true,
      theme: appState.theme || theme,
      onChange: (elements, state, sceneFiles) => onChange && onChange(elements, state, sceneFiles),
      onPointerUpdate: (update) => onPointer && onPointer(update),
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
    // Every element, deleted ones too: a deletion is a change to send.
    elements() {
      return api.getSceneElementsIncludingDeleted()
    },
    files() {
      return api.getFiles()
    },
    // Takes in elements and images from elsewhere, by Excalidraw's own merge,
    // without touching the undo stack or the selection. Returns the scene
    // after it, so the caller can tell which of `remote` were taken.
    apply(remote, remoteFiles) {
      const fileList = Object.values(remoteFiles || {})
      if (fileList.length) api.addFiles(fileList)
      if (!remote || remote.length === 0) return api.getSceneElementsIncludingDeleted()
      const elements = reconcileElements(
        api.getSceneElementsIncludingDeleted(),
        restoreElements(remote, null),
        api.getAppState(),
      )
      api.updateScene({ elements, captureUpdate: CaptureUpdateAction.NEVER })
      return elements
    },
    // Who else is here and where their pointers are (a Map of id => collaborator).
    collaborators(map) {
      api.updateScene({ collaborators: map, captureUpdate: CaptureUpdateAction.NEVER })
    },
    unmount() {
      root.unmount()
    },
  }
}
