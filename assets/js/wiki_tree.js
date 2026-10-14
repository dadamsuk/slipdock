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
// Rows a finger can hit, on a touch screen (R11.11).
export const TOUCH_ROW_HEIGHT = 40
// How long a finger rests on a row before its menu opens.
const LONG_PRESS_MS = 500
const OVERSCAN = 12
// How long a drag has to hover over a closed folder before it opens.
const HOVER_OPEN_MS = 600
// How long type-ahead keeps what was typed before starting afresh.
const TYPE_AHEAD_MS = 700
// The most open containers kept between visits: an open set is a reader's
// convenience, and a runaway one would make every visit slow.
const MAX_OPEN = 300
// How long the mouse rests on a page row before its preview shows (#760).
export const PREVIEW_MS = 450
const PREVIEW_WIDTH = 320

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
  if (/^(folder|page|board):\d+$/.test(key)) return key
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

// Whether a writer can drag the row about: a page, folder or file of a board
// they can write to. A vault's mapped folders are where another board's
// wiki is shown, not folders of this one, and an extra placement is the
// page seen from another folder (it is moved from its home row).
export function movableRow(row) {
  return !!row && ["page", "folder", "file"].includes(row.kind) && !row.mount && !row.also && !!row.writable
}

// What dropping row `from` on row `to` (in `zone`) asks the server for:
// `{kind, id, into, before}` as the `tree_move` event takes it, or null for
// a drop that means nothing (on itself, inside itself, on a vault's own
// rows). A folder only ever lands among folders; a page dropped on a page's
// middle becomes part of it. A file is only ever filed in a folder (or the
// top), the one its target is in, and never part of a page.
export function dropIntent(flat, from, to, zone) {
  const dragged = flat[from] && flat[from].row
  const target = flat[to] && flat[to].row
  if (!dragged || !target || from === to) return null
  if (!["page", "folder", "file"].includes(dragged.kind)) return null
  if (ancestors(flat, to).includes(dragged.key)) return null

  const move = (into, before = null) =>
    into ? {kind: dragged.kind, id: String(dragged.id), into, before: before && String(before)} : null

  if (dragged.kind === "file") {
    const into = target.kind === "folder" && zone === "inside"
      ? intoOf(target.key)
      : intoOf(target.kind === "folder" ? flat[to].parent : folderAbove(flat, to))
    // Where it already is: nothing to ask for.
    if (!into || !into.startsWith("folder:") || into === intoOf(folderAbove(flat, from))) return null
    return move(into)
  }

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
  const top = index * ctx.rowH
  const pad = 0.25 + depth * 0.75

  if (row.kind === "loading" || row.kind === "more") {
    const label = row.kind === "loading" ? "Loading…" : "Loading more…"
    return `<div class="absolute inset-x-0 flex items-center text-xs text-base-content/40" style="top:${top}px;height:${ctx.rowH}px;padding-left:${pad + 1}rem" data-index="${index}" ${row.kind === "more" ? `data-more="${escapeHtml(item.parent)}" data-offset="${row.offset}"` : ""}>${label}</div>`
  }

  const key = escapeHtml(row.key)
  const current = ctx.current === row.key
  const active = ctx.active === row.key
  // A vault's mapped folders have no menu; an extra placement's menu takes
  // the placement away (see movableRow for what drags).
  const movable = movableRow(row)
  const selected = ctx.selected && ctx.selected.has(row.key)
  const title = escapeHtml(row.title)
  // A file opens in place, in its viewer or editor: a page of its own, so
  // an ordinary link rather than a patch of the wiki.
  const nav = row.kind === "file"
    ? ""
    : `data-phx-link="${row.nav === "redirect" ? "redirect" : "patch"}" data-phx-link-state="push"`

  const badges = [
    row.also ? `<span class="hero-link size-3 shrink-0 text-base-content/40" title="Also filed here; its home is another folder"></span>` : "",
    row.draft ? `<span class="shrink-0 rounded bg-amber-500/15 px-1 text-2xs font-medium text-amber-700">draft</span>` : "",
    row.template ? `<span class="shrink-0 rounded bg-base-content/10 px-1 text-2xs text-base-content/60">template</span>` : "",
    row.encrypted ? `<span class="hero-lock-closed size-3 shrink-0 text-base-content/40" title="Holds encrypted text"></span>` : "",
    row.archived ? `<span class="shrink-0 rounded bg-base-content/10 px-1 text-2xs text-base-content/60">archived</span>` : "",
    row.kind === "folder" || row.kind === "dir"
      ? `<span class="shrink-0 text-2xs text-base-content/40">${row.pages ?? ""}</span>`
      : "",
  ].join("")

  const chevron = ctx.model.openable(row)
    ? `<button type="button" data-toggle class="shrink-0 py-1.5 pr-0.5" title="${open ? "Close" : "Open"}" aria-label="Open or close"><span class="${open ? "hero-chevron-down" : "hero-chevron-right"} size-3 shrink-0 text-base-content/40"></span></button>`
    : `<span class="w-3.5 shrink-0"></span>`

  const handle = movable && ctx.organising
    ? `<span data-drag class="shrink-0 cursor-grab touch-none py-1.5 text-base-content/30 hover:text-base-content/60" title="Drag to move this ${row.kind}"><span class="hero-bars-2 size-3.5"></span></span>`
    : ""

  const menu = ["page", "folder", "file"].includes(row.kind) && !row.mount
    ? `<button type="button" data-menu class="btn btn-ghost btn-xs btn-square shrink-0 opacity-0 group-hover:opacity-100 focus:opacity-100 [@media(hover:none)]:opacity-100" title="More (or right-click)"><span class="hero-ellipsis-horizontal size-3.5"></span></button>`
    : ""

  const classes = [
    "wt-row group absolute inset-x-0 flex items-center gap-1 rounded-lg pr-1 text-sm hover:bg-base-200",
    current ? "bg-base-200 font-medium" : "",
    selected ? "bg-primary/10" : "",
    row.context ? "opacity-60" : "",
    row.archived ? "text-base-content/50" : "",
    active ? "ring-1 ring-inset ring-primary/60" : "",
  ].join(" ")

  // A page's name has no browser tooltip: its preview (#760) shows the whole
  // of it, and a tooltip would land on top of the preview.
  return `<div id="wt-row-${index}" class="${classes}" style="top:${top}px;height:${ctx.rowH}px;padding-left:${pad}rem" role="treeitem" ${active ? `aria-selected="true"` : ""} aria-level="${depth + 1}" ${ctx.model.openable(row) ? `aria-expanded="${open}"` : ""} ${current ? `aria-current="page"` : ""} data-key="${key}" data-index="${index}" ${row.href ? "" : "data-dir"} ${movable ? "data-movable" : ""}>` +
    handle + chevron +
    `<a href="${escapeHtml(row.href || "#")}" ${nav} ${movable ? `draggable="false"` : ""} class="flex min-w-0 flex-1 items-center gap-1.5 py-1.5" ${row.kind === "page" ? "" : `title="${escapeHtml(row.title)}"`}>` +
    `<span class="${ICONS[row.kind] || ICONS.page} size-3.5 shrink-0 text-base-content/50"></span>` +
    `<span class="min-w-0 flex-1 truncate ${row.kind === "folder" || row.kind === "dir" ? "font-medium" : ""}">${title}</span>` +
    badges + `</a>` + menu + `</div>`
}

// The card a page row's preview draws (#760), from what `tree_preview`
// answers: the page's summary and the start of its body as plain text, its
// tags, and who changed it and when. Everything in it is escaped.
export function previewHtml(p) {
  const chip = text => `<span class="rounded bg-base-content/10 px-1 text-2xs text-base-content/60">${escapeHtml(text)}</span>`
  const badges = [p.draft && "draft", p.template && "template", p.archived && "archived"].filter(Boolean).map(chip).join("")
  const where = p.board
    ? `<div class="mb-1 flex items-center gap-1 text-2xs text-base-content/50"><span class="hero-squares-2x2 size-3"></span>${escapeHtml(p.board)}</div>`
    : ""
  const summary = p.summary ? `<p class="mb-2 font-medium text-base-content/80">${escapeHtml(p.summary)}</p>` : ""
  const paragraphs = p.paragraphs || []
  const body = paragraphs.length
    ? paragraphs.map(t => `<p class="mb-1.5 last:mb-0">${escapeHtml(t)}</p>`).join("")
    : (p.summary ? "" : `<p class="italic text-base-content/40">Nothing written yet</p>`)
  const tags = (p.tags || []).length
    ? `<div class="mt-2 flex flex-wrap gap-1">${p.tags.map(t => `<span class="rounded bg-primary/10 px-1 text-2xs text-primary">#${escapeHtml(t)}</span>`).join("")}</div>`
    : ""
  const meta = [
    p.code,
    p.updated && `Changed ${p.updated}${p.updated_by ? ` by ${p.updated_by}` : ""}`,
    p.children ? `${p.children} ${p.children === 1 ? "page" : "pages"} inside` : null,
  ].filter(Boolean).map(escapeHtml).join(" · ")

  return where +
    `<div class="mb-1.5 flex items-start gap-1.5"><span class="min-w-0 flex-1 font-semibold leading-snug">${escapeHtml(p.title)}</span>${badges}</div>` +
    summary +
    `<div class="text-base-content/70">${body}</div>` +
    tags +
    (meta ? `<div class="mt-2 border-t border-base-300/70 pt-1.5 text-2xs text-base-content/50">${meta}</div>` : "")
}

const SORTS = [["manual", "As arranged"], ["name", "By name"], ["modified", "Last changed first"], ["created", "Newest first"]]
// A folder with no sort of its own follows the top's (#789), and can be
// set back to that.
const FOLDER_SORTS = [["board", "Same as the top"], ...SORTS]

// What a row's menu offers (R11.10), for whoever is reading: opening and
// copying for anyone, the rest for a writer on the row's board. Each item
// is a link (followed as the tree's own links are), an event for the
// server, or an action done here. `keys` are what a move, archive or tag
// acts on: the whole selection when the row is part of one.
export function menuItems(row, ctx) {
  const selection = ctx.selected && ctx.selected.has(row.key) && ctx.selected.size > 1 ? [...ctx.selected] : [row.key]
  const many = selection.length > 1
  const writable = !!row.writable
  const nav = row.nav === "redirect" ? "redirect" : "patch"
  const base = `/boards/${row.board_id}/wiki`
  const items = []
  const add = (when, item) => { if (when) items.push(item) }
  const id = String(row.id)

  if (row.kind === "root") {
    add(ctx.canWrite, {label: "New note", icon: "hero-document-plus", href: `/boards/${ctx.board}/wiki/new`, nav: "patch"})
    add(ctx.canWrite, {label: "New folder", icon: "hero-folder-plus", event: "new_folder", payload: {}})
    add(ctx.canWrite, {label: "New drawing", icon: "hero-paint-brush", event: "new_drawing", payload: {key: "root"}})
    if (ctx.canWrite) SORTS.forEach(([sort, label]) =>
      items.push({label: `Sort: ${label}`, icon: (ctx.rootSort || "name") === sort ? "hero-check" : "hero-arrows-up-down", event: "set_tree_sort", payload: {key: "root", sort}, group: "sort"}))
    return items
  }

  if (row.mount || row.kind === "dir" || row.kind === "loading" || row.kind === "more") return items

  if (row.kind === "file") {
    add(true, {label: "Open in a new tab", icon: "hero-arrow-top-right-on-square", action: "newTab", href: row.href})
    add(true, {label: "Copy link", icon: "hero-link", action: "copy", href: row.href})
    // Put away, or gone for good (#769): the server asks, and says who may delete.
    add(writable, {label: "Archive…", icon: "hero-archive-box", event: "ask_archive_file", payload: {id}, danger: true, group: "danger"})
    add(writable, {label: "Delete…", icon: "hero-trash", event: "ask_delete_file", payload: {id}, danger: true, group: "danger"})
    return items
  }

  if (row.also) {
    add(true, {label: "Open", icon: "hero-document-text", href: row.href, nav})
    add(true, {label: "Open in a new tab", icon: "hero-arrow-top-right-on-square", action: "newTab", href: row.href})
    add(writable && row.placed_in, {label: "Take out of this folder", icon: "hero-folder-minus", event: "remove_placement", payload: {id, folder: String(row.placed_in)}, group: "edit"})
    add(true, {label: "Copy link", icon: "hero-link", action: "copy", href: row.href, group: "share"})
    return items
  }

  add(!many, {label: "Open", icon: row.kind === "folder" ? "hero-folder-open" : "hero-document-text", href: row.href, nav})
  add(!many, {label: "Open in a new tab", icon: "hero-arrow-top-right-on-square", action: "newTab", href: row.href})

  if (row.kind === "folder") {
    add(writable && !many, {label: "New note here", icon: "hero-document-plus", href: `${base}/new?folder=${id}`, nav, group: "new"})
    add(writable && !many && row.board_id === ctx.board, {label: "New folder inside", icon: "hero-folder-plus", event: "new_folder", payload: {parent: id}, group: "new"})
    add(writable && !many, {label: "New drawing here", icon: "hero-paint-brush", event: "new_drawing", payload: {key: row.key}, group: "new"})
    add(writable && !many, {label: "Rename…", icon: "hero-pencil", event: "rename_folder", payload: {id}, group: "edit"})
    // Its contents to a board of their own, mapped at its vault path (#747):
    // for whoever owns the vault, since it changes the vault's mappings.
    add(writable && !many && ctx.vaultOwner, {label: "Give it its own board…", icon: "hero-arrow-up-on-square-stack", event: "split_folder", payload: {id}, group: "edit"})
  } else {
    add(writable && !many, {label: "New note inside", icon: "hero-document-plus", href: `${base}/new?parent=${id}`, nav, group: "new"})
    add(writable && !many, {label: "Rename…", icon: "hero-pencil", event: "rename_page", payload: {id}, group: "edit"})
  }

  add(writable, {label: many ? `Move ${selection.length}…` : "Move…", icon: "hero-arrow-right-circle", event: "tree_dialog", payload: {kind: "move", keys: selection}, group: "edit"})
  add(writable && row.kind === "page" && !many, {label: "Also file in…", icon: "hero-link", event: "tree_dialog", payload: {kind: "also", keys: [row.key]}, group: "edit"})
  add(writable && row.kind === "page" && row.board_id === ctx.board, {label: many ? `Tag ${selection.length}…` : "Tag…", icon: "hero-tag", event: "tree_dialog", payload: {kind: "tag", keys: selection}, group: "edit"})

  if (row.kind === "folder" && writable && !many) FOLDER_SORTS.forEach(([sort, label]) =>
    items.push({label: `Sort: ${label}`, icon: (row.sort || "board") === sort ? "hero-check" : "hero-arrows-up-down", event: "set_tree_sort", payload: {key: row.key, sort}, group: "sort"}))

  add(!many, {label: "Copy link", icon: "hero-link", action: "copy", href: row.href, group: "share"})

  if (writable) {
    if (row.kind === "folder" && !many) items.push({label: "Delete folder…", icon: "hero-trash", event: "ask_delete_folder", payload: {id}, danger: true, group: "danger"})
    if (row.kind === "page") items.push(many
      ? {label: `Archive ${selection.length}…`, icon: "hero-archive-box", event: "tree_dialog", payload: {kind: "archive", keys: selection}, danger: true, group: "danger"}
      : {label: "Archive…", icon: "hero-archive-box", event: "ask_archive_page", payload: {id}, danger: true, group: "danger"})
  }
  return items
}

function menuHtml(items) {
  let group = null
  return items.map((item, i) => {
    const rule = i > 0 && item.group !== group ? `<li class="my-0.5 border-t border-base-300/70"></li>` : ""
    group = item.group
    const inner = `<span class="${item.icon} size-4"></span> ${escapeHtml(item.label)}`
    const tone = item.danger ? "text-error" : ""
    if (item.href && !item.action)
      return rule + `<li><a href="${escapeHtml(item.href)}" data-phx-link="${item.nav}" data-phx-link-state="push" class="${tone}">${inner}</a></li>`
    return rule + `<li><button type="button" data-menu-item="${i}" class="${tone}">${inner}</button></li>`
  }).join("")
}

export const WikiTree = {
  mounted() {
    this.model = new TreeModel()
    const coarse = typeof window.matchMedia === "function" && window.matchMedia("(pointer: coarse)").matches
    this.rowH = coarse ? TOUCH_ROW_HEIGHT : ROW_HEIGHT
    this.hidden = this.el.clientHeight === 0
    this.rowsEl = this.el.querySelector("[data-tree-rows]")
    this.menuEl = null
    this.loadingMore = new Set()
    this.version = this.el.dataset.version
    // Which tree this is — the board's, or the vault's — is the server's to
    // say (#758); it comes back with every load.
    this.scope = "board"

    this.onScroll = () => { this.hidePreview(); this.schedule() }
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
    // A click anywhere else shuts the menu, except the one a long press ends
    // with, which is what opened it.
    this.onAway = e => { if (this.menuEl && !this.pressed && !this.menuEl.contains(e.target)) this.closeMenu() }
    this.selected = new Set()
    this.selectionEl = this.el.querySelector("#wiki-tree-selection")
    this.onContextMenu = e => this.contextMenu(e)
    // A page row the mouse rests on shows a preview of the page (#760).
    this.previews = new Map()
    this.onOver = e => this.hoverRow(e)
    this.rowsEl.addEventListener("pointerover", this.onOver)
    this.onLeave = () => this.hidePreview()
    this.rowsEl.addEventListener("pointerleave", this.onLeave)
    this.rowsEl.addEventListener("contextmenu", this.onContextMenu)
    if (this.selectionEl) this.selectionEl.addEventListener("click", e => this.selectionAction(e))
    document.addEventListener("click", this.onAway, true)

    this.el.addEventListener("click", e => {
      const button = e.target.closest("[data-tree-toggle-all]")
      if (button) { e.preventDefault(); this.toggleAll() }
      if (e.target.closest("[data-tree-reveal]")) { e.preventDefault(); this.revealAgain() }
    })

    this.load({first: true})
  },

  updated() {
    // Opened as a drawer on a phone: it has a height now, so draw it, at the
    // page being read.
    const shown = this.el.clientHeight > 0
    if (shown && this.hidden) {
      this.hidden = false
      this.render()
      this.scrollToCurrent(true)
    }
    this.hidden = !shown
    if (this.el.dataset.version !== this.version) {
      this.version = this.el.dataset.version
      this.previews = new Map()
      this.hidePreview()
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
    this.hidePreview()
    if (this.previewEl) this.previewEl.remove()
  },

  // The mouse resting on a page row, for a moment, shows its preview; on to
  // another row starts again, and anything that isn't a page shows nothing.
  // Not for a finger, whose resting press opens the row's menu.
  hoverRow(e) {
    if (e.pointerType !== "mouse" || this.drag || this.menuEl) return
    const rowEl = e.target.closest && e.target.closest("[data-key]")
    const key = rowEl && rowEl.dataset.key
    if (key && key === this.previewKey) return
    this.hidePreview()
    if (!key || !key.startsWith("page:")) return
    this.previewKey = key
    this.previewTimer = setTimeout(() => this.preview(key, rowEl), PREVIEW_MS)
  },

  // Asked for once per page while the tree's rows stand: a reload (the
  // version going up) forgets them all.
  preview(key, rowEl) {
    this.previewKey = key
    const show = p => {
      if (this.previewKey !== key || !p || !p.found) return
      this.drawPreview(p, rowEl)
    }
    if (this.previews.has(key)) return show(this.previews.get(key))
    this.pushEvent("tree_preview", {key}, reply => {
      this.previews.set(key, reply)
      show(reply)
    })
  },

  // Beside the tree, level with the row, kept on screen. It takes no
  // pointer, so it never stands between the mouse and the next row.
  drawPreview(p, rowEl) {
    if (!this.previewEl) {
      const el = document.createElement("div")
      el.id = "wiki-tree-preview"
      el.setAttribute("role", "tooltip")
      el.className = "pointer-events-none fixed z-50 max-h-[70vh] overflow-hidden rounded-xl border border-base-300 bg-base-100 p-3 text-sm shadow-xl"
      el.style.width = `${PREVIEW_WIDTH}px`
      document.body.appendChild(el)
      this.previewEl = el
    }
    const el = this.previewEl
    el.innerHTML = previewHtml(p)
    el.dataset.key = p.key
    el.hidden = false
    const winW = window.innerWidth || 1024
    const winH = window.innerHeight || 768
    const tree = this.el.getBoundingClientRect ? this.el.getBoundingClientRect() : {right: 0}
    const row = rowEl && rowEl.getBoundingClientRect ? rowEl.getBoundingClientRect() : {top: 8}
    const left = Math.max(8, Math.min(tree.right + 8, winW - PREVIEW_WIDTH - 8))
    const top = Math.max(8, Math.min(row.top, winH - (el.offsetHeight || 0) - 8))
    el.style.left = `${left}px`
    el.style.top = `${top}px`
    this.rowsEl.setAttribute("aria-describedby", el.id)
  },

  hidePreview() {
    clearTimeout(this.previewTimer)
    this.previewKey = null
    if (this.previewEl) this.previewEl.hidden = true
    if (this.rowsEl && this.rowsEl.removeAttribute) this.rowsEl.removeAttribute("aria-describedby")
  },


  ctx() {
    return {
      model: this.model,
      board: Number(this.el.dataset.board),
      current: this.el.dataset.current || null,
      active: this.active || null,
      selected: this.selected,
      rowH: this.rowH,
      rootSort: this.rootSort,
      organising: this.el.dataset.organising === "true",
      canWrite: this.el.dataset.canWrite === "true",
      vaultOwner: this.el.dataset.vaultOwner === "true",
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
      this.rootSort = reply.sort
      // What was picked was acted on, or the tree changed under it.
      this.selected = new Set()
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
    const top = this.rowsTop() + index * this.rowH
    const view = this.el
    if (always || top < view.scrollTop || top + this.rowH > view.scrollTop + view.clientHeight)
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
    const [start, end] = windowRange(this.el.scrollTop - offset, this.el.clientHeight, this.flat.length, this.rowH)

    let html = ""
    for (let i = start; i < end; i++) html += rowHtml(this.flat[i], i, ctx)
    this.rowsEl.style.height = `${this.flat.length * this.rowH}px`
    this.rowsEl.setAttribute("role", "tree")
    // Only what changed is drawn again. Every update of the page calls this,
    // and so does a reload after anything on the board changes (a sync, an
    // agent writing): rows replaced with the same rows still flicker, drop
    // the hover, and restart a press, so the same rows are left alone.
    const drawn = html + (this.dragGuide ? this.dragGuide.outerHTML : "")
    if (drawn !== this.drawn) {
      this.rowsEl.innerHTML = drawn
      this.drawn = drawn
    }
    const activeIndex = this.active ? this.flat.findIndex(i => i.row.key === this.active) : -1
    if (activeIndex >= start && activeIndex < end) this.rowsEl.setAttribute("aria-activedescendant", `wt-row-${activeIndex}`)
    else if (this.rowsEl.removeAttribute) this.rowsEl.removeAttribute("aria-activedescendant")
    if (this.menuEl) this.rowsEl.appendChild(this.menuEl)
    this.el.dataset.rows = String(this.flat.length)

    this.renderSelection()

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
    this.hidePreview()
    const menuItem = e.target.closest("[data-menu-item]")
    if (menuItem) return this.menuAction(e, Number(menuItem.dataset.menuItem))
    if ((this.pressed && !e.target.closest("[data-tree-menu]")) || this.dragged) {
      e.preventDefault()
      e.stopPropagation()
      return
    }
    const rowEl = e.target.closest("[data-key]")
    if (!rowEl) return
    const key = rowEl.dataset.key
    if (this.rowsEl.focus) this.rowsEl.focus({preventScroll: true})

    // Ctrl/Cmd-click picks a row, Shift-click every row from the last one.
    if ((e.ctrlKey || e.metaKey || e.shiftKey) && !e.target.closest("[data-toggle]")) {
      e.preventDefault()
      e.stopPropagation()
      this.pick(key, e.shiftKey)
      this.active = key
      return this.render()
    }
    if (this.selected.size && !e.target.closest("[data-menu]")) this.selected = new Set()
    // The keyboard carries on from the row clicked.
    this.active = key
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
    const mine = item && item.row.writable && !item.row.mount

    // Space shows the highlighted page's preview, or puts it away (#760);
    // any other key puts it away.
    if (e.key === " ") {
      e.preventDefault()
      if (!item || item.row.kind !== "page" || this.previewKey === item.row.key) return this.hidePreview()
      this.hidePreview()
      const rowEl = this.rowsEl.querySelector && this.rowsEl.querySelector(`#wt-row-${index}`)
      return this.preview(item.row.key, rowEl)
    }
    this.hidePreview()

    if (e.key === "Escape" && (this.selected.size || this.menuEl)) {
      e.preventDefault()
      this.closeMenu()
      this.selected = new Set()
      return this.render()
    }

    if (e.key === "F2" || e.key === "Delete") {
      e.preventDefault()
      if (!mine) return
      const id = String(item.row.id)
      if (item.row.kind === "file") return e.key === "Delete" ? this.pushEvent("ask_archive_file", {id}) : undefined
      if (!["page", "folder"].includes(item.row.kind)) return
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
    const top = this.rowsTop() + index * this.rowH
    if (top < this.el.scrollTop) this.el.scrollTop = top
    else if (top + this.rowH > this.el.scrollTop + this.el.clientHeight) this.el.scrollTop = top + this.rowH - this.el.clientHeight
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

  // Ctrl/Cmd-click adds or takes away one row; Shift-click takes in every
  // row from the last one picked. Only rows that can be moved, archived or
  // tagged are picked.
  pick(key, range) {
    const flat = this.flat || []
    const pickable = i => ["page", "folder"].includes(i.row.kind) && i.row.writable && !i.row.mount
    if (range && this.active) {
      const a = flat.findIndex(i => i.row.key === this.active)
      const b = flat.findIndex(i => i.row.key === key)
      if (a >= 0 && b >= 0) {
        flat.slice(Math.min(a, b), Math.max(a, b) + 1).filter(pickable).forEach(i => this.selected.add(i.row.key))
        return
      }
    }
    const item = flat.find(i => i.row.key === key)
    if (!item || !pickable(item)) return
    if (this.selected.has(key)) this.selected.delete(key)
    else this.selected.add(key)
  },

  renderSelection() {
    if (!this.selectionEl) return
    const n = this.selected ? this.selected.size : 0
    this.selectionEl.innerHTML = n === 0 ? "" :
      `<div class="mb-2 flex flex-wrap items-center gap-1 rounded-lg bg-primary/10 px-2 py-1 text-xs shadow-sm">` +
      `<span class="mr-auto font-medium">${n} picked</span>` +
      `<button type="button" data-sel="move" class="btn btn-ghost btn-xs">Move…</button>` +
      `<button type="button" data-sel="archive" class="btn btn-ghost btn-xs">Archive…</button>` +
      `<button type="button" data-sel="tag" class="btn btn-ghost btn-xs">Tag…</button>` +
      `<button type="button" data-sel="clear" class="btn btn-ghost btn-xs btn-square" title="Let go (Esc)" aria-label="Let go"><span class="hero-x-mark size-3.5"></span></button>` +
      `</div>`
  },

  selectionAction(e) {
    const button = e.target.closest("[data-sel]")
    if (!button) return
    e.preventDefault()
    const kind = button.dataset.sel
    if (kind === "clear") {
      this.selected = new Set()
      return this.render()
    }
    this.pushEvent("tree_dialog", {kind, keys: [...this.selected]})
  },

  contextMenu(e) {
    const rowEl = e.target.closest("[data-key]")
    const box = this.rowsEl.getBoundingClientRect()
    const at = {x: e.clientX - box.left, y: e.clientY - box.top}
    if (rowEl) {
      e.preventDefault()
      return this.openMenu(rowEl, at)
    }
    // The tree's own background: what can be made at its top.
    if (this.scope === "board" && this.ctx().canWrite) {
      e.preventDefault()
      this.showMenu(menuItems({kind: "root"}, this.ctx()), at)
    }
  },

  openMenu(rowEl, at) {
    this.hidePreview()
    const item = this.flat[Number(rowEl.dataset.index)]
    if (!item) return
    if (this.selected.size && !this.selected.has(item.row.key)) this.selected = new Set()
    const top = Number(rowEl.dataset.index) * this.rowH + this.rowH
    this.showMenu(menuItems(item.row, this.ctx()), at || {y: top})
  },

  showMenu(items, at) {
    this.closeMenu()
    if (!items.length) return
    const menu = document.createElement("ul")
    menu.className = "menu absolute z-40 w-56 rounded-xl bg-base-100 p-1 text-sm shadow-lg ring-1 ring-base-content/10"
    menu.style.top = `${at.y}px`
    if (at.x !== undefined) menu.style.left = `${Math.max(0, Math.min(at.x, (this.rowsEl.clientWidth || 224) - 224))}px`
    else menu.style.right = "4px"
    menu.dataset.treeMenu = ""
    menu.setAttribute("role", "menu")
    menu.innerHTML = menuHtml(items)
    menu.addEventListener("click", e => {
      if (e.target.closest("a")) setTimeout(() => this.closeMenu(), 0)
    })
    this.menuItems = items
    this.menuEl = menu
    this.rowsEl.appendChild(menu)
  },

  menuAction(e, index) {
    e.preventDefault()
    e.stopPropagation()
    const item = (this.menuItems || [])[index]
    this.closeMenu()
    if (!item) return
    if (item.event) return this.pushEvent(item.event, item.payload)
    const url = new URL(item.href, window.location.href).toString()
    if (item.action === "newTab") window.open(url, "_blank", "noopener")
    if (item.action === "copy" && navigator.clipboard) navigator.clipboard.writeText(url)
  },

  closeMenu() {
    if (this.menuEl) this.menuEl.remove()
    this.menuEl = null
  },

  // The tree's drag: pointer events rather than the browser's own drag and
  // drop, which a virtual list (whose rows come and go as it scrolls) and a
  // touch screen both defeat. With a mouse a writer's row drags from
  // anywhere on it (#749): a press that moves less than a few pixels is
  // still the click it was. A finger scrolls, and holds for the menu, so
  // on a touch screen only Organise mode's handles drag.
  dragStart(e) {
    this.hidePreview()
    const handle = e.target.closest("[data-drag]")
    if (!handle && e.pointerType === "touch") return this.pressStart(e)
    if (e.button > 0) return
    let rowEl
    if (handle) {
      rowEl = handle.closest("[data-key]")
      e.preventDefault()
    } else {
      if (e.pointerType !== "mouse" || e.ctrlKey || e.metaKey || e.shiftKey || e.altKey) return
      if (e.target.closest("[data-toggle], [data-menu]")) return
      rowEl = e.target.closest("[data-movable]")
      if (!rowEl) return
    }

    // The dragged row is held by its key, not its place: a folder opening
    // under the drag puts rows above it, and its place changes.
    this.drag = {key: rowEl.dataset.key, x: e.clientX, y: e.clientY, started: false, target: null}
    this.onMove = ev => this.dragMove(ev)
    this.onUp = ev => this.dragEnd(ev)
    window.addEventListener("pointermove", this.onMove)
    window.addEventListener("pointerup", this.onUp)
    window.addEventListener("pointercancel", this.onUp)
  },

  // A finger resting on a row opens its menu, as a right-click does: touch
  // screens have no right button, and iOS sends no contextmenu event.
  pressStart(e) {
    const rowEl = e.target.closest("[data-key]")
    if (!rowEl) return
    clearTimeout(this.pressTimer)
    const x = e.clientX
    const y = e.clientY
    const cancel = ev => {
      if (ev.type === "pointermove" && Math.abs(ev.clientX - x) + Math.abs(ev.clientY - y) < 8) return
      clearTimeout(this.pressTimer)
      window.removeEventListener("pointermove", cancel)
      window.removeEventListener("pointerup", cancel)
      window.removeEventListener("pointercancel", cancel)
    }
    window.addEventListener("pointermove", cancel)
    window.addEventListener("pointerup", cancel)
    window.addEventListener("pointercancel", cancel)
    this.pressTimer = setTimeout(() => {
      cancel({type: "pointerup"})
      // The click the finger's lifting makes is the menu's, not the row's.
      this.pressed = true
      setTimeout(() => { this.pressed = false }, 700)
      const box = this.rowsEl.getBoundingClientRect()
      this.openMenu(rowEl, {x: x - box.left, y: y - box.top})
    }, LONG_PRESS_MS)
  },

  dragMove(e) {
    const drag = this.drag
    if (!drag) return
    if (!drag.started) {
      if (Math.abs(e.clientX - drag.x) + Math.abs(e.clientY - drag.y) < 4) return
      drag.started = true
      this.closeMenu()
      if (window.getSelection) window.getSelection().removeAllRanges()
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
    const to = Math.floor(y / this.rowH)
    const target = this.flat[to]
    if (!target) { this.setGuide(null); return }
    const zone = dropZone(y - to * this.rowH, this.rowH)
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
        guide.style.cssText = `top:${at.to * this.rowH}px;height:${this.rowH}px`
      } else {
        const top = (at.to + (at.zone === "after" ? 1 : 0)) * this.rowH - 1
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
    if (!drag || !drag.started) return
    // The click the mouse's release makes is the drag's, not the row's: it
    // would open the row it was dropped on.
    this.dragged = true
    setTimeout(() => { this.dragged = false }, 0)
    if (drag.target) this.pushEvent("tree_move", drag.target)
  },

  endDrag() {
    if (!this.drag) return
    const started = this.drag.started
    clearTimeout(this.drag.hoverTimer)
    if (this.drag.ghost) this.drag.ghost.remove()
    this.drag = null
    this.dragGuide = null
    this.el.classList.remove("wiki-dragging")
    window.removeEventListener("pointermove", this.onMove)
    window.removeEventListener("pointerup", this.onUp)
    window.removeEventListener("pointercancel", this.onUp)
    // A press that never became a drag drew nothing, and redrawing now
    // would swap the link out from under the click that is coming.
    if (started) this.render()
  },
}
