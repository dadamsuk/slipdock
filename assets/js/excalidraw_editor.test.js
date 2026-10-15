// node --test assets/js — the Excalidraw editor's hook (#824). What it sends
// is `changed` against what it `remember`s, plus `unsentFiles`; what it took
// in from elsewhere is `taken`; the status line is `statusText`. Those are
// what is tested. The merge itself is Excalidraw's `reconcileElements`; a
// stand-in with the same rule (Slipdock.Wiki.Excalidraw.Reconcile) plays it
// here, and the hook is driven against a fake editor and a fake socket.
import {test} from "node:test"
import assert from "node:assert/strict"
import {changed, remember, unsentFiles, taken, statusText, ExcalidrawEditor} from "./excalidraw_editor.js"

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
