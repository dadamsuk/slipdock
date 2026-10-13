// node --test assets/js — no browser, so the DOM here is the handful of
// things wiki_tree.js touches, and the server is a pushEvent that answers.
import {test} from "node:test"
import assert from "node:assert/strict"
import {TreeModel, windowRange, dropZone, dropIntent, escapeHtml, WikiTree, ROW_HEIGHT} from "./wiki_tree.js"

const folder = (id, extra = {}) => ({kind: "folder", id, key: `folder:${id}`, title: `F${id}`, count: 1, board_id: 1, ...extra})
const page = (id, extra = {}) => ({kind: "page", id, key: `page:${id}`, title: `P${id}`, count: 0, board_id: 1, ...extra})

// root: F1 (open: F2 (open: P3), P4 (open: P5)), P6
function sample() {
  const model = new TreeModel("root")
  model.set("root", [folder(1), page(6)])
  model.set("folder:1", [folder(2), page(4, {count: 1})])
  model.set("folder:2", [page(3)])
  model.set("page:4", [page(5)])
  model.open = new Set(["folder:1", "folder:2", "page:4"])
  return model
}

test("flatten walks open, loaded containers in order, with depth and parent", () => {
  const flat = sample().flatten()
  assert.deepEqual(flat.map(i => [i.row.key, i.depth, i.parent]), [
    ["folder:1", 0, "root"],
    ["folder:2", 1, "folder:1"],
    ["page:3", 2, "folder:2"],
    ["page:4", 1, "folder:1"],
    ["page:5", 2, "page:4"],
    ["page:6", 0, "root"],
  ])
})

test("a shut folder hides its rows; an open one not loaded yet shows loading", () => {
  const model = sample()
  model.open.delete("folder:2")
  model.kids.delete("page:4")
  const keys = model.flatten().map(i => i.row.key)
  assert.deepEqual(keys, ["folder:1", "folder:2", "page:4", "loading:page:4", "page:6"])
})

test("nothing with no children opens, and a key seen above it never opens twice", () => {
  const model = new TreeModel("root")
  model.set("root", [folder(1, {count: 0}), page(2, {count: 1})])
  model.set("page:2", [page(2, {count: 1})])
  model.open = new Set(["folder:1", "page:2"])
  assert.deepEqual(model.flatten().map(i => i.row.key), ["folder:1", "page:2", "page:2"])
})

test("append puts the next page of rows where the more row was", () => {
  const model = new TreeModel("root")
  model.set("root", [page(1), {kind: "more", key: "more:1", offset: 1, count: 0}])
  model.append("root", [page(2)])
  assert.deepEqual(model.kids.get("root").map(r => r.key), ["page:1", "page:2"])
})

test("windowRange draws what is in view and a few either side, clamped", () => {
  assert.deepEqual(windowRange(0, 300, 1000, 30, 5), [0, 15])
  assert.deepEqual(windowRange(3000, 300, 1000, 30, 5), [95, 115])
  assert.deepEqual(windowRange(29900, 300, 1000, 30, 5), [991, 1000])
  assert.deepEqual(windowRange(-50, 300, 4, 30, 5), [0, 4])
})

test("dropZone: top quarter before, bottom quarter after, middle inside", () => {
  assert.equal(dropZone(2), "before")
  assert.equal(dropZone(ROW_HEIGHT / 2), "inside")
  assert.equal(dropZone(ROW_HEIGHT - 2), "after")
})

test("a page dropped on a folder's middle is filed in it", () => {
  const flat = sample().flatten()
  // P6 (index 5) onto F2 (index 1)
  assert.deepEqual(dropIntent(flat, 5, 1, "inside"), {kind: "page", id: "6", into: "folder:2", before: null})
})

test("a page dropped above or below a page lands beside it, in its container", () => {
  const flat = sample().flatten()
  assert.deepEqual(dropIntent(flat, 5, 2, "before"), {kind: "page", id: "6", into: "folder:2", before: "3"})
  assert.deepEqual(dropIntent(flat, 5, 2, "after"), {kind: "page", id: "6", into: "folder:2", before: null})
  // P3 below P4's row: the next page in folder 1 after P4 is none
  assert.deepEqual(dropIntent(flat, 2, 3, "after"), {kind: "page", id: "3", into: "folder:1", before: null})
})

test("a page dropped on a page's middle becomes part of it", () => {
  const flat = sample().flatten()
  assert.deepEqual(dropIntent(flat, 5, 4, "inside"), {kind: "page", id: "6", into: "page:5", before: null})
})

test("a page at the top level dropped beside one goes to the top of the wiki", () => {
  const flat = sample().flatten()
  assert.deepEqual(dropIntent(flat, 2, 5, "before"), {kind: "page", id: "3", into: "folder:", before: "6"})
})

test("a folder only lands among folders", () => {
  const flat = sample().flatten()
  // F2 before F1: into the top, above F1
  assert.deepEqual(dropIntent(flat, 1, 0, "before"), {kind: "folder", id: "2", into: "folder:", before: "1"})
  // F2 dropped on a page row goes to the folder that page is in
  assert.deepEqual(dropIntent(flat, 1, 5, "inside"), {kind: "folder", id: "2", into: "folder:", before: null})
  assert.deepEqual(dropIntent(flat, 1, 4, "before"), {kind: "folder", id: "2", into: "folder:1", before: null})
})

test("nothing is dropped on itself, inside itself, or from a vault's own rows", () => {
  const flat = sample().flatten()
  assert.equal(dropIntent(flat, 0, 0, "inside"), null)
  assert.equal(dropIntent(flat, 0, 2, "inside"), null) // F1 into P3, which is inside F1
  assert.equal(dropIntent(flat, 0, 1, "inside"), null) // F1 into F2, inside F1
  assert.equal(dropIntent(flat, 3, 4, "inside"), null) // P4 onto its own child
  const vault = new TreeModel("vault")
  vault.set("vault", [{kind: "dir", key: "dir:Jobs", id: "dir:Jobs", title: "Jobs", count: 1}, page(9)])
  assert.equal(dropIntent(vault.flatten(), 1, 0, "inside"), null)
})

test("escapeHtml leaves nothing a title could inject", () => {
  assert.equal(escapeHtml(`<img src=x onerror="a">&'`), "&lt;img src=x onerror=&quot;a&quot;&gt;&amp;&#39;")
  assert.equal(escapeHtml(null), "")
})

// The hook, with just enough of a DOM.

function fakeStorage() {
  const data = {}
  return {
    data,
    getItem: k => (k in data ? data[k] : null),
    setItem: (k, v) => { data[k] = String(v) },
    removeItem: k => { delete data[k] },
  }
}

function mountHook({dataset = {}, replies = []} = {}) {
  globalThis.localStorage = fakeStorage()
  globalThis.window = {addEventListener() {}, removeEventListener() {}}
  globalThis.document = {addEventListener() {}, removeEventListener() {}, createElement: () => ({style: {}, dataset: {}, remove() {}, addEventListener() {}})}
  globalThis.requestAnimationFrame = fn => fn()

  const rowsEl = {
    offsetTop: 0, innerHTML: "", style: {}, attrs: {},
    addEventListener() {}, setAttribute(k, v) { this.attrs[k] = v },
    querySelectorAll: () => [], appendChild() {},
  }
  const el = {
    dataset: {board: "1", vault: "", organising: "false", canWrite: "true", version: "1", current: "", reveal: "[]", ...dataset},
    scrollTop: 0, clientHeight: 600,
    querySelector: sel => (sel === "[data-tree-rows]" ? rowsEl : null),
    addEventListener() {}, classList: {add() {}, remove() {}},
  }
  const pushed = []
  const hook = Object.create(WikiTree)
  hook.el = el
  hook.handleEvent = () => {}
  hook.pushEvent = (event, payload, reply) => {
    pushed.push({event, payload})
    const answer = replies.shift()
    if (reply && answer) reply(typeof answer === "function" ? answer(payload) : answer)
  }
  return {hook, el, rowsEl, pushed}
}

const root = rows => ({scope: "board", root: "root", filtering: false, nodes: {root: rows}, reveal: [], small: false})

test("mounting asks for the tree and draws only the rows", () => {
  const {hook, rowsEl, pushed} = mountHook({replies: [root([folder(1), page(2)])]})
  hook.mounted()
  assert.equal(pushed[0].event, "tree_load")
  assert.deepEqual(pushed[0].payload, {scope: "board", keys: [], all: false})
  assert.match(rowsEl.innerHTML, /data-key="folder:1"/)
  assert.match(rowsEl.innerHTML, /data-phx-link="patch"/)
  assert.equal(rowsEl.style.height, `${2 * ROW_HEIGHT}px`)
})

test("a first visit to a small wiki opens every folder, and remembers it", () => {
  const all = {...root([folder(1)]), nodes: {root: [folder(1)], "folder:1": [page(2)]}}
  const {hook, pushed} = mountHook({replies: [{...root([folder(1)]), small: true}, all]})
  hook.mounted()
  assert.equal(pushed[1].payload.all, true)
  assert.deepEqual([...hook.model.open], ["root", "folder:1"])
  assert.deepEqual(JSON.parse(localStorage.data["slipdock:wiki-open:board:1"]), ["root", "folder:1"])
})

test("what was open last time is asked for, and the way to the page opens too", () => {
  const {hook, pushed} = mountHook({
    replies: [{...root([folder(1), folder(7)]), nodes: {root: [folder(1), folder(7)], "folder:1": [page(2)], "folder:7": [page(8)]}, reveal: ["folder:7"]}],
  })
  globalThis.localStorage = fakeStorage()
  localStorage.setItem("slipdock:wiki-open:board:1", JSON.stringify(["folder:1"]))
  const load = WikiTree.load
  hook.model = new TreeModel()
  hook.rowsEl = hook.el.querySelector("[data-tree-rows]")
  hook.scope = "board"
  load.call(hook, {})
  assert.deepEqual(pushed[0].payload.keys, ["folder:1"])
  assert.deepEqual([...hook.model.open].sort(), ["folder:1", "folder:7"])
})

test("opening a folder asks for it once; shutting keeps it; both are remembered", () => {
  const {hook, pushed} = mountHook({
    replies: [root([folder(1)]), {nodes: {"folder:1": [page(2)]}}],
  })
  hook.mounted()
  hook.toggle("folder:1")
  assert.deepEqual(pushed[1].payload, {scope: "board", keys: ["folder:1"], only: true})
  assert.deepEqual(hook.model.flatten().map(i => i.row.key), ["folder:1", "page:2"])
  hook.toggle("folder:1")
  assert.equal(pushed.length, 2)
  assert.deepEqual(JSON.parse(localStorage.data["slipdock:wiki-open:board:1"]), [])
  hook.toggle("folder:1")
  assert.equal(pushed.length, 2)
})

test("a folder the server will not load stops loading rather than spinning", () => {
  const {hook} = mountHook({replies: [root([folder(1)]), {nodes: {}}]})
  hook.mounted()
  hook.toggle("folder:1")
  assert.equal(hook.model.open.has("folder:1"), false)
})

test("while filtering every level sent is open, and the reader's own set is kept", () => {
  const filtered = {scope: "board", root: "root", filtering: true, reveal: [], small: false,
    nodes: {root: [folder(1)], "folder:1": [page(2)]}}
  const {hook} = mountHook({replies: [filtered]})
  localStorage.setItem("slipdock:wiki-open:board:1", JSON.stringify(["folder:9"]))
  hook.mounted()
  assert.deepEqual([...hook.model.open].sort(), ["folder:1", "root"])
  assert.deepEqual(JSON.parse(localStorage.data["slipdock:wiki-open:board:1"]), ["folder:9"])
})

test("a new version from the server reloads; anything else only redraws", () => {
  const {hook, el, pushed} = mountHook({replies: [root([page(1)]), root([page(1), page(2)])]})
  hook.mounted()
  hook.updated()
  assert.equal(pushed.length, 1)
  el.dataset.version = "2"
  hook.updated()
  assert.equal(pushed.length, 2)
  assert.equal(hook.model.kids.get("root").length, 2)
})

test("a page opened elsewhere opens the folders to it, asking for those not loaded", () => {
  const {hook, el, pushed} = mountHook({replies: [root([folder(1)]), {nodes: {"folder:1": [page(2)]}}]})
  hook.mounted()
  el.dataset.current = "page:2"
  el.dataset.reveal = JSON.stringify(["folder:1"])
  hook.updated()
  assert.deepEqual(pushed[1].payload.keys, ["folder:1"])
  assert.ok(hook.model.open.has("folder:1"))
  assert.match(hook.rowsEl.innerHTML, /aria-current="page"/)
})

test("a more row in view asks for the next page of its container", () => {
  const {hook, rowsEl, pushed} = mountHook({
    replies: [root([page(1), {kind: "more", key: "more:1", offset: 1, count: 0}]), {key: "root", rows: [page(2)]}],
  })
  rowsEl.querySelectorAll = sel => (sel === "[data-more]" && !rowsEl.done ? [{dataset: {more: "root", offset: "1"}}] : [])
  hook.mounted()
  rowsEl.done = true
  assert.deepEqual(pushed[1], {event: "tree_children", payload: {scope: "board", key: "root", offset: 1}})
  assert.deepEqual(hook.model.kids.get("root").map(r => r.key), ["page:1", "page:2"])
})

test("organising puts a handle on this board's pages and folders only", () => {
  const {hook, rowsEl} = mountHook({
    dataset: {organising: "true"},
    replies: [root([folder(1), page(2), page(3, {board_id: 2}), folder(4, {mount: true})])],
  })
  hook.mounted()
  const handles = rowsEl.innerHTML.split("data-key=").slice(1).map(r => r.includes("data-drag"))
  assert.deepEqual(handles, [true, true, false, false])
})

test("rows from another board open that board's wiki, files open in a tab", () => {
  const file = {kind: "file", id: 5, key: "file:5", title: "a.png", count: 0, board_id: 1, href: "/wiki-files/5/a.png"}
  const {hook, rowsEl} = mountHook({replies: [root([page(3, {board_id: 2, nav: "redirect"}), file])]})
  hook.mounted()
  assert.match(rowsEl.innerHTML, /data-phx-link="redirect"/)
  assert.match(rowsEl.innerHTML, /target="_blank"/)
})

test("a drag keeps hold of its row when a folder opens above it mid-drag", () => {
  const {hook, el, rowsEl, pushed} = mountHook({
    dataset: {organising: "true"},
    replies: [root([folder(1), page(2), page(3)])],
  })
  const listeners = {}
  globalThis.window.addEventListener = (type, fn) => { listeners[type] = fn }
  globalThis.document.body = {appendChild() {}}
  el.getBoundingClientRect = () => ({top: 0, bottom: 600})
  rowsEl.getBoundingClientRect = () => ({top: 0})
  hook.mounted()

  // Grab P3 by its handle (row 2).
  const rowEl = {dataset: {key: "page:3", index: "2"}}
  hook.dragStart({target: {closest: sel => (sel === "[data-drag]" ? {closest: () => rowEl} : null)}, button: 0, clientX: 5, clientY: 65, preventDefault() {}})
  listeners.pointermove({clientX: 20, clientY: 80})

  // F1 opens above it: P3 is now row 3, and row 2 is F1's child.
  hook.model.set("folder:1", [page(9)])
  hook.model.open.add("folder:1")
  hook.render()

  // Drop on F1's middle (row 0).
  listeners.pointermove({clientX: 20, clientY: 15})
  listeners.pointerup({})
  assert.deepEqual(pushed.at(-1), {event: "tree_move", payload: {kind: "page", id: "3", into: "folder:1", before: null}})
})

test("revealing a page its folder has not reached yet asks for the rows through it", () => {
  const more = {kind: "more", key: "more:1", offset: 1, count: 0}
  const {hook, el, pushed} = mountHook({
    replies: [
      {...root([folder(1)]), nodes: {root: [folder(1)], "folder:1": [page(2), more]}},
      {nodes: {"folder:1": [page(2), page(3)]}},
    ],
  })
  localStorage.setItem("slipdock:wiki-open:board:1", JSON.stringify(["folder:1"]))
  hook.mounted()
  el.dataset.current = "page:3"
  el.dataset.reveal = JSON.stringify(["folder:1"])
  hook.updated()
  assert.deepEqual(pushed.at(-1).payload, {scope: "board", keys: ["folder:1"], only: true, through: "page:3"})
  assert.ok(hook.model.flatten().some(i => i.row.key === "page:3"))
})
