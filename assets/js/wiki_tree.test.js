// node --test assets/js — no browser, so the DOM here is the handful of
// things wiki_tree.js touches, and the server is a pushEvent that answers.
import {test} from "node:test"
import assert from "node:assert/strict"
import {TreeModel, windowRange, dropZone, dropIntent, movableRow, escapeHtml, keyMove, typeAhead, menuItems, WikiTree, ROW_HEIGHT, previewHtml, PREVIEW_MS} from "./wiki_tree.js"

// Rows as the server sends them to a writer on board 1.
const folder = (id, extra = {}) => ({kind: "folder", id, key: `folder:${id}`, title: `F${id}`, count: 1, board_id: 1, writable: true, ...extra})
const page = (id, extra = {}) => ({kind: "page", id, key: `page:${id}`, title: `P${id}`, count: 0, board_id: 1, writable: true, ...extra})

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
  vault.set("vault", [{kind: "dir", key: "dir:Journal", id: "dir:Journal", title: "Journal", count: 1}, page(9)])
  assert.equal(dropIntent(vault.flatten(), 1, 0, "inside"), null)
})

// root: F1 (open: F2 (open: A3.png), P4, A5.png), P6, A7.png
const file = (id, extra = {}) => ({kind: "file", id, key: `file:${id}`, title: `A${id}.png`, count: 0, board_id: 1, writable: true, ...extra})
function withFiles() {
  const model = new TreeModel("root")
  model.set("root", [folder(1), page(6), file(7)])
  model.set("folder:1", [folder(2), page(4), file(5)])
  model.set("folder:2", [file(3)])
  model.open = new Set(["folder:1", "folder:2"])
  return model
}

test("a file dropped on a folder's middle is filed in it (#749)", () => {
  const flat = withFiles().flatten()
  // A7 (index 6) onto F2 (index 1); A3 (index 2) onto F1 (index 0)
  assert.deepEqual(dropIntent(flat, 6, 1, "inside"), {kind: "file", id: "7", into: "folder:2", before: null})
  assert.deepEqual(dropIntent(flat, 2, 0, "inside"), {kind: "file", id: "3", into: "folder:1", before: null})
})

test("a file dropped anywhere else goes to the folder its target is in, never into a page", () => {
  const flat = withFiles().flatten()
  // A7 on P4's middle: P4's folder, F1
  assert.deepEqual(dropIntent(flat, 6, 3, "inside"), {kind: "file", id: "7", into: "folder:1", before: null})
  // A3 beside F1, on P6, or beside A7: the top of the wiki
  assert.deepEqual(dropIntent(flat, 2, 0, "before"), {kind: "file", id: "3", into: "folder:", before: null})
  assert.deepEqual(dropIntent(flat, 2, 5, "inside"), {kind: "file", id: "3", into: "folder:", before: null})
  assert.deepEqual(dropIntent(flat, 2, 6, "after"), {kind: "file", id: "3", into: "folder:", before: null})
  // A5 beside F2: F2 sits in F1, so into F1 — where A5 already is
  assert.equal(dropIntent(flat, 4, 1, "before"), null)
})

test("a file dropped where it already is, or on a vault's own rows, asks for nothing", () => {
  const flat = withFiles().flatten()
  assert.equal(dropIntent(flat, 4, 3, "inside"), null) // A5 on P4, both in F1
  assert.equal(dropIntent(flat, 6, 5, "after"), null) // A7 beside P6, both at the top
  assert.equal(dropIntent(flat, 6, 6, "inside"), null)
  const vault = new TreeModel("vault")
  vault.set("vault", [{kind: "dir", key: "dir:Journal", id: "dir:Journal", title: "Journal", count: 1}, file(9)])
  assert.equal(dropIntent(vault.flatten(), 1, 0, "inside"), null)
})

test("movableRow: a writer's pages, folders and files, never a mount, a placement or a vault row", () => {
  assert.ok(movableRow(page(1)))
  assert.ok(movableRow(folder(1)))
  assert.ok(movableRow(file(1)))
  assert.ok(!movableRow(page(1, {writable: false})))
  assert.ok(!movableRow(file(1, {writable: undefined})))
  assert.ok(!movableRow(folder(1, {mount: true})))
  assert.ok(!movableRow(page(1, {also: true})))
  assert.ok(!movableRow({kind: "dir", key: "dir:Journal", writable: true}))
  assert.ok(!movableRow(null))
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
  globalThis.document = {addEventListener() {}, removeEventListener() {}, createElement: () => ({style: {}, dataset: {}, remove() {}, addEventListener() {}, setAttribute() {}})}
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

test("which tree it is is the server's to say, not a switch the browser remembers (#758)", () => {
  const context = {scope: "vault", root: "board:5", filtering: false, reveal: [], small: false, open: [],
    nodes: {"board:5": [folder(1), {kind: "folder", key: "board:6", id: "board:6", title: "Journal", mount: true, count: 1}]}}
  const {hook, pushed} = mountHook({dataset: {vault: "3"}, replies: [context, {nodes: {"board:6": [page(9)]}}]})
  globalThis.localStorage.setItem("slipdock:wiki-scope:3", JSON.stringify("vault"))
  hook.mounted()
  // Asked for as the board's, whatever was stored; answered as the vault's.
  assert.deepEqual(pushed[0].payload, {scope: "board", all: false})
  assert.equal(hook.scope, "vault")
  assert.equal(hook.model.root, "board:5")
  assert.deepEqual(hook.model.flatten().map(i => i.row.key), ["folder:1", "board:6"])
  hook.toggle("board:6")
  assert.deepEqual(pushed[1].payload, {scope: "vault", keys: ["board:6"], only: true})
})

test("drawing the same rows again leaves the DOM alone; a change redraws", () => {
  const same = root([folder(1), page(2)])
  const {hook, rowsEl} = mountHook({replies: [same, same, root([folder(1), page(3)])]})
  let writes = 0
  let value = ""
  Object.defineProperty(rowsEl, "innerHTML", {get: () => value, set: v => { writes++; value = v }})
  hook.mounted()
  assert.equal(writes, 1)
  // An update of the page, and a reload that brings the same rows back.
  hook.updated()
  hook.load({})
  assert.equal(writes, 1)
  hook.load({})
  assert.equal(writes, 2)
  assert.match(value, /data-key="page:3"/)
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

test("a reload after a move stays where the reader scrolled; a new page is scrolled to", () => {
  const pages = Array.from({length: 60}, (_, i) => page(i + 1))
  const {hook, el} = mountHook({
    dataset: {current: "page:50"},
    replies: [root(pages), root(pages), root(pages)],
  })
  hook.mounted()
  const atCurrent = el.scrollTop
  assert.ok(atCurrent > 0)

  // Scrolled up to drop something there: the reload that follows keeps it.
  el.scrollTop = 0
  el.dataset.version = "2"
  hook.updated()
  assert.equal(hook.model.kids.get("root").length, 60)
  assert.equal(el.scrollTop, 0)

  // A move that came with another page being opened goes to that page.
  el.dataset.current = "page:55"
  el.dataset.version = "3"
  hook.updated()
  assert.ok(el.scrollTop > atCurrent)
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
    replies: [root([folder(1), page(2), page(3, {board_id: 2, writable: false}), folder(4, {mount: true})])],
  })
  hook.mounted()
  const handles = rowsEl.innerHTML.split("data-key=").slice(1).map(r => r.includes("data-drag"))
  assert.deepEqual(handles, [true, true, false, false])
})

test("a row wears the icon and colour the server sends, and the plain one of its kind without (#792)", () => {
  const {hook, rowsEl} = mountHook({replies: [root([
    folder(1, {icon: "hero-light-bulb", tint: "text-amber-500 dark:text-amber-300"}),
    page(2, {icon: "hero-fire"}),
    page(3, {tint: "text-rose-500"}),
    folder(4),
    page(5, {icon: '"><script>'}),
  ])]})
  hook.mounted()
  const rowOf = key => rowsEl.innerHTML.split("data-key=").find(r => r.startsWith(`"${key}"`))
  assert.match(rowOf("folder:1"), /class="hero-light-bulb size-3\.5 shrink-0 text-amber-500 dark:text-amber-300"/)
  assert.doesNotMatch(rowOf("folder:1"), /hero-folder /)
  assert.match(rowOf("page:2"), /class="hero-fire size-3\.5 shrink-0 text-base-content\/50"/)
  assert.match(rowOf("page:3"), /class="hero-document-text size-3\.5 shrink-0 text-rose-500"/)
  assert.match(rowOf("folder:4"), /class="hero-folder size-3\.5 shrink-0 text-base-content\/50"/)
  assert.doesNotMatch(rowOf("page:5"), /<script>/)
})

test("rows from another board open that board's wiki, files open in place in their viewer", () => {
  const file = {kind: "file", id: 5, key: "file:5", title: "a.png", count: 0, board_id: 1, href: "/files/5"}
  const {hook, rowsEl} = mountHook({replies: [root([page(3, {board_id: 2, nav: "redirect"}), file])]})
  hook.mounted()
  assert.match(rowsEl.innerHTML, /data-phx-link="redirect"/)
  const fileRow = rowsEl.innerHTML.split("data-key=").find(r => r.startsWith('"file:5"'))
  assert.match(fileRow, /href="\/files\/5"/)
  assert.doesNotMatch(fileRow, /target="_blank"|data-phx-link/)
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

// A mouse pressing on a row (not a handle): `closest` answers for the row's
// own parts, as the browser would for a press on its title.
function rowPress(rowEl, extra = {}) {
  return {
    pointerType: "mouse", button: 0, clientX: 5, clientY: 5, preventDefault() {},
    target: {closest: sel => (sel === "[data-movable]" || sel === "[data-key]" ? rowEl : null)},
    ...extra,
  }
}

function dragEnv(rows, dataset = {}) {
  const env = mountHook({dataset, replies: [root(rows)]})
  const listeners = {}
  globalThis.window.addEventListener = (type, fn) => { listeners[type] = fn }
  globalThis.window.removeEventListener = type => { delete listeners[type] }
  globalThis.document.body = {appendChild() {}}
  env.el.getBoundingClientRect = () => ({top: 0, bottom: 600})
  env.rowsEl.getBoundingClientRect = () => ({top: 0, left: 0})
  env.hook.mounted()
  return {...env, listeners}
}

test("without organising, a writer's rows drag by a mouse and their links don't (#749)", () => {
  const {rowsEl} = dragEnv([folder(1), page(2), file(3), page(4, {board_id: 2, writable: false})])
  const rows = rowsEl.innerHTML.split("data-key=").slice(1)
  assert.deepEqual(rows.map(r => r.includes("data-movable")), [true, true, true, false])
  assert.deepEqual(rows.map(r => r.includes(`draggable="false"`)), [true, true, true, false])
  // No handles: those are Organise mode's.
  assert.doesNotMatch(rowsEl.innerHTML, /data-drag/)
})

test("a mouse drags a file onto a folder without organising, and the drop opens nothing", () => {
  const {hook, pushed, listeners} = dragEnv([folder(1), page(2), file(3)])
  hook.dragStart(rowPress({dataset: {key: "file:3", index: "2"}}))
  listeners.pointermove({clientX: 20, clientY: 70})
  listeners.pointermove({clientX: 20, clientY: 15}) // F1's middle
  listeners.pointerup({})
  assert.deepEqual(pushed.at(-1), {event: "tree_move", payload: {kind: "file", id: "3", into: "folder:1", before: null}})
  // The release's click lands on a row; it must not open it.
  const click = {prevented: false, preventDefault() { this.prevented = true }, stopPropagation() {}, target: {closest: () => null}}
  hook.click(click)
  assert.ok(click.prevented)
})

test("a mouse press that barely moves is a click, not a drag, and leaves its link in place", () => {
  const {hook, rowsEl, pushed, listeners} = dragEnv([folder(1), page(2)])
  hook.dragStart(rowPress({dataset: {key: "page:2", index: "1"}}))
  listeners.pointermove({clientX: 7, clientY: 6})
  // The rows aren't redrawn: the click to come is on the link pressed.
  rowsEl.innerHTML = "the link pressed"
  listeners.pointerup({})
  assert.equal(rowsEl.innerHTML, "the link pressed")
  assert.equal(pushed.filter(p => p.event === "tree_move").length, 0)
  const click = {prevented: false, preventDefault() { this.prevented = true }, stopPropagation() {}, target: {closest: () => null}}
  hook.click(click)
  assert.ok(!click.prevented)
})

test("no row drag from a toggle, a menu button, a modifier click, a reader's row or a finger", () => {
  const {hook, listeners} = dragEnv([folder(1), page(2)])
  const rowEl = {dataset: {key: "page:2", index: "1"}}
  const onPart = part => ({closest: sel => (sel === part || sel === "[data-movable]" || sel === "[data-key]" ? rowEl : null)})
  hook.dragStart(rowPress(rowEl, {target: onPart("[data-toggle], [data-menu]")}))
  assert.equal(hook.drag, undefined)
  hook.dragStart(rowPress(rowEl, {ctrlKey: true}))
  hook.dragStart(rowPress(rowEl, {shiftKey: true}))
  hook.dragStart(rowPress(rowEl, {button: 2}))
  hook.dragStart(rowPress(rowEl, {pointerType: "pen"}))
  assert.equal(hook.drag, undefined)
  // A reader's row has no data-movable.
  hook.dragStart(rowPress(rowEl, {target: {closest: sel => (sel === "[data-key]" ? rowEl : null)}}))
  assert.equal(hook.drag, undefined)
  // A finger on a row is a press for the menu, not a drag.
  hook.dragStart(rowPress(rowEl, {pointerType: "touch"}))
  assert.equal(hook.drag, undefined)
  clearTimeout(hook.pressTimer)
  listeners.pointerup({type: "pointerup"})
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
  const {hook, pushed, press} = keyHook([folder(1), page(2), page(3, {board_id: 9, writable: false})])
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
  const {hook, pushed, press} = keyHook([page(2, {writable: false})], {canWrite: "false"})
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

const labels = items => items.map(i => i.label)

test("a page's menu, for a writer", () => {
  const items = menuItems(page(7, {href: "/boards/1/wiki/p7"}), {board: 1, canWrite: true, selected: new Set()})
  assert.deepEqual(labels(items), [
    "Open", "Open in a new tab", "New note inside", "Rename…", "Move…", "Also file in…", "Tag…", "Copy link", "Archive…",
  ])
  assert.deepEqual(items.find(i => i.label === "Move…").payload, {kind: "move", keys: ["page:7"]})
  assert.equal(items.find(i => i.label === "New note inside").href, "/boards/1/wiki/new?parent=7")
  assert.ok(items.find(i => i.label === "Archive…").danger)
})

test("a folder's menu offers making, sorting and deleting, its sort ticked", () => {
  const items = menuItems(folder(4, {href: "/boards/1/wiki?folder=4", sort: "name"}), {board: 1, canWrite: true, selected: new Set()})
  assert.ok(labels(items).includes("New note here"))
  assert.ok(labels(items).includes("New folder inside"))
  assert.ok(labels(items).includes("New drawing here"))
  assert.ok(labels(items).includes("Delete folder…"))
  assert.equal(items.find(i => i.label === "Sort: By name").icon, "hero-check")
  assert.deepEqual(items.find(i => i.label === "Sort: Newest first").payload, {key: "folder:4", sort: "created"})
  assert.deepEqual(items.find(i => i.label === "New drawing here").payload, {key: "folder:4"})
})

test("a folder with no sort of its own ticks Same as the top, and can go back to it (#789)", () => {
  const items = menuItems(folder(4, {href: "/boards/1/wiki?folder=4"}), {board: 1, canWrite: true, selected: new Set()})
  const sorts = items.filter(i => i.group === "sort")
  assert.deepEqual(sorts.map(i => i.label), ["Sort: Same as the top", "Sort: As arranged", "Sort: By name", "Sort: Last changed first", "Sort: Newest first"])
  assert.deepEqual(sorts.filter(i => i.icon === "hero-check").map(i => i.label), ["Sort: Same as the top"])
  assert.deepEqual(sorts[0].payload, {key: "folder:4", sort: "board"})
  const manual = menuItems(folder(4, {href: "/x", sort: "manual"}), {board: 1, canWrite: true, selected: new Set()})
  assert.equal(manual.find(i => i.label === "Sort: As arranged").icon, "hero-check")
})

test("the top of the tree is by name until another sort is chosen (#789)", () => {
  const root = {kind: "root", key: "root"}
  const ticked = ctx => menuItems(root, {board: 1, canWrite: true, selected: new Set(), ...ctx}).filter(i => i.icon === "hero-check").map(i => i.label)
  assert.deepEqual(ticked({}), ["Sort: By name"])
  assert.deepEqual(ticked({rootSort: "manual"}), ["Sort: As arranged"])
})

test("a reader only opens and copies; another board's folder makes no folders here", () => {
  const reader = menuItems(page(7, {writable: false, href: "/x"}), {board: 1, canWrite: false, selected: new Set()})
  assert.deepEqual(labels(reader), ["Open", "Open in a new tab", "Copy link"])
  const theirs = menuItems(folder(4, {board_id: 2, href: "/y", nav: "redirect"}), {board: 1, canWrite: true, selected: new Set()})
  assert.ok(!labels(theirs).includes("New folder inside"))
  assert.equal(theirs.find(i => i.label === "Open").nav, "redirect")
  assert.ok(!labels(menuItems(page(8, {board_id: 2}), {board: 1, canWrite: true, selected: new Set()})).includes("Tag…"))
})

test("a file's menu archives or deletes it, for a writer only (#769)", () => {
  const items = menuItems(file(5, {href: "/files/5"}), {board: 1, canWrite: true, selected: new Set()})
  assert.deepEqual(labels(items), ["Open in a new tab", "Copy link", "Archive…", "Delete…"])
  assert.deepEqual(items.find(i => i.label === "Archive…"), {label: "Archive…", icon: "hero-archive-box", event: "ask_archive_file", payload: {id: "5"}, danger: true, group: "danger"})
  assert.equal(items.find(i => i.label === "Delete…").event, "ask_delete_file")
  assert.deepEqual(items.find(i => i.label === "Delete…").payload, {id: "5"})
  const reader = menuItems(file(5, {href: "/files/5", writable: false}), {board: 1, canWrite: false, selected: new Set()})
  assert.deepEqual(labels(reader), ["Open in a new tab", "Copy link"])
})

test("Delete on a file asks to archive it; F2 on a file and keys on another board's file do nothing", () => {
  const {hook, pushed, press} = keyHook([file(5), file(6, {board_id: 9, writable: false})])
  hook.active = "file:5"
  assert.ok(press("F2").prevented)
  press("Delete")
  hook.active = "file:6"
  press("Delete")
  assert.deepEqual(pushed.slice(1).map(p => [p.event, p.payload.id]), [["ask_archive_file", "5"]])
})

test("with several picked, the menu acts on all of them", () => {
  const selected = new Set(["page:7", "page:8", "folder:4"])
  const items = menuItems(page(7), {board: 1, canWrite: true, selected})
  assert.deepEqual(labels(items), ["Move 3…", "Tag 3…", "Archive 3…"])
  assert.deepEqual(items[2].payload, {kind: "archive", keys: ["page:7", "page:8", "folder:4"]})
})

test("the background's menu makes things at the top, and a vault's own rows have none", () => {
  const root = menuItems({kind: "root"}, {board: 1, canWrite: true, rootSort: "modified"})
  assert.deepEqual(labels(root).slice(0, 3), ["New note", "New folder", "New drawing"])
  assert.equal(root.find(i => i.label === "Sort: Last changed first").icon, "hero-check")
  assert.deepEqual(menuItems({kind: "dir", key: "dir:X"}, {board: 1, canWrite: true}), [])
  assert.deepEqual(menuItems(folder(3, {mount: true}), {board: 1, canWrite: true}), [])
})

test("Ctrl-click and Shift-click pick rows, and the bar acts on them", () => {
  const {hook, pushed} = mountHook({replies: [root([folder(1), page(2), page(3), page(4, {writable: false})])]})
  const bar = {innerHTML: "", addEventListener() {}}
  const find = hook.el.querySelector
  hook.el.querySelector = sel => (sel === "#wiki-tree-selection" ? bar : find(sel))
  hook.mounted()
  const rowClick = (key, mods = {}) => hook.click({
    ...mods, preventDefault() {}, stopPropagation() {},
    target: {closest: sel => (sel === "[data-key]" ? {dataset: {key}} : null)},
  })
  rowClick("folder:1", {ctrlKey: true})
  rowClick("page:4", {shiftKey: true})
  assert.deepEqual([...hook.selected], ["folder:1", "page:2", "page:3"])
  rowClick("page:2", {metaKey: true})
  assert.deepEqual([...hook.selected], ["folder:1", "page:3"])
  hook.selectionEl = bar
  hook.renderSelection()
  assert.match(bar.innerHTML, /2 picked/)
  hook.selectionAction({preventDefault() {}, target: {closest: () => ({dataset: {sel: "archive"}})}})
  assert.deepEqual(pushed.at(-1), {event: "tree_dialog", payload: {kind: "archive", keys: ["folder:1", "page:3"]}})
  rowClick("page:3")
  assert.equal(hook.selected.size, 0)
})

test("a menu item's event goes to the server; copy and new tab stay here", () => {
  const {hook, pushed} = mountHook({replies: [root([page(7, {href: "/boards/1/wiki/p7"})])]})
  hook.mounted()
  let copied = null
  let opened = null
  Object.defineProperty(globalThis, "navigator", {value: {clipboard: {writeText: t => { copied = t }}}, configurable: true})
  globalThis.window.location = {href: "https://example.test/boards/1/wiki"}
  globalThis.window.open = url => { opened = url }
  hook.menuItems = menuItems(page(7, {href: "/boards/1/wiki/p7"}), {board: 1, canWrite: true, selected: new Set()})
  const ev = {preventDefault() {}, stopPropagation() {}}
  hook.menuAction(ev, labels(hook.menuItems).indexOf("Rename…"))
  assert.deepEqual(pushed.at(-1), {event: "rename_page", payload: {id: "7"}})
  hook.menuItems = menuItems(page(7, {href: "/boards/1/wiki/p7"}), {board: 1, canWrite: true, selected: new Set()})
  hook.menuAction(ev, labels(hook.menuItems).indexOf("Copy link"))
  assert.equal(copied, "https://example.test/boards/1/wiki/p7")
  hook.menuItems = menuItems(page(7, {href: "/boards/1/wiki/p7"}), {board: 1, canWrite: true, selected: new Set()})
  hook.menuAction(ev, 1)
  assert.equal(opened, "https://example.test/boards/1/wiki/p7")
})

test("a page also filed in a folder is marked, cannot be dragged, and can be taken out", () => {
  const also = page(7, {also: true, placed_in: 4, href: "/boards/1/wiki/p7"})
  const {rowsEl} = (() => {
    const env = mountHook({dataset: {organising: "true"}, replies: [root([also])]})
    env.hook.mounted()
    return env
  })()
  assert.match(rowsEl.innerHTML, /hero-link size-3/)
  assert.doesNotMatch(rowsEl.innerHTML, /data-drag/)
  const items = menuItems(also, {board: 1, canWrite: true, selected: new Set()})
  assert.deepEqual(labels(items), ["Open", "Open in a new tab", "Take out of this folder", "Copy link"])
  assert.deepEqual(items[2].payload, {id: "7", folder: "4"})
  assert.deepEqual(labels(menuItems({...also, writable: false}, {board: 1, canWrite: false})), ["Open", "Open in a new tab", "Copy link"])
})

test("on a touch screen the rows are taller", () => {
  const {hook, rowsEl} = mountHook({replies: [root([page(1), page(2)])]})
  globalThis.window.matchMedia = q => ({matches: q === "(pointer: coarse)"})
  hook.mounted()
  delete globalThis.window.matchMedia
  assert.equal(hook.rowH, 40)
  assert.equal(rowsEl.style.height, "80px")
  assert.match(rowsEl.innerHTML, /top:40px;height:40px/)
})

test("a finger resting on a row opens its menu, and the lift does not follow the link", async () => {
  const {hook, rowsEl} = mountHook({replies: [root([page(7, {href: "/x"})])]})
  const listeners = {}
  globalThis.window.addEventListener = (type, fn) => { listeners[type] = fn }
  globalThis.window.removeEventListener = type => { delete listeners[type] }
  rowsEl.getBoundingClientRect = () => ({top: 0, left: 0})
  hook.el.getBoundingClientRect = () => ({top: 0, bottom: 600})
  hook.mounted()
  const rowEl = {dataset: {key: "page:7", index: "0"}}
  hook.dragStart({pointerType: "touch", clientX: 20, clientY: 10, button: 0, target: {closest: sel => (sel === "[data-key]" ? rowEl : null)}})
  await new Promise(r => setTimeout(r, 560))
  assert.ok(hook.menuEl)
  assert.deepEqual(labels(hook.menuItems).slice(0, 2), ["Open", "Open in a new tab"])
  // The click the lift makes lands outside the menu, and must not shut it.
  hook.onAway({target: {}})
  assert.ok(hook.menuEl)
  const click = {prevented: false, preventDefault() { this.prevented = true }, stopPropagation() {}, target: {closest: sel => (sel === "[data-key]" ? rowEl : null)}}
  hook.click(click)
  assert.ok(click.prevented)
})

test("a finger that moves is scrolling, not pressing", async () => {
  const {hook, rowsEl} = mountHook({replies: [root([page(7)])]})
  const listeners = {}
  globalThis.window.addEventListener = (type, fn) => { listeners[type] = fn }
  globalThis.window.removeEventListener = type => { delete listeners[type] }
  rowsEl.getBoundingClientRect = () => ({top: 0, left: 0})
  hook.el.getBoundingClientRect = () => ({top: 0, bottom: 600})
  hook.mounted()
  const rowEl = {dataset: {key: "page:7", index: "0"}}
  hook.dragStart({pointerType: "touch", clientX: 20, clientY: 10, button: 0, target: {closest: sel => (sel === "[data-key]" ? rowEl : null)}})
  listeners.pointermove({type: "pointermove", clientX: 20, clientY: 60})
  await new Promise(r => setTimeout(r, 560))
  assert.equal(hook.menuEl, null)
})

test("a tree that was hidden draws itself, at the page, when it is opened as a drawer", () => {
  const {hook, el} = mountHook({dataset: {current: "page:1"}, replies: [root([page(1)])]})
  el.clientHeight = 0
  hook.mounted()
  const scrolled = []
  hook.scrollToCurrent = always => scrolled.push(always)
  hook.updated()
  assert.deepEqual(scrolled, [])
  el.clientHeight = 600
  hook.updated()
  assert.deepEqual(scrolled, [true])
  hook.updated()
  assert.deepEqual(scrolled, [true])
})

test("a folder offers its own board to the vault's owner only (#747)", () => {
  const row = folder(4, {href: "/boards/1/wiki?folder=4"})
  const owner = menuItems(row, {board: 1, canWrite: true, vaultOwner: true, selected: new Set()})
  const item = owner.find(i => i.label === "Give it its own board…")
  assert.deepEqual(item && item.payload, {id: "4"})
  assert.equal(item.event, "split_folder")

  const other = menuItems(row, {board: 1, canWrite: true, vaultOwner: false, selected: new Set()})
  assert.ok(!labels(other).includes("Give it its own board…"))

  const page7 = menuItems(page(7, {href: "/boards/1/wiki/p7"}), {board: 1, canWrite: true, vaultOwner: true, selected: new Set()})
  assert.ok(!labels(page7).includes("Give it its own board…"))
})

// A page's preview (#760).

const preview = (extra = {}) => ({found: true, key: "page:7", title: "Plans", paragraphs: ["First.", "Second."], tags: [], children: 0, ...extra})

test("a preview shows the title, the start of the body, tags and who changed it", () => {
  const html = previewHtml(preview({summary: "In short", tags: ["work"], code: "W-7", updated: "2h ago", updated_by: "Ann", children: 2, board: "Journal", draft: true}))
  assert.match(html, /Plans/)
  assert.match(html, /In short/)
  assert.match(html, /<p class="mb-1.5 last:mb-0">First.<\/p><p class="mb-1.5 last:mb-0">Second.<\/p>/)
  assert.match(html, /#work/)
  assert.match(html, /W-7 · Changed 2h ago by Ann · 2 pages inside/)
  assert.match(html, /Journal/)
  assert.match(html, />draft</)
})

test("a preview of an empty page says so, one page inside reads singular, and nothing is injected", () => {
  assert.match(previewHtml(preview({paragraphs: []})), /Nothing written yet/)
  assert.doesNotMatch(previewHtml(preview({paragraphs: [], summary: "S"})), /Nothing written yet/)
  assert.match(previewHtml(preview({children: 1})), /1 page inside/)
  assert.doesNotMatch(previewHtml(preview()), /inside|Changed/)
  const html = previewHtml(preview({title: "<img onerror=x>", paragraphs: ["<script>"], tags: ["<b>"], updated_by: "<i>", updated: "now"}))
  assert.doesNotMatch(html, /<img|<script|<b>|<i>/)
})

function previewHook(replies) {
  const made = []
  const mounted = mountHook({replies: [root([page(7), page(8), folder(1)]), ...replies]})
  globalThis.document.createElement = () => {
    const el = {style: {}, dataset: {}, hidden: false, attrs: {}, setAttribute(k, v) { this.attrs[k] = v }, remove() { this.removed = true }}
    made.push(el)
    return el
  }
  globalThis.document.body = {appendChild() {}}
  mounted.hook.mounted()
  return {...mounted, made}
}

const over = (key, pointerType = "mouse") => ({pointerType, target: {closest: () => ({dataset: {key}, getBoundingClientRect: () => ({top: 40})})}})
const wait = ms => new Promise(r => setTimeout(r, ms))

test("the mouse resting on a page row asks for its preview once and draws it beside the tree", async () => {
  const {hook, pushed, made, rowsEl} = previewHook([preview({title: "Seven"})])
  hook.el.getBoundingClientRect = () => ({right: 256})
  hook.hoverRow(over("page:7"))
  assert.equal(pushed.filter(p => p.event === "tree_preview").length, 0)
  await wait(PREVIEW_MS + 20)
  assert.deepEqual(pushed.at(-1), {event: "tree_preview", payload: {key: "page:7"}})
  assert.match(made[0].innerHTML, /Seven/)
  assert.equal(made[0].hidden, false)
  assert.equal(made[0].style.left, "264px")
  assert.equal(made[0].style.top, "40px")
  assert.equal(rowsEl.attrs["aria-describedby"], "wiki-tree-preview")

  // Off the rows it goes; back on, it comes from what was kept.
  hook.onLeave()
  assert.equal(made[0].hidden, true)
  hook.hoverRow(over("page:7"))
  await wait(PREVIEW_MS + 20)
  assert.equal(pushed.filter(p => p.event === "tree_preview").length, 1)
  assert.equal(made[0].hidden, false)
})

test("moving on before the preview shows, a folder, a finger or a missing page shows nothing", async () => {
  const {hook, pushed, made} = previewHook([{found: false}])
  hook.hoverRow(over("page:7"))
  hook.hoverRow(over("folder:1"))
  hook.hoverRow(over("page:8", "touch"))
  await wait(PREVIEW_MS + 20)
  assert.equal(pushed.filter(p => p.event === "tree_preview").length, 0)
  hook.hoverRow(over("page:8"))
  await wait(PREVIEW_MS + 20)
  assert.deepEqual(pushed.at(-1).payload, {key: "page:8"})
  assert.equal(made.length, 0)
})

test("a reply that comes after the mouse has gone draws nothing", async () => {
  let answer
  const {hook, made} = previewHook([])
  hook.pushEvent = (event, payload, reply) => { answer = reply }
  hook.hoverRow(over("page:7"))
  await wait(PREVIEW_MS + 20)
  hook.onLeave()
  answer(preview())
  assert.equal(made.length, 0)
})

test("Space shows the highlighted page's preview and puts it away; other keys put it away", () => {
  const {hook, pushed, made} = previewHook([preview({title: "Seven"}), preview({key: "page:8", title: "Eight"})])
  const key = k => hook.keydown({key: k, preventDefault() {}})
  hook.active = "page:7"
  key(" ")
  assert.deepEqual(pushed.at(-1), {event: "tree_preview", payload: {key: "page:7"}})
  assert.match(made[0].innerHTML, /Seven/)
  key(" ")
  assert.equal(made[0].hidden, true)
  key(" ")
  assert.equal(made[0].hidden, false)
  key("ArrowDown")
  assert.equal(made[0].hidden, true)
  assert.equal(hook.active, "page:8")
  // A folder has no preview.
  hook.active = "folder:1"
  key(" ")
  assert.equal(made[0].hidden, true)
})

test("a new version of the tree forgets the previews it had", async () => {
  const {hook, pushed, el} = previewHook([preview(), root([page(7)]), preview({title: "New"})])
  hook.preview("page:7", null)
  el.dataset.version = "2"
  hook.updated()
  hook.preview("page:7", null)
  assert.equal(pushed.filter(p => p.event === "tree_preview").length, 2)
})

test("a page row has no browser tooltip; a folder row keeps one", () => {
  const {rowsEl} = previewHook([])
  const link = key => rowsEl.innerHTML.split(`data-key="${key}"`)[1].split("<a ")[1].split(">")[0]
  assert.doesNotMatch(link("page:7"), /title=/)
  assert.match(link("folder:1"), /title="F1"/)
})

test("a writer's folder offers Organise…; a page, a selection and a reader don't (#791)", () => {
  const row = folder(4, {href: "/boards/1/wiki?folder=4"})
  const item = menuItems(row, {board: 1, canWrite: true, selected: new Set()}).find(i => i.label === "Organise…")
  assert.equal(item && item.event, "organise_folder")
  assert.deepEqual(item.payload, {id: "4"})

  const several = menuItems(row, {board: 1, canWrite: true, selected: new Set(["folder:4", "folder:5"])})
  assert.ok(!labels(several).includes("Organise…"))
  const reader = menuItems(folder(4, {writable: false, href: "/x"}), {board: 1, canWrite: false, selected: new Set()})
  assert.ok(!labels(reader).includes("Organise…"))
  assert.ok(!labels(menuItems(page(7, {href: "/x"}), {board: 1, canWrite: true, selected: new Set()})).includes("Organise…"))
})
