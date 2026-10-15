// An Excalidraw drawing in the Excalidraw editor (W-103 R5.2), on the page
// SlipdockWeb.DrawingLive draws. The editor is a React component of some
// size, so it is not in app.js: it is built once into /vendor/excalidraw/
// (assets/excalidraw/build.sh) and imported here only when a drawing is
// opened. Fonts come from the same place, never from a CDN.
//
// Several people can have the same drawing open (#821, W-1730). The server
// holds the scene (Slipdock.Wiki.DrawingSession) and saves it by itself.
// This hook sends only the elements whose version moved since it last sent
// them, a few times a second at most, and takes in what other people drew
// with Excalidraw's own merge (`reconcileElements`). What it took in is
// remembered as sent, so it never goes back as a change of this editor's.
// Images go once each. Images a .excalidraw.md note links (its `## Embedded
// Files`) are given to the editor to show and never sent, so the note keeps
// linking them rather than swallowing them as data. After a reconnect, or
// when the server's session had to start again, the whole scene is sent and
// the server's handed back, which the merge makes harmless both ways.

// How often changes go to the server at most, and pointers (#825): about
// twenty a second, which the server holds them to as well.
export const SEND_MS = 150
export const POINTER_MS = 50

// The elements whose version differs from what was last sent (or taken in)
// for them: new ones, edited ones and deleted ones.
export function changed(elements, sent) {
  return (elements || []).filter(el => sent.get(el.id) !== el.version)
}

// Notes `elements` as sent, or as already known to the server.
export function remember(sent, elements) {
  for (const el of elements || []) sent.set(el.id, el.version)
  return sent
}

// The images the server hasn't had from here yet, bar the ones the note
// only links.
export function unsentFiles(files, sentFiles, linked) {
  const out = {}
  for (const [id, file] of Object.entries(files || {})) {
    if (sentFiles.has(id) || (linked && linked.includes(id))) continue
    if (file && typeof file.dataURL === "string") out[id] = file
  }
  return out
}

// Which of `remote` made it into the merged scene: those the merge kept
// rather than the local copy.
export function taken(scene, remote) {
  const now = new Map((scene || []).map(el => [el.id, el]))
  return (remote || []).filter(el => {
    const got = now.get(el.id)
    return got && got.version === el.version && got.versionNonce === el.versionNonce
  })
}

// Excalidraw's collaborators map, from the other tabs in the drawing
// (`people`: id, name, colour, viewing) and the last pointer each sent.
export function collaborators(people, pointers) {
  const map = new Map()
  for (const p of people || []) {
    const at = pointers.get(p.id)
    const entry = {
      id: p.id,
      socketId: p.id,
      username: p.viewing ? `${p.name} (viewing)` : p.name,
      color: {background: p.colour, stroke: p.colour},
      isCurrentUser: false,
    }
    if (at) {
      entry.pointer = {x: at.x, y: at.y, tool: at.tool}
      entry.button = at.button
      entry.selectedElementIds = Object.fromEntries((at.selected || []).map(id => [id, true]))
    }
    map.set(p.id, entry)
  }
  return map
}

// What a pointer update from Excalidraw goes to the server as.
export function pointerPayload(update, selectedElementIds) {
  const pointer = (update && update.pointer) || {}
  return {
    x: pointer.x || 0,
    y: pointer.y || 0,
    tool: pointer.tool === "laser" ? "laser" : "pointer",
    button: update && update.button === "down" ? "down" : "up",
    selected: Object.keys(selectedElementIds || {}).filter(id => selectedElementIds[id]),
  }
}

// What the status line says.
export function statusText({ready, viewOnly, connected, unsaved, error}) {
  if (!ready) return "Loading the editor…"
  if (!connected) return "Reconnecting…"
  if (error) return error
  if (viewOnly) return "View only"
  return unsaved ? "Saving…" : "Saved"
}

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
    this.statusEl = this.el.querySelector("[data-drawing-status]")
    this.canvas = this.el.querySelector("#drawing-canvas")
    this.sent = new Map()
    this.sentFiles = new Set()
    this.waiting = [] // remote changes that came before the editor did
    this.people = []
    this.pointers = new Map()
    this.selected = {}
    this.state = {ready: false, viewOnly: false, connected: true, unsaved: false, error: null}

    window.EXCALIDRAW_ASSET_PATH = vendor
    loadCss(vendor + "excalidraw.css")

    // Ctrl+S: there is nothing to press, but it saves now rather than in a
    // moment, and the browser's own "save page" is kept out of the way.
    this.onKey = e => {
      if ((e.ctrlKey || e.metaKey) && e.key === "s") {
        e.preventDefault()
        this.send(true)
      }
    }
    this.onLeave = () => this.send(true)
    window.addEventListener("keydown", this.onKey)
    window.addEventListener("beforeunload", this.onLeave)

    this.handleEvent("drawing:remote", ({elements, files}) => this.take(elements, files))
    this.handleEvent("drawing:saved", () => this.set({unsaved: !!this.timer, error: null}))
    this.handleEvent("drawing:notice", ({text}) => this.set({error: text}))
    this.handleEvent("drawing:resync", () => this.resync())
    this.handleEvent("drawing:people", ({people}) => this.arrived(people))
    this.handleEvent("drawing:pointer", pointer => this.pointed(pointer))

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
    this.linked = reply.linked || []
    remember(this.sent, scene.elements)
    for (const id of Object.keys(scene.files || {})) this.sentFiles.add(id)
    for (const id of this.linked) this.sentFiles.add(id)
    this.editor = mod.mount(this.canvas, {
      scene,
      files: reply.files || {},
      viewOnly: !!reply.view_only,
      theme: document.documentElement.dataset.theme === "dark" ? "dark" : "light",
      onChange: (_elements, appState) => {
        this.selected = (appState && appState.selectedElementIds) || {}
        this.schedule()
      },
      onPointer: update => this.pointer(update),
    })
    this.set({ready: true, viewOnly: !!reply.view_only})
    this.el.dataset.shapes = (scene.elements || []).filter(e => !e.isDeleted).length
    const waiting = this.waiting
    this.waiting = []
    for (const {elements, files} of waiting) this.take(elements, files)
    this.showPeople()
  },

  // Excalidraw calls onChange for every scroll and selection too; what
  // changed is worked out when the throttle fires, and nothing goes if
  // nothing did.
  schedule() {
    if (this.state.viewOnly || this.timer) return
    this.timer = setTimeout(() => this.send(), SEND_MS)
  },

  send(now = false) {
    clearTimeout(this.timer)
    this.timer = null
    // While the socket is down nothing is sent, or noted as sent: the
    // resync on reconnecting sends it all.
    if (!this.editor || !this.editor.ready() || this.state.viewOnly || !this.state.connected) return
    const elements = changed(this.editor.elements(), this.sent)
    const files = unsentFiles(this.editor.files(), this.sentFiles, this.linked)
    if (elements.length === 0 && Object.keys(files).length === 0) {
      if (now) this.pushEvent("flush", {})
      return
    }
    remember(this.sent, elements)
    for (const id of Object.keys(files)) this.sentFiles.add(id)
    this.count()
    this.set({unsaved: true})
    this.pushEvent("delta", {elements, files, flush: now}, reply => {
      if (reply.error) return this.set({error: reply.error})
      if (reply.stale && reply.stale.length) this.take(reply.stale, {})
    })
  },

  // Somebody else's elements, or the server's newer copy of ours.
  take(elements, files) {
    if (!this.editor || !this.editor.ready()) return this.waiting.push({elements, files})
    const scene = this.editor.apply(elements || [], files || {})
    remember(this.sent, taken(scene, elements))
    for (const id of Object.keys(files || {})) this.sentFiles.add(id)
    this.count()
  },

  // Everything this editor has goes up, and everything the server has
  // comes back: after a reconnect, or a session that started again.
  resync() {
    if (!this.editor || !this.editor.ready()) return
    clearTimeout(this.timer)
    this.timer = null
    const elements = this.state.viewOnly ? [] : this.editor.elements()
    const files = this.state.viewOnly ? {} : unsentFiles(this.editor.files(), new Set(), this.linked)
    this.pushEvent("resync", {elements, files}, reply => {
      if (reply.error) return this.set({error: reply.error})
      remember(this.sent, elements)
      for (const id of Object.keys(files)) this.sentFiles.add(id)
      this.take(reply.elements, reply.files)
    })
  },

  // Who else has the drawing open: those who left take their cursors along.
  arrived(people) {
    this.people = people || []
    const here = new Set(this.people.map(p => p.id))
    for (const id of [...this.pointers.keys()]) if (!here.has(id)) this.pointers.delete(id)
    this.showPeople()
  },

  pointed({id, ...at}) {
    if (!this.people.some(p => p.id === id)) return
    this.pointers.set(id, at)
    this.showPeople()
  },

  showPeople() {
    if (!this.editor || !this.editor.ready()) return
    this.editor.collaborators(collaborators(this.people, this.pointers))
    this.el.dataset.pointers = this.pointers.size
  },

  // This pointer, to the others: at once, then at most every POINTER_MS,
  // the latest position winning. Never saved anywhere.
  pointer(update) {
    this.lastPointer = pointerPayload(update, this.selected)
    if (this.pointerTimer) this.pointerPending = true
    else this.sendPointer()
  },

  sendPointer() {
    this.pointerPending = false
    if (this.state.connected) this.pushEvent("pointer", this.lastPointer)
    this.pointerTimer = setTimeout(() => {
      this.pointerTimer = null
      if (this.pointerPending) this.sendPointer()
    }, POINTER_MS)
  },

  disconnected() {
    this.set({connected: false})
  },

  reconnected() {
    this.set({connected: true})
    this.resync()
  },

  // How many shapes the drawing has, on the element: what the browser tests
  // (tools/e2e/drawing-live.sh) read to see the other person's drawing arrive.
  count() {
    if (this.editor && this.editor.ready())
      this.el.dataset.shapes = this.editor.elements().filter(e => !e.isDeleted).length
  },

  set(changes) {
    Object.assign(this.state, changes)
    this.say(statusText(this.state))
  },

  say(text) {
    if (this.statusEl) this.statusEl.textContent = text
  },

  destroyed() {
    clearTimeout(this.timer)
    clearTimeout(this.pointerTimer)
    window.removeEventListener("keydown", this.onKey)
    window.removeEventListener("beforeunload", this.onLeave)
    this.editor?.unmount()
  },
}
