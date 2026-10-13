// node --test assets/js — the Excalidraw editor's hook. What it sends to be
// saved is `withoutLinked(serialized, linked)`, and whether Save lights up is
// `signature`, so those are what is tested; the editor itself is Excalidraw's.
import {test} from "node:test"
import assert from "node:assert/strict"
import {withoutLinked, signature} from "./excalidraw_editor.js"

const scene = {
  type: "excalidraw",
  elements: [{id: "a", version: 3}],
  files: {
    linked1: {id: "linked1", dataURL: "data:image/png;base64,AAAA"},
    pasted: {id: "pasted", dataURL: "data:image/png;base64,BBBB"},
  },
}

test("files the note links are taken out before saving; pasted ones stay", () => {
  const out = JSON.parse(withoutLinked(JSON.stringify(scene), ["linked1"]))
  assert.deepEqual(Object.keys(out.files), ["pasted"])
  assert.deepEqual(out.elements, scene.elements)
})

test("with nothing linked the JSON goes as the editor wrote it, byte for byte", () => {
  const json = JSON.stringify(scene)
  assert.equal(withoutLinked(json, []), json)
  assert.equal(withoutLinked(json, undefined), json)
})

test("a scene without files is left alone", () => {
  const json = JSON.stringify({elements: []})
  assert.deepEqual(JSON.parse(withoutLinked(json, ["x"])), {elements: []})
})

test("the signature moves when an element changes, is added or deleted, and not otherwise", () => {
  const base = [{id: "a", version: 1}, {id: "b", version: 4}]
  const same = signature(base)
  assert.equal(signature(base.map(e => ({...e}))), same, "looking changes nothing")
  assert.notEqual(signature([{id: "a", version: 2}, base[1]]), same, "an edit")
  assert.notEqual(signature([...base, {id: "c", version: 1}]), same, "an addition")
  assert.notEqual(signature([base[0], {...base[1], isDeleted: true, version: 5}]), same, "a deletion")
  assert.equal(signature([...base, {id: "gone", version: 9, isDeleted: true}]), same, "already-deleted elements don't count")
  assert.equal(signature(undefined), "0:0")
})
