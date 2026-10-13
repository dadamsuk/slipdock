// The wiki's tree (see `SlipdockWeb.WikiLive.Index` and `Slipdock.Wiki.Tree`).
//
// Built for a wiki of thousands of pages (W-103 R11), so it is drawn here
// rather than by the server:
//
//   * lazy — the server is asked for a container's rows when it is opened
//     (`tree_load`, `tree_children`), never for every page at once, and a
//     big folder comes a page of rows at a time;
//   * virtualised — only the rows in view (and a few either side) are in
//     the DOM, absolutely placed in a box as tall as the whole list, so a
//     folder of 5,000 notes scrolls like one of fifty.
//
// The server still owns everything that is not drawing: what the filter bar
// lets through, what a drop does to the filing, the folder menu's actions
// (their buttons carry `phx-click`, which LiveView picks up wherever they
// are), and where links go (`data-phx-link`, so opening a page is the same
// patch a server-drawn link makes).
//
// Rows are keyed `root`, `folder:12`, `page:7`, and in a vault's tree
// `vault`, `dir:Projects` and `board:4` too. Keys are the same on every
// board, since ids are, which is what lets the vault's tree be one tree.

export const ROW_HEIGHT = 30
const OVERSCAN = 12
// How long a drag has to hover over a closed folder before it opens.
const HOVER_OPEN_MS = 600
// How long type-ahead keeps what was typed before starting afresh.
const TYPE_AHEAD_MS = 700
// The most open containers kept between visits: an open set is a reader's
// convenience, and a runaway one would make every visit slow.
const MAX_OPEN = 300

export function escapeHtml(text) {
  return String(text ?? "").replace(/[&<>"']/g, c => ({
    "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;",
  })[c])
}

// What the tree knows: each loaded container's rows, and which are open.
export class TreeModel {
  constructor(root = "root") {
    this.root = root
    this.kids = new Map()
    this.open = new Set()
  }

  reset(root) {
    this.root = root
    this.kids = new Map()
  }

  set(key, rows) { this.kids.set(key, rows) }

  // Rows appended where the container's "more" row stood.
  append(key, rows) {
    const had = (this.kids.get(key) || []).filter(r => r.kind !== "more")
    this.kids.set(key, had.concat(rows))
  }

  openable(row) { return row.count > 0 && row.kind !== "more" && row.kind !== "file" }

  // Everything on screen, top to bottom: each open container's rows after
  // it. An open container not loaded yet shows one "loading" row.
  flatten() {
    const out = []
    const walk = (key, depth, parent, seen) => {
      for (const row of this.kids.get(key) || []) {
        const open = this.openable(row) && this.open.has(row.key) && !seen.has(row.key)
        out.push({row, depth, parent: key, open})
        if (!open) continue
        if (this.kids.has(row.key)) {
          walk(row.key, depth + 1, row.key, new Set(seen).add(row.key))
        } else {
          out.push({row: {kind: "loading", key: `loading:${row.key}`, count: 0}, depth: depth + 1, parent: row.key, open: false})
        }
      }
    }
    walk(this.root, 0, null, new Set([this.root]))
    return out
  }

  // Every folder-like key loaded: what "close all" shuts.
  openKeys() { return [...this.open] }
}

// The row the keyboard moves to from `index` (R11.6): `{index}` to move,
// `{toggle: key}` to open or shut, `{open: index}` to follow the row, or
// null for a key the tree does not use. Loading and "more" rows are
// stepped over.
export function keyMove(flat, index, key, model) {
  const usable = i => flat[i] && !["loading", "more"].includes(flat[i].row.kind)
  const step = (from, dir) => {
    for (let i = from + dir; i >= 0 && i < flat.length; i += dir) if (usable(i)) return i
    return from
  }
  const item = flat[index]

  switch (key) {
    case "ArrowDown": return {index: index < 0 ? step(-1, 1) : step(index, 1)}
    case "ArrowUp": return {index: index < 0 ? step(-1, 1) : step(index, -1)}
    case "Home": return {index: step(-1, 1)}
    case "End": return {index: step(flat.length, -1)}
    case "ArrowRight":
      if (!item) return null
      if (model.openable(item.row) && !item.open) return {toggle: item.row.key}
      if (item.open) return {index: step(index, 1)}
      return null
    case "ArrowLeft": {
      if (!item) return null
      if (item.open) return {toggle: item.row.key}
      const parent = flat.findIndex(i => i.row.key === item.parent)
      return parent >= 0 ? {index: parent} : null
    }
    case "Enter": return item ? {open: index} : null
    default: return null
  }
}

// Type-ahead: the next row after `index` whose title starts with what was
// typed, wrapping round to the top; -1 for none.
export function typeAhead(flat, index, typed) {
  const want = typed.toLowerCase()
  for (let n = 1; n <= flat.length; n++) {
    const i = (Math.max(index, -1) + n) % flat.length
    const title = flat[i].row.title
    if (title && title.toLowerCase().startsWith(want)) return i
  }
  return -1
}

// The slice of rows to draw for a scroll position: [start, end).
export function windowRange(scrollTop, height, total, rowHeight = ROW_HEIGHT, overscan = OVERSCAN) {
  const first = Math.floor(Math.max(0, scrollTop) / rowHeight)
  const count = Math.ceil(Math.max(0, height) / rowHeight)
  return [Math.max(0, first - overscan), Math.min(total, first + count + overscan)]
}

// Which part of a row the pointer is over: the top and bottom quarters put
// what is dragged beside the row, the middle puts it inside.
export function dropZone(offsetY, rowHeight = ROW_HEIGHT) {
  if (offsetY < rowHeight * 0.25) return "before"
  if (offsetY > rowHeight * 0.75) return "after"
  return "inside"
}

// The container a drop into `key`'s list lands in, as `tree_move` reads it:
// `folder:` is the top of the wiki. Anything else (a vault's own rows) takes
// no drop.
function intoOf(key) {
  if (key === "root") return "folder:"
  if (/^(folder|page):\d+$/.test(key)) return key
  return null
}

function ancestors(flat, index) {
  const keys = []
  let parent = flat[index].parent
  for (let i = index - 1; i >= 0 && parent; i--) {
    if (flat[i].row.key === parent) {
      keys.push(parent)
      parent = flat[i].parent
    }
  }
  return keys
}

// The nearest folder (or the top) the row at `index` sits in.
function folderAbove(flat, index) {
  let parent = flat[index].parent
  for (let i = index - 1; i >= 0; i--) {
    if (parent === "root" || /^folder:/.test(parent || "")) return parent
    if (flat[i].row.key === parent) parent = flat[i].parent
  }
  return parent === "root" || /^folder:/.test(parent || "") ? parent : null
}

function nextSibling(flat, index, kind) {
  const parent = flat[index].parent
  for (let i = index + 1; i < flat.length; i++) {
    if (flat[i].parent === parent && flat[i].row.kind === kind) return flat[i].row.id
    if (flat[i].depth < flat[index].depth) break
  }
  return null
}

// What dropping row `from` on row `to` (in `zone`) asks the server for:
// `{kind, id, into, before}` as the `tree_move` event takes it, or null for
// a drop that means nothing (on itself, inside itself, on a vault's own
// rows). A folder only ever lands among folders; a page dropped on a page's
// middle becomes part of it.
export function dropIntent(flat, from, to, zone) {
  const dragged = flat[from] && flat[from].row
  const target = flat[to] && flat[to].row
  if (!dragged || !target || from === to) return null
  if (!["page", "folder"].includes(dragged.kind)) return null
  if (ancestors(flat, to).includes(dragged.key)) return null

  const move = (into, before = null) =>
    into ? {kind: dragged.kind, id: String(dragged.id), into, before: before && String(before)} : null

  if (dragged.kind === "folder") {
    if (target.kind === "folder") {
      if (zone === "inside") return move(intoOf(target.key))
      const into = intoOf(flat[to].parent)
      if (!into || into.startsWith("page:")) return null
      return zone === "before" ? move(into, target.id) : move(into, nextSibling(flat, to, "folder"))
    }
    return move(intoOf(folderAbove(flat, to)))
  }

  if (target.kind === "folder") {
    return zone === "inside" ? move(intoOf(target.key)) : move(intoOf(flat[to].parent))
  }
  if (target.kind === "page") {
    if (zone === "inside") return move(intoOf(target.key))
    const into = intoOf(flat[to].parent)
    return zone === "before" ? move(into, target.id) : move(into, nextSibling(flat, to, "page"))
  }
  if (target.kind === "file") return move(intoOf(flat[to].parent))
  return null
}

const ICONS = {
  folder: "hero-folder",
  page: "hero-document-text",
  file: "hero-paper-clip",
  dir: "hero-folder",
}

function rowHtml(item, index, ctx) {
  const {row, depth, open} = item
  const top = index * ROW_HEIGHT
  const pad = 0.25 + depth * 0.75

  if (row.kind === "loading" || row.kind === "more") {
    const label = row.kind === "loading" ? "Loading…" : "Loading more…"
    return `<div class="absolute inset-x-0 flex items-center text-xs text-base-content/40" style="top:${top}px;height:${ROW_HEIGHT}px;padding-left:${pad + 1}rem" data-index="${index}" ${row.kind === "more" ? `data-more="${escapeHtml(item.parent)}" data-offset="${row.offset}"` : ""}>${label}</div>`
  }

  const key = escapeHtml(row.key)
  const current = ctx.current === row.key
  const active = ctx.active === row.key
  // A vault's mapped folders are where another board's wiki is shown, not
  // folders of this one: nothing moves them, and they have no menu.
  const movable = ctx.organising && ["page", "folder"].includes(row.kind) && !row.mount && row.board_id === ctx.board
  const title = escapeHtml(row.title)
  const nav = row.kind === "file"
    ? `target="_blank" rel="noopener"`
    : `data-phx-link="${row.nav === "redirect" ? "redirect" : "patch"}" data-phx-link-state="push"`

  const badges = [
    row.draft ? `<span class="shrink-0 rounded bg-amber-500/15 px-1 text-2xs font-medium text-amber-700">draft</span>` : "",
    row.template ? `<span class="shrink-0 rounded bg-base-content/10 px-1 text-2xs text-base-content/60">template</span>` : "",
    row.archived ? `<span class="shrink-0 rounded bg-base-content/10 px-1 text-2xs text-base-content/60">archived</span>` : "",
    row.kind === "folder" || row.kind === "dir"
      ? `<span class="shrink-0 text-2xs text-base-content/40">${row.pages ?? ""}</span>`
      : "",
  ].join("")

  const chevron = ctx.model.openable(row)
    ? `<button type="button" data-toggle class="shrink-0 py-1.5 pr-0.5" title="${open ? "Close" : "Open"}" aria-label="Open or close"><span class="${open ? "hero-chevron-down" : "hero-chevron-right"} size-3 shrink-0 text-base-content/40"></span></button>`
    : `<span class="w-3.5 shrink-0"></span>`

  const handle = movable
    ? `<span data-drag class="shrink-0 cursor-grab touch-none py-1.5 text-base-content/30 hover:text-base-content/60" title="Drag to move this ${row.kind}"><span class="hero-bars-2 size-3.5"></span></span>`
    : ""

  const menu = row.kind === "folder" && !row.mount && ctx.canWrite && row.board_id === ctx.board
    ? `<button type="button" data-menu class="btn btn-ghost btn-xs btn-square shrink-0 opacity-0 group-hover:opacity-100 focus:opacity-100" title="Folder actions"><span class="hero-ellipsis-horizontal size-3.5"></span></button>`
    : ""

  const classes = [
    "wt-row group absolute inset-x-0 flex items-center gap-1 rounded-lg pr-1 text-sm hover:bg-base-200",
    current ? "bg-base-200 font-medium" : "",
    row.context ? "opacity-60" : "",
    row.archived ? "text-base-content/50" : "",
    active ? "ring-1 ring-inset ring-primary/60" : "",
  ].join(" ")

  return `<div id="wt-row-${index}" class="${classes}" style="top:${top}px;height:${ROW_HEIGHT}px;padding-left:${pad}rem" role="treeitem" ${active ? `aria-selected="true"` : ""} aria-level="${depth + 1}" ${ctx.model.openable(row) ? `aria-expanded="${open}"` : ""} ${current ? `aria-current="page"` : ""} data-key="${key}" data-index="${index}" ${row.href ? "" : "data-dir"}>` +
    handle + chevron +
    `<a href="${escapeHtml(row.href || "#")}" ${nav} class="flex min-w-0 flex-1 items-center gap-1.5 py-1.5" title="${escapeHtml(row.tip || row.title)}">` +
    `<span class="${ICONS[row.kind] || ICONS.page} size-3.5 shrink-0 text-base-content/50"></span>` +
    `<span class="min-w-0 flex-1 truncate ${row.kind === "folder" || row.kind === "dir" ? "font-medium" : ""}">${title}</span>` +
    badges + `</a>` + menu + `</div>`
}

function folderMenuHtml(row, ctx) {
  const id = escapeHtml(row.id)
  const base = `/boards/${ctx.board}/wiki`
  const link = (href, icon, label) =>
    `<li><a href="${href}" data-phx-link="patch" data-phx-link-state="push"><span class="${icon} size-4"></span> ${label}</a></li>`
  const action = (event, attr, icon, label, extra = "") =>
    `<li><button type="button" phx-click="${event}" ${attr}="${id}" class="${extra}"><span class="${icon} size-4"></span> ${label}</button></li>`

  return link(`${base}?folder=${id}`, "hero-folder-open", "Open this folder") +
    link(`${base}/new?folder=${id}`, "hero-document-plus", "New page here") +
    action("new_folder", "phx-value-parent", "hero-folder-plus", "New folder inside") +
    action("rename_folder", "phx-value-id", "hero-pencil", "Rename or move…") +
    action("ask_delete_folder", "phx-value-id", "hero-trash", "Delete folder…", "text-error")
}

function storageGet(key, fallback) {
  try {
    const value = localStorage.getItem(key)
    return value === null ? fallback : JSON.parse(value)
  } catch (_e) { return fallback }
}

function storageSet(key, value) {
  try { localStorage.setItem(key, JSON.stringify(value)) } catch (_e) {}
}

export const WikiTree = {
  mounted() {
    this.model = new TreeModel()
    this.rowsEl = this.el.querySelector("[data-tree-rows]")
    this.menuEl = null
    this.loadingMore = new Set()
    this.version = this.el.dataset.version
    this.scope = this.el.dataset.vault ? storageGet(this.scopeKey(), "board") : "board"

    this.onScroll = () => this.schedule()
    this.el.addEventListener("scroll", this.onScroll, {passive: true})
    this.onResize = () => this.schedule()
    window.addEventListener("resize", this.onResize)

    this.onClick = e => this.click(e)
    this.rowsEl.addEventListener("click", this.onClick)
    // The tree takes the keyboard while it has focus (R11.6), and says so
    // with data-own-keys, which the page-wide shortcuts stand down for.
    this.rowsEl.tabIndex = 0
    this.rowsEl.dataset.ownKeys = ""
    this.onKeyDown = e => this.keydown(e)
    this.rowsEl.addEventListener("keydown", this.onKeyDown)
    this.onPointerDown = e => this.dragStart(e)
    this.rowsEl.addEventListener("pointerdown", this.onPointerDown)
    this.onAway = e => { if (this.menuEl && !this.menuEl.contains(e.target)) this.closeMenu() }
    document.addEventListener("click", this.onAway, true)

    this.el.addEventListener("click", e => {
      const button = e.target.closest("[data-tree-toggle-all]")
      if (button) { e.preventDefault(); this.toggleAll() }
      const scope = e.target.closest("[data-tree-scope]")
      if (scope) { e.preventDefault(); this.setScope(scope.dataset.treeScope) }
      if (e.target.closest("[data-tree-reveal]")) { e.preventDefault(); this.revealAgain() }
    })

    this.handleEvent("wiki-tree:scope", ({scope}) => this.setScope(scope, false))
    this.load({first: true})
  },

  updated() {
    if (this.el.dataset.version !== this.version) {
      this.version = this.el.dataset.version
      this.load({})
    } else {
      this.reveal()
      this.render()
    }
  },

  destroyed() {
    window.removeEventListener("resize", this.onResize)
    document.removeEventListener("click", this.onAway, true)
    this.endDrag()
  },

  scopeKey() { return `slipdock:wiki-scope:${this.el.dataset.vault}` },

  ctx() {
    return {
      model: this.model,
      board: Number(this.el.dataset.board),
      current: this.el.dataset.current || null,
      active: this.active || null,
      organising: this.el.dataset.organising === "true",
      canWrite: this.el.dataset.canWrite === "true",
    }
  },

  // Asks for the root and whatever this reader had open in this tree (kept
  // on the server, per reader and per tree), and draws the answer. While
  // the filter bar is on, the server sends every level that holds a match
  // and they all open; the reader's own open folders come back when it is
  // off.
  load({first = false, all = false}) {
    this.pushEvent("tree_load", {scope: this.scope, all}, reply => {
      if (!reply || !reply.nodes) return
      this.scope = reply.scope
      this.filtering = reply.filtering
      this.model.reset(reply.root)
      for (const [key, rows] of Object.entries(reply.nodes)) this.model.set(key, rows)

      if (reply.filtering) {
        this.model.open = new Set(Object.keys(reply.nodes))
      } else {
        const kept = Array.isArray(reply.open) ? reply.open : null
        const open = all ? Object.keys(reply.nodes) : (kept || [])
        this.model.open = new Set(open.concat(reply.reveal || []))
        // A first visit to a small wiki opens it all, as the tree always did;
        // a big one opens only the way to what is being looked at.
        if (first && kept === null && reply.small) return this.load({all: true})
        if (all) this.save()
      }
      this.revealed = this.el.dataset.current
      this.render()
      this.scrollToCurrent()
    })
  },

  // Tells the server what is open now, so this tree opens the same way next
  // time, on this machine or another.
  save() {
    if (this.filtering) return
    this.pushEvent("tree_open", {scope: this.scope, keys: [...this.model.open].slice(0, MAX_OPEN)})
  },

  // Opening a container asks for it the first time; shutting one keeps what
  // was loaded, so opening it again is instant.
  toggle(key) {
    if (this.model.open.has(key)) {
      this.model.open.delete(key)
    } else {
      this.model.open.add(key)
      if (!this.model.kids.has(key)) this.fetch([key])
    }
    this.save()
    this.render()
  },

  fetch(keys, then, through) {
    const payload = {scope: this.scope, keys, only: true}
    if (through) payload.through = through
    this.pushEvent("tree_load", payload, reply => {
      if (!reply || !reply.nodes) return
      for (const [key, rows] of Object.entries(reply.nodes)) this.model.set(key, rows)
      // A key the server would not load (gone, or not this reader's) is
      // dropped rather than left loading for ever.
      for (const key of keys) if (!reply.nodes[key]) this.model.open.delete(key)
      this.render()
      if (then) then()
    })
  },

  more(parent, offset) {
    const tag = `${parent}@${offset}`
    if (this.loadingMore.has(tag)) return
    this.loadingMore.add(tag)
    this.pushEvent("tree_children", {scope: this.scope, key: parent, offset}, reply => {
      this.loadingMore.delete(tag)
      if (reply && reply.rows) { this.model.append(parent, reply.rows); this.render() }
    })
  },

  toggleAll() {
    const anyOpen = this.model.flatten().some(item => item.open && item.row.kind !== "page")
    if (anyOpen) {
      this.model.open = new Set()
      this.save()
      this.render()
    } else {
      this.load({all: true})
    }
  },

  setScope(scope, persist = true) {
    if (!this.el.dataset.vault || !["board", "vault"].includes(scope)) return
    this.scope = scope
    if (persist) storageSet(this.scopeKey(), scope)
    this.load({})
  },

  // The way to the page or folder being looked at opens when it changes,
  // asking for whatever on that way is not loaded yet.
  reveal() {
    const current = this.el.dataset.current
    if (!current || current === this.revealed || this.filtering) return
    this.revealed = current
    let path = []
    try { path = JSON.parse(this.el.dataset.reveal || "[]") } catch (_e) {}
    const missing = path.filter(k => !this.model.kids.has(k))
    path.forEach(k => this.model.open.add(k))
    // Its own container may be loaded only part of the way: a big folder
    // comes a page of rows at a time, and the page may be further down.
    const container = path[path.length - 1] || this.model.root
    const shown = () => this.model.flatten().some(i => i.row.key === current)
    const reach = () => {
      if (shown() || !current.startsWith("page:")) return this.scrollToCurrent()
      this.fetch([container], () => this.scrollToCurrent(), current)
    }
    if (missing.length) this.fetch(missing, reach)
    else reach()
  },

  // "Show where I am": the way to the page opened again, and the page
  // scrolled to, after the reader has shut or scrolled it away.
  revealAgain() {
    this.revealed = null
    this.reveal()
    this.active = this.el.dataset.current || this.active
    this.scrollToCurrent(true)
  },

  scrollToCurrent(always = false) {
    const current = this.el.dataset.current
    if (!current) return
    const index = this.model.flatten().findIndex(item => item.row.key === current)
    if (index < 0) return
    const top = this.rowsTop() + index * ROW_HEIGHT
    const view = this.el
    if (always || top < view.scrollTop || top + ROW_HEIGHT > view.scrollTop + view.clientHeight)
      view.scrollTop = Math.max(0, top - view.clientHeight / 3)
    this.render()
  },

  // Where the rows start inside the scrolling pane: below the buttons and
  // notes above them, however tall those are.
  rowsTop() {
    if (!this.rowsEl.getBoundingClientRect) return this.rowsEl.offsetTop || 0
    return this.rowsEl.getBoundingClientRect().top - this.el.getBoundingClientRect().top + this.el.scrollTop
  },

  schedule() {
    if (this.frame) return
    this.frame = requestAnimationFrame(() => { this.frame = null; this.render() })
  },

  render() {
    const ctx = this.ctx()
    this.flat = this.model.flatten()
    const offset = this.rowsTop()
    const [start, end] = windowRange(this.el.scrollTop - offset, this.el.clientHeight, this.flat.length)

    let html = ""
    for (let i = start; i < end; i++) html += rowHtml(this.flat[i], i, ctx)
    this.rowsEl.style.height = `${this.flat.length * ROW_HEIGHT}px`
    this.rowsEl.setAttribute("role", "tree")
    this.rowsEl.innerHTML = html + (this.dragGuide ? this.dragGuide.outerHTML : "")
    const activeIndex = this.active ? this.flat.findIndex(i => i.row.key === this.active) : -1
    if (activeIndex >= start && activeIndex < end) this.rowsEl.setAttribute("aria-activedescendant", `wt-row-${activeIndex}`)
    else if (this.rowsEl.removeAttribute) this.rowsEl.removeAttribute("aria-activedescendant")
    if (this.menuEl) this.rowsEl.appendChild(this.menuEl)
    this.el.dataset.rows = String(this.flat.length)

    // A "more" row in view asks for the next page of its folder.
    this.rowsEl.querySelectorAll("[data-more]").forEach(el =>
      this.more(el.dataset.more, Number(el.dataset.offset)))
    this.updateToggleAll()
  },

  updateToggleAll() {
    const button = this.el.querySelector("[data-tree-toggle-all]")
    if (!button) return
    const anyOpen = (this.flat || []).some(item => item.open && item.row.kind !== "page")
    button.title = anyOpen ? "Close all folders" : "Open all folders"
    const icon = button.querySelector("span")
    if (icon) icon.className = `${anyOpen ? "hero-chevron-double-up" : "hero-chevron-double-down"} size-4`
  },

  click(e) {
    const rowEl = e.target.closest("[data-key]")
    if (!rowEl) return
    const key = rowEl.dataset.key
    // The keyboard carries on from the row clicked.
    this.active = key
    if (this.rowsEl.focus) this.rowsEl.focus({preventScroll: true})
    if (rowEl.dataset.dir !== undefined && !e.target.closest("[data-menu]")) {
      e.preventDefault()
      return this.toggle(key)
    }
    if (e.target.closest("[data-toggle]")) {
      e.preventDefault()
      this.toggle(key)
    } else if (e.target.closest("[data-menu]")) {
      e.preventDefault()
      e.stopPropagation()
      this.openMenu(rowEl)
    }
  },

  keydown(e) {
    if (e.altKey || e.ctrlKey || e.metaKey) return
    const flat = this.flat || []
    let index = this.active ? flat.findIndex(i => i.row.key === this.active) : -1
    const item = flat[index]
    const ctx = this.ctx()
    const mine = item && ctx.canWrite && item.row.board_id === ctx.board && !item.row.mount

    if (e.key === "F2" || e.key === "Delete") {
      e.preventDefault()
      if (!mine || !["page", "folder"].includes(item.row.kind)) return
      const id = String(item.row.id)
      if (e.key === "F2") return item.row.kind === "folder" ? this.pushEvent("rename_folder", {id}) : this.pushEvent("rename_page", {id})
      return item.row.kind === "folder" ? this.pushEvent("ask_delete_folder", {id}) : this.pushEvent("ask_archive_page", {id})
    }

    const move = keyMove(flat, index, e.key, this.model)
    if (move) {
      e.preventDefault()
      if (move.toggle) return this.toggle(move.toggle)
      if (move.open !== undefined) return this.follow(move.open)
      return this.setActive(move.index)
    }

    // Type-ahead: letters jump to the next row starting with them.
    if (e.key.length === 1 && e.key !== " ") {
      e.preventDefault()
      clearTimeout(this.typedTimer)
      this.typed = (this.typed || "") + e.key
      this.typedTimer = setTimeout(() => { this.typed = "" }, TYPE_AHEAD_MS)
      let found = typeAhead(flat, index - (this.typed.length > 1 ? 1 : 0), this.typed)
      if (found < 0 && this.typed.length > 1) {
        this.typed = e.key
        found = typeAhead(flat, index, this.typed)
      }
      if (found >= 0) this.setActive(found)
    }
  },

  setActive(index) {
    const item = (this.flat || [])[index]
    if (!item) return
    this.active = item.row.key
    const top = this.rowsTop() + index * ROW_HEIGHT
    if (top < this.el.scrollTop) this.el.scrollTop = top
    else if (top + ROW_HEIGHT > this.el.scrollTop + this.el.clientHeight) this.el.scrollTop = top + ROW_HEIGHT - this.el.clientHeight
    this.render()
  },

  // Enter: what clicking the row's name does. A vault's own folder has no
  // page of its own, so it opens or shuts instead.
  follow(index) {
    const item = (this.flat || [])[index]
    if (!item) return
    if (!item.row.href) return this.toggle(item.row.key)
    this.setActive(index)
    const link = this.rowsEl.querySelector && this.rowsEl.querySelector(`#wt-row-${index} a`)
    if (link) link.click()
  },

  openMenu(rowEl) {
    this.closeMenu()
    const item = this.flat[Number(rowEl.dataset.index)]
    if (!item) return
    const menu = document.createElement("ul")
    menu.className = "menu absolute right-1 z-40 w-52 rounded-xl bg-base-100 p-1 text-sm shadow-lg ring-1 ring-base-content/10"
    menu.style.top = `${Number(rowEl.dataset.index) * ROW_HEIGHT + ROW_HEIGHT}px`
    menu.dataset.treeMenu = ""
    menu.innerHTML = folderMenuHtml(item.row, this.ctx())
    menu.addEventListener("click", () => setTimeout(() => this.closeMenu(), 0))
    this.menuEl = menu
    this.rowsEl.appendChild(menu)
  },

  closeMenu() {
    if (this.menuEl) this.menuEl.remove()
    this.menuEl = null
  },

  // Organise mode's drag: pointer events rather than the browser's own
  // drag and drop, which a virtual list (whose rows come and go as it
  // scrolls) and a touch screen both defeat.
  dragStart(e) {
    const handle = e.target.closest("[data-drag]")
    if (!handle || e.button > 0) return
    const rowEl = handle.closest("[data-key]")
    e.preventDefault()

    // The dragged row is held by its key, not its place: a folder opening
    // under the drag puts rows above it, and its place changes.
    this.drag = {key: rowEl.dataset.key, x: e.clientX, y: e.clientY, started: false, target: null}
    this.onMove = ev => this.dragMove(ev)
    this.onUp = ev => this.dragEnd(ev)
    window.addEventListener("pointermove", this.onMove)
    window.addEventListener("pointerup", this.onUp)
    window.addEventListener("pointercancel", this.onUp)
  },

  dragMove(e) {
    const drag = this.drag
    if (!drag) return
    if (!drag.started) {
      if (Math.abs(e.clientX - drag.x) + Math.abs(e.clientY - drag.y) < 4) return
      drag.started = true
      this.el.classList.add("wiki-dragging")
      const ghost = document.createElement("div")
      ghost.className = "pointer-events-none fixed z-50 rounded-lg bg-base-100 px-2 py-1 text-sm shadow-lg ring-1 ring-primary/40"
      const item = this.flat.find(i => i.row.key === drag.key)
      ghost.textContent = item ? item.row.title : ""
      document.body.appendChild(ghost)
      drag.ghost = ghost
    }
    drag.ghost.style.left = `${e.clientX + 12}px`
    drag.ghost.style.top = `${e.clientY + 8}px`

    // Near the top or bottom edge the tree scrolls, so a drop can reach a
    // folder that is out of view.
    const box = this.el.getBoundingClientRect()
    if (e.clientY < box.top + 24) this.el.scrollTop -= 12
    else if (e.clientY > box.bottom - 24) this.el.scrollTop += 12

    const rowsBox = this.rowsEl.getBoundingClientRect()
    const y = e.clientY - rowsBox.top
    const to = Math.floor(y / ROW_HEIGHT)
    const target = this.flat[to]
    if (!target) { this.setGuide(null); return }
    const zone = dropZone(y - to * ROW_HEIGHT)
    const from = this.flat.findIndex(i => i.row.key === drag.key)
    const intent = from < 0 ? null : dropIntent(this.flat, from, to, zone)
    drag.target = intent
    this.setGuide(intent ? {to, zone, depth: target.depth} : null)

    // Hovering on a shut folder's middle opens it.
    const key = target.row.key
    if (zone === "inside" && this.model.openable(target.row) && !this.model.open.has(key)) {
      if (drag.hoverKey !== key) {
        clearTimeout(drag.hoverTimer)
        drag.hoverKey = key
        drag.hoverTimer = setTimeout(() => { if (this.drag) this.toggle(key) }, HOVER_OPEN_MS)
      }
    } else {
      clearTimeout(drag.hoverTimer)
      drag.hoverKey = null
    }
  },

  setGuide(at) {
    if (!at) {
      this.dragGuide = null
    } else {
      const guide = document.createElement("div")
      const pad = 0.25 + at.depth * 0.75
      if (at.zone === "inside") {
        guide.className = "pointer-events-none absolute inset-x-0 rounded-lg ring-2 ring-primary/60"
        guide.style.cssText = `top:${at.to * ROW_HEIGHT}px;height:${ROW_HEIGHT}px`
      } else {
        const top = (at.to + (at.zone === "after" ? 1 : 0)) * ROW_HEIGHT - 1
        guide.className = "pointer-events-none absolute right-0 h-0.5 rounded bg-primary"
        guide.style.cssText = `top:${top}px;left:${pad}rem`
      }
      guide.dataset.dropGuide = ""
      this.dragGuide = guide
    }
    this.render()
  },

  dragEnd() {
    const drag = this.drag
    this.endDrag()
    if (drag && drag.started && drag.target) this.pushEvent("tree_move", drag.target)
  },

  endDrag() {
    if (!this.drag) return
    clearTimeout(this.drag.hoverTimer)
    if (this.drag.ghost) this.drag.ghost.remove()
    this.drag = null
    this.dragGuide = null
    this.el.classList.remove("wiki-dragging")
    window.removeEventListener("pointermove", this.onMove)
    window.removeEventListener("pointerup", this.onUp)
    window.removeEventListener("pointercancel", this.onUp)
    this.render()
  },
}
