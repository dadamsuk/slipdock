// An Excalidraw drawing in the Excalidraw editor (W-103 R5.2), on the page
// SlipdockWeb.DrawingLive draws. The editor is a React component of some
// size, so it is not in app.js: it is built once into /vendor/excalidraw/
// (assets/excalidraw/build.sh) and imported here only when a drawing is
// opened. Fonts come from the same place, never from a CDN.
//
// The server hands over the scene as the file holds it; saving sends the
// whole scene back as JSON, and the server writes it in the file's own
// format. Images a .excalidraw.md note links (its `## Embedded Files`) are
// given to the editor to show, and taken out again before saving, so the
// note keeps linking them rather than swallowing them as data.

// The scene JSON with the linked files' data left out.
export function withoutLinked(json, linked) {
  if (!linked || linked.length === 0) return json
  const scene = JSON.parse(json)
  if (scene.files) for (const id of linked) delete scene.files[id]
  return JSON.stringify(scene, null, 2)
}

// What changes when the drawing does, and not when it is only looked at:
// Excalidraw calls onChange for every scroll and selection as well.
// Deleted elements are left out: the editor keeps them, a saved file need not.
export function signature(elements) {
  const live = (elements || []).filter(el => !el.isDeleted)
  const sum = live.reduce((total, el) => total + (el.version || 0), 0)
  return `${live.length}:${sum}`
}

const LEAVE = "This drawing has changes that aren't saved. Leave anyway?"

function loadCss(href) {
  if (document.querySelector(`link[data-excalidraw-css]`)) return
  const link = document.createElement("link")
  link.rel = "stylesheet"
  link.href = href
  link.dataset.excalidrawCss = ""
  document.head.appendChild(link)
}

export const ExcalidrawEditor = {
  mounted() {
    const vendor = this.el.dataset.vendor
    this.status = this.el.querySelector("[data-drawing-status]")
    this.saveButton = this.el.querySelector("[data-drawing-save]")
    this.canvas = this.el.querySelector("#drawing-canvas")
    this.saved = null
    this.dirty = false

    window.EXCALIDRAW_ASSET_PATH = vendor
    loadCss(vendor + "excalidraw.css")

    this.onKey = e => {
      if ((e.ctrlKey || e.metaKey) && e.key === "s" && this.saveButton) {
        e.preventDefault()
        this.save()
      }
    }
    this.onLeave = e => {
      if (this.dirty) {
        e.preventDefault()
        e.returnValue = LEAVE
      }
    }
    window.addEventListener("keydown", this.onKey)
    window.addEventListener("beforeunload", this.onLeave)
    this.saveButton?.addEventListener("click", () => this.save())

    this.pushEvent("load", {}, reply => this.open(vendor, reply))
  },

  async open(vendor, reply) {
    if (reply.error) return this.say(reply.error)
    let mod
    try {
      mod = await import(vendor + "excalidraw.js")
    } catch (_e) {
      return this.say("The drawing editor couldn't be loaded.")
    }
    const scene = JSON.parse(reply.json)
    this.base = reply.base
    this.linked = reply.linked || []
    this.saved = signature(scene.elements)
    this.editor = mod.mount(this.canvas, {
      scene,
      files: reply.files || {},
      viewOnly: !!reply.view_only,
      theme: document.documentElement.dataset.theme === "dark" ? "dark" : "light",
      onChange: elements => this.changed(elements),
    })
    this.say(reply.view_only ? "View only" : "")
  },

  changed(elements) {
    const dirty = signature(elements) !== this.saved
    if (dirty === this.dirty) return
    this.dirty = dirty
    if (this.saveButton) this.saveButton.disabled = !dirty
    this.say(dirty ? "Unsaved changes" : "")
  },

  save() {
    if (!this.editor || !this.editor.ready() || this.saving) return
    this.saving = true
    const json = withoutLinked(this.editor.serialize(), this.linked)
    const sig = signature(JSON.parse(json).elements)
    this.say("Saving…")
    this.pushEvent("save", {json, base: this.base}, reply => {
      this.saving = false
      if (reply.ok) {
        this.base = reply.base
        this.saved = sig
        this.dirty = false
        if (this.saveButton) this.saveButton.disabled = true
        this.say("Saved")
      } else {
        this.say(reply.error || "The drawing couldn't be saved.")
      }
    })
  },

  say(text) {
    if (this.status) this.status.textContent = text
  },

  destroyed() {
    window.removeEventListener("keydown", this.onKey)
    window.removeEventListener("beforeunload", this.onLeave)
    this.editor?.unmount()
  },
}
