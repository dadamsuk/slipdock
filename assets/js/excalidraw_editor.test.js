// node --test assets/js — the Excalidraw editor's hook (#824). What it sends
// is `changed` against what it `remember`s, plus `unsentFiles`; what it took
// in from elsewhere is `taken`; the status line is `statusText`. Those are
// what is tested. The merge itself is Excalidraw's `reconcileElements`; a
// stand-in with the same rule (Slipdock.Wiki.Excalidraw.Reconcile) plays it
// here, and the hook is driven against a fake editor and a fake socket.
import {test, mock} from "node:test"
import assert from "node:assert/strict"
import {
  changed, remember, unsentFiles, taken, statusText, collaborators, pointerPayload, POINTER_MS, ExcalidrawEditor,
} from "./excalidraw_editor.js"

const el = (id, version, extra = {}) => ({id, version, versionNonce: 7, ...extra})

// Excalidraw's rule: the higher version wins; on a tie, the lower nonce.
function reconcile(local, remote) {
  const byId = new Map(local.map(e => [e.id, e]))
  const out = new Map(local.map(e => [e.id, e]))
  for (const r of remote) {
    const l = byId.get(r.id)
    const keep = l && (l.version > r.version || (l.version === r.version && l.versionNonce < r.versionNonce))
    if (!keep) out.set(r.id, r)
  }
  return [...out.values()]
}

function fakeEditor(elements, files = {}) {
  const editor = {
    scene: elements,
    sceneFiles: files,
    ready: () => true,
    collaborators: map => (editor.shown = map),
    elements: () => editor.scene,
    files: () => editor.sceneFiles,
    apply(remote, remoteFiles) {
      Object.assign(editor.sceneFiles, remoteFiles)
      editor.scene = reconcile(editor.scene, remote)
      return editor.scene
    },
  }
  return editor
}

// The hook with a fake editor already open, recording what it pushes.
function hook(elements, {files = {}, linked = [], viewOnly = false} = {}) {
  const h = Object.create(ExcalidrawEditor)
  h.pushed = []
  h.pushEvent = (event, payload, reply) => h.pushed.push({event, payload, reply})
  h.statusEl = {textContent: ""}
  h.el = {dataset: {}}
  h.sent = remember(new Map(), elements)
  h.sentFiles = new Set(Object.keys(files))
  h.linked = linked
  h.waiting = []
  h.people = []
  h.pointers = new Map()
  h.selected = {}
  h.state = {ready: true, viewOnly, connected: true, unsaved: false, error: null}
  h.editor = fakeEditor(elements, {...files})
  return h
}

test("only elements whose version moved are sent: new, edited, deleted", () => {
  const sent = remember(new Map(), [el("a", 1), el("b", 4), el("c", 2)])
  const now = [el("a", 1), el("b", 5), el("c", 3, {isDeleted: true}), el("d", 1)]
  assert.deepEqual(changed(now, sent).map(e => e.id), ["b", "c", "d"])
  remember(sent, changed(now, sent))
  assert.deepEqual(changed(now, sent), [], "nothing twice")
  assert.deepEqual(changed(undefined, sent), [])
})

test("images go once each, never a linked one, never one without data", () => {
  const files = {
    pasted: {id: "pasted", dataURL: "data:image/png;base64,AA"},
    linked1: {id: "linked1", dataURL: "data:image/png;base64,BB"},
    empty: {id: "empty"},
  }
  const sentFiles = new Set()
  assert.deepEqual(Object.keys(unsentFiles(files, sentFiles, ["linked1"])), ["pasted"])
  sentFiles.add("pasted")
  assert.deepEqual(unsentFiles(files, sentFiles, ["linked1"]), {})
  assert.deepEqual(unsentFiles(undefined, sentFiles, undefined), {})
})

test("taken: the remote elements the merge kept, not the ones it refused", () => {
  const scene = reconcile([el("a", 5), el("b", 1)], [el("a", 3), el("b", 2), el("c", 1)])
  assert.deepEqual(taken(scene, [el("a", 3), el("b", 2), el("c", 1)]).map(e => e.id), ["b", "c"])
})

test("the status line", () => {
  assert.equal(statusText({ready: false}), "Loading the editor…")
  assert.equal(statusText({ready: true, connected: false, unsaved: true}), "Reconnecting…")
  assert.equal(statusText({ready: true, connected: true, error: "Oops"}), "Oops")
  assert.equal(statusText({ready: true, connected: true, viewOnly: true}), "View only")
  assert.equal(statusText({ready: true, connected: true, unsaved: true}), "Saving…")
  assert.equal(statusText({ready: true, connected: true, unsaved: false}), "Saved")
})

test("a change is sent once, with its new images, and the status says saving until saved", () => {
  const h = hook([el("a", 1), el("b", 1)], {linked: ["l1"]})
  h.editor.scene = [el("a", 2), el("b", 1), el("n", 1, {fileId: "p"})]
  h.editor.sceneFiles = {p: {id: "p", dataURL: "data:x"}, l1: {id: "l1", dataURL: "data:y"}}
  h.send()
  assert.equal(h.pushed.length, 1)
  const {event, payload} = h.pushed[0]
  assert.equal(event, "delta")
  assert.deepEqual(payload.elements.map(e => e.id), ["a", "n"])
  assert.deepEqual(Object.keys(payload.files), ["p"])
  assert.equal(h.statusEl.textContent, "Saving…")

  h.send()
  assert.equal(h.pushed.length, 1, "nothing new, nothing sent")
  h.send(true)
  assert.equal(h.pushed[1].event, "flush", "Ctrl+S with nothing to send still saves now")
})

test("a reader's editor never sends", () => {
  const h = hook([el("a", 1)], {viewOnly: true})
  h.editor.scene = [el("a", 2)]
  h.send()
  h.schedule()
  assert.equal(h.pushed.length, 0)
  assert.ok(!h.timer, "nothing scheduled")
})

test("remote changes are applied, and do not echo back as this editor's", () => {
  const h = hook([el("a", 1), el("b", 3)])
  h.take([el("a", 2, {x: 5}), el("b", 2), el("c", 1)], {f: {id: "f", dataURL: "data:z"}})
  const byId = Object.fromEntries(h.editor.scene.map(e => [e.id, e]))
  assert.equal(byId.a.x, 5)
  assert.equal(byId.b.version, 3, "ours was newer")
  assert.ok(byId.c)
  assert.ok(h.editor.sceneFiles.f)

  h.send()
  assert.equal(h.pushed.length, 0, "nothing goes back")
})

test("a stale reply brings the server's newer copy in", () => {
  const h = hook([el("a", 1)])
  h.editor.scene = [el("a", 2)]
  h.send()
  h.pushed[0].reply({stale: [el("a", 9, {x: 1})]})
  assert.equal(h.editor.scene[0].version, 9)
  h.send()
  assert.equal(h.pushed.length, 1)
})

test("remote changes that arrive before the editor wait for it", () => {
  const h = hook([])
  const editor = h.editor
  h.editor = null
  h.take([el("early", 1)], {})
  assert.equal(h.waiting.length, 1)
  h.editor = editor
  for (const {elements, files} of h.waiting.splice(0)) h.take(elements, files)
  assert.deepEqual(h.editor.scene.map(e => e.id), ["early"])
})

test("a resync sends the whole scene and takes in the server's", () => {
  const h = hook([el("a", 1)], {files: {p: {id: "p", dataURL: "data:x"}}, linked: ["l"]})
  h.editor.sceneFiles.l = {id: "l", dataURL: "data:y"}
  h.reconnected()
  const {event, payload, reply} = h.pushed[0]
  assert.equal(event, "resync")
  assert.deepEqual(payload.elements.map(e => e.id), ["a"], "everything, sent or not")
  assert.deepEqual(Object.keys(payload.files), ["p"], "every image but the linked")

  reply({elements: [el("a", 1), el("theirs", 4)], files: {}})
  assert.deepEqual(h.editor.scene.map(e => e.id).sort(), ["a", "theirs"])
  h.send()
  assert.equal(h.pushed.length, 1, "nothing echoes after a resync")
  assert.equal(h.statusEl.textContent, "Saved")

  h.disconnected()
  assert.equal(h.statusEl.textContent, "Reconnecting…")
})

test("the shape count follows what is drawn here and what arrives", () => {
  const h = hook([el("a", 1)])
  h.editor.scene = [el("a", 1), el("b", 1)]
  h.send()
  assert.equal(h.el.dataset.shapes, 2)
  h.take([el("a", 2, {isDeleted: true}), el("c", 1)], {})
  assert.equal(h.el.dataset.shapes, 2)
})

test("collaborators: a name, a colour, viewers marked, and the last pointer with its selection", () => {
  const people = [
    {id: "t1", name: "Wren", colour: "#e03131", viewing: false},
    {id: "t2", name: "Ash", colour: "#1971c2", viewing: true},
  ]
  const pointers = new Map([["t1", {x: 10, y: 20, tool: "pointer", button: "down", selected: ["a"]}]])
  const map = collaborators(people, pointers)
  const wren = map.get("t1")
  assert.equal(wren.username, "Wren")
  assert.deepEqual(wren.color, {background: "#e03131", stroke: "#e03131"})
  assert.deepEqual(wren.pointer, {x: 10, y: 20, tool: "pointer"})
  assert.equal(wren.button, "down")
  assert.deepEqual(wren.selectedElementIds, {a: true})
  assert.equal(map.get("t2").username, "Ash (viewing)")
  assert.equal(map.get("t2").pointer, undefined)
})

test("pointerPayload sends a cursor's worth and nothing else", () => {
  const out = pointerPayload({pointer: {x: 1.5, y: 2, tool: "laser"}, button: "down", pointersMap: {big: 1}}, {a: true, b: false})
  assert.deepEqual(out, {x: 1.5, y: 2, tool: "laser", button: "down", selected: ["a"]})
  assert.deepEqual(pointerPayload(null, null), {x: 0, y: 0, tool: "pointer", button: "up", selected: []})
})

test("people arrive and leave, and their cursors go with them; strangers' pointers are ignored", () => {
  const h = hook([])
  h.arrived([{id: "t1", name: "Wren", colour: "#000", viewing: false}])
  h.pointed({id: "t1", x: 5, y: 6, tool: "pointer", button: "up", selected: []})
  h.pointed({id: "ghost", x: 1, y: 1})
  assert.equal(h.editor.shown.get("t1").pointer.x, 5)
  assert.equal(h.editor.shown.size, 1)
  assert.equal(h.el.dataset.pointers, 1)

  h.arrived([])
  assert.equal(h.editor.shown.size, 0)
  assert.equal(h.pointers.size, 0)
})

test("pointers go at once, then at most every POINTER_MS, the latest position winning", () => {
  mock.timers.enable({apis: ["setTimeout"]})
  try {
    const h = hook([])
    h.pointer({pointer: {x: 1, y: 1}})
    h.pointer({pointer: {x: 2, y: 2}})
    h.pointer({pointer: {x: 3, y: 3}})
    assert.deepEqual(h.pushed.map(p => p.payload.x), [1])
    mock.timers.tick(POINTER_MS)
    assert.deepEqual(h.pushed.map(p => p.payload.x), [1, 3])
    mock.timers.tick(POINTER_MS)
    assert.equal(h.pushed.length, 2, "nothing new, nothing sent")
  } finally {
    mock.timers.reset()
  }
})

test("while disconnected nothing is sent or noted as sent; reconnecting sends it all", () => {
  const h = hook([el("a", 1)])
  h.disconnected()
  h.editor.scene = [el("a", 2)]
  h.send()
  h.pointer({pointer: {x: 1, y: 1}})
  assert.equal(h.pushed.length, 0)
  assert.equal(h.sent.get("a"), 1)

  h.reconnected()
  assert.equal(h.pushed[0].event, "resync")
  assert.deepEqual(h.pushed[0].payload.elements, [el("a", 2)])
})
