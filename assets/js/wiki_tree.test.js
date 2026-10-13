// node --test assets/js — no browser, so the DOM here is the handful of
// things wiki_tree.js touches, and the server is a pushEvent that answers.
import {test} from "node:test"
import assert from "node:assert/strict"
import {TreeModel, windowRange, dropZone, dropIntent, escapeHtml, keyMove, typeAhead, WikiTree, ROW_HEIGHT} from "./wiki_tree.js"

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
    offsetTop: 0, innerHTML: "", style: {}, attrs: {}, dataset: {},
    addEventListener() {}, setAttribute(k, v) { this.attrs[k] = v }, removeAttribute(k) { delete this.attrs[k] },
    querySelectorAll: () => [], appendChild() {}, focus() {},
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
    if (!reply) return
    const answer = replies.shift()
    if (answer) reply(typeof answer === "function" ? answer(payload) : answer)
  }
  return {hook, el, rowsEl, pushed}
}

const root = rows => ({scope: "board", root: "root", filtering: false, nodes: {root: rows}, reveal: [], small: false, open: []})
const saved = pushed => pushed.filter(p => p.event === "tree_open").map(p => p.payload.keys)

test("mounting asks for the tree and draws only the rows", () => {
  const {hook, rowsEl, pushed} = mountHook({replies: [root([folder(1), page(2)])]})
  hook.mounted()
  assert.equal(pushed[0].event, "tree_load")
  assert.deepEqual(pushed[0].payload, {scope: "board", all: false})
  assert.match(rowsEl.innerHTML, /data-key="folder:1"/)
  assert.match(rowsEl.innerHTML, /data-phx-link="patch"/)
  assert.equal(rowsEl.style.height, `${2 * ROW_HEIGHT}px`)
})

test("a first visit to a small wiki opens every folder, and remembers it", () => {
  const all = {...root([folder(1)]), nodes: {root: [folder(1)], "folder:1": [page(2)]}}
  const {hook, pushed} = mountHook({replies: [{...root([folder(1)]), small: true, open: null}, all]})
  hook.mounted()
  assert.equal(pushed[1].payload.all, true)
  assert.deepEqual([...hook.model.open], ["root", "folder:1"])
  assert.deepEqual(saved(pushed), [["root", "folder:1"]])
})

test("a big wiki's first visit opens only the way to the page", () => {
  const {hook, pushed} = mountHook({replies: [{...root([folder(1)]), open: null, reveal: ["folder:1"], nodes: {root: [folder(1)], "folder:1": [page(2)]}}]})
  hook.mounted()
  assert.deepEqual([...hook.model.open], ["folder:1"])
  assert.equal(pushed.length, 1)
})

test("what was open last time comes back from the server, with the way to the page", () => {
  const {hook} = mountHook({
    replies: [{...root([folder(1), folder(7)]), nodes: {root: [folder(1), folder(7)], "folder:1": [page(2)], "folder:7": [page(8)]}, open: ["folder:1"], reveal: ["folder:7"]}],
  })
  hook.mounted()
  assert.deepEqual([...hook.model.open].sort(), ["folder:1", "folder:7"])
  assert.deepEqual(hook.model.flatten().map(i => i.row.key), ["folder:1", "page:2", "folder:7", "page:8"])
})

test("opening a folder asks for it once; shutting keeps it; both are kept on the server", () => {
  const {hook, pushed} = mountHook({
    replies: [root([folder(1)]), {nodes: {"folder:1": [page(2)]}}],
  })
  hook.mounted()
  hook.toggle("folder:1")
  assert.deepEqual(pushed[1].payload, {scope: "board", keys: ["folder:1"], only: true})
  assert.deepEqual(hook.model.flatten().map(i => i.row.key), ["folder:1", "page:2"])
  hook.toggle("folder:1")
  hook.toggle("folder:1")
  assert.equal(pushed.filter(p => p.event === "tree_load").length, 2)
  assert.deepEqual(saved(pushed), [["folder:1"], [], ["folder:1"]])
})

test("a folder the server will not load stops loading rather than spinning", () => {
  const {hook} = mountHook({replies: [root([folder(1)]), {nodes: {}}]})
  hook.mounted()
  hook.toggle("folder:1")
  assert.equal(hook.model.open.has("folder:1"), false)
})

test("while filtering every level sent is open, and nothing is kept of it", () => {
  const filtered = {scope: "board", root: "root", filtering: true, reveal: [], small: false, open: null,
    nodes: {root: [folder(1)], "folder:1": [page(2)]}}
  const {hook, pushed} = mountHook({replies: [filtered]})
  hook.mounted()
  assert.deepEqual([...hook.model.open].sort(), ["folder:1", "root"])
  hook.toggle("folder:1")
  assert.deepEqual(saved(pushed), [])
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
      {...root([folder(1)]), nodes: {root: [folder(1)], "folder:1": [page(2), more]}, open: ["folder:1"]},
      {nodes: {"folder:1": [page(2), page(3)]}},
    ],
  })
  hook.mounted()
  el.dataset.current = "page:3"
  el.dataset.reveal = JSON.stringify(["folder:1"])
  hook.updated()
  assert.deepEqual(pushed.at(-1).payload, {scope: "board", keys: ["folder:1"], only: true, through: "page:3"})
  assert.ok(hook.model.flatten().some(i => i.row.key === "page:3"))
})

test("the arrows walk the rows, stepping over loading rows", () => {
  const model = sample()
  model.kids.delete("page:4")
  const flat = model.flatten()
  // folder:1, folder:2, page:3, page:4, loading, page:6
  assert.deepEqual(keyMove(flat, -1, "ArrowDown", model), {index: 0})
  assert.deepEqual(keyMove(flat, 3, "ArrowDown", model), {index: 5})
  assert.deepEqual(keyMove(flat, 5, "ArrowUp", model), {index: 3})
  assert.deepEqual(keyMove(flat, 0, "ArrowUp", model), {index: 0})
  assert.deepEqual(keyMove(flat, 2, "Home", model), {index: 0})
  assert.deepEqual(keyMove(flat, 0, "End", model), {index: 5})
  assert.equal(keyMove(flat, 0, "x", model), null)
})

test("right opens a shut container or steps into an open one; left shuts or goes up", () => {
  const model = sample()
  model.open.delete("folder:2")
  const flat = model.flatten()
  // folder:1 (open), folder:2 (shut), page:4 (open), page:5, page:6
  assert.deepEqual(keyMove(flat, 1, "ArrowRight", model), {toggle: "folder:2"})
  assert.deepEqual(keyMove(flat, 0, "ArrowRight", model), {index: 1})
  assert.equal(keyMove(flat, 4, "ArrowRight", model), null)
  assert.deepEqual(keyMove(flat, 0, "ArrowLeft", model), {toggle: "folder:1"})
  assert.deepEqual(keyMove(flat, 3, "ArrowLeft", model), {index: 2})
  assert.equal(keyMove(flat, 0, "ArrowLeft", {openable: () => false}) && null, null)
  assert.deepEqual(keyMove(flat, 2, "Enter", model), {open: 2})
})

test("type-ahead finds the next row starting with what was typed, wrapping", () => {
  const flat = sample().flatten()
  assert.equal(typeAhead(flat, -1, "p"), 2)
  assert.equal(typeAhead(flat, 2, "p"), 3)
  assert.equal(typeAhead(flat, 5, "f"), 0)
  assert.equal(typeAhead(flat, 0, "f2"), 1)
  assert.equal(typeAhead(flat, 0, "zz"), -1)
})

function keyHook(rows, dataset = {}) {
  const env = mountHook({dataset, replies: [root(rows)]})
  env.hook.mounted()
  const press = key => {
    const e = {key, preventDefault() { this.prevented = true }}
    env.hook.keydown(e)
    return e
  }
  return {...env, press}
}

test("F2 and Delete act on a page or folder of this board, for a writer", () => {
  const {hook, pushed, press} = keyHook([folder(1), page(2), page(3, {board_id: 9})])
  hook.active = "page:2"
  press("F2")
  press("Delete")
  hook.active = "folder:1"
  press("F2")
  press("Delete")
  hook.active = "page:3"
  press("F2")
  assert.deepEqual(pushed.slice(1).map(p => [p.event, p.payload.id]), [
    ["rename_page", "2"], ["ask_archive_page", "2"], ["rename_folder", "1"], ["ask_delete_folder", "1"],
  ])
})

test("a reader's F2 and Delete do nothing", () => {
  const {hook, pushed, press} = keyHook([page(2)], {canWrite: "false"})
  hook.active = "page:2"
  assert.ok(press("Delete").prevented)
  assert.equal(pushed.length, 1)
})

test("arrows and typing move the highlighted row, which the tree marks", () => {
  const {hook, rowsEl, press} = keyHook([folder(1), page(2), page(3, {title: "Zed"})])
  press("ArrowDown")
  assert.equal(hook.active, "folder:1")
  press("z")
  assert.equal(hook.active, "page:3")
  assert.match(rowsEl.innerHTML, /data-key="page:3"[^>]*>/)
  assert.match(rowsEl.innerHTML, /aria-selected="true"[^>]*data-key="page:3"/)
  assert.equal(rowsEl.attrs["aria-activedescendant"], "wt-row-2")
})

test("Enter on a vault's own folder opens it rather than going anywhere", () => {
  const dir = {kind: "dir", key: "dir:Projects", id: "dir:Projects", title: "Projects", count: 1, board_id: null}
  const {hook, press} = keyHook([dir])
  hook.active = "dir:Projects"
  press("Enter")
  assert.ok(hook.model.open.has("dir:Projects"))
})

test("show where I am opens the way to the page again and scrolls to it", () => {
  const {hook, el, pushed} = mountHook({
    dataset: {current: "page:2", reveal: JSON.stringify(["folder:1"])},
    replies: [{...root([folder(1)]), nodes: {root: [folder(1)], "folder:1": [page(2)]}, reveal: ["folder:1"]}],
  })
  hook.mounted()
  hook.model.open.delete("folder:1")
  el.scrollTop = 500
  hook.revealAgain()
  assert.ok(hook.model.open.has("folder:1"))
  assert.equal(hook.active, "page:2")
  assert.equal(el.scrollTop, 0)
  assert.equal(pushed.length, 1)
})
