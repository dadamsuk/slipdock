// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/slipdock"
import topbar from "../vendor/topbar"
import Sortable from "../vendor/sortable"
import {installConfirm} from "./confirm"
import {ModalDialog} from "./modal_dialog"
import {installPosthog} from "./posthog"
import {Replay} from "./replay"

const Hooks = {}
Hooks.ModalDialog = ModalDialog
Hooks.Replay = Replay

// Keeps the server's idea of the window width up to date, so views that
// render something different on a phone (the calendar's agenda, the board's
// one-list pager) switch when the device is turned or the window dragged.
// The first width comes in over the socket's connect params, not from here.
Hooks.Viewport = {
  mounted() {
    let last = window.innerWidth
    let timer = null

    this.onResize = () => {
      clearTimeout(timer)
      timer = setTimeout(() => {
        if (window.innerWidth === last) return
        last = window.innerWidth
        this.pushEvent("viewport", {width: last})
      }, 200)
    }

    window.addEventListener("resize", this.onResize)
    window.addEventListener("orientationchange", this.onResize)
    // The connect params can be stale if the socket reconnects into a page
    // that was resized while it was away; one push settles it.
    if (String(window.innerWidth) !== this.el.dataset.width) {
      this.pushEvent("viewport", {width: window.innerWidth})
    }
  },
  destroyed() {
    window.removeEventListener("resize", this.onResize)
    window.removeEventListener("orientationchange", this.onResize)
  },
}

// A menu that has to escape its scroll container. The board's lists scroll,
// and an absolutely-positioned dropdown inside one is clipped by it — the
// card's "move to another list" menu came out as two visible rows. The
// native popover API puts the menu in the browser's top layer, above every
// overflow and z-index; all that is left is to put it beside the button
// that opened it, which CSS anchor positioning would do if Firefox had it.
//
// Positioned before it is painted, from the trigger's rectangle and the
// menu's own fixed width, so there is no frame at the wrong place: below the
// trigger in the top half of the screen, above it in the bottom half.
Hooks.AnchoredPopover = {
  mounted() {
    this.el.addEventListener("beforetoggle", e => {
      if (e.newState !== "open") return
      const trigger = document.getElementById(this.el.dataset.anchor)
      if (!trigger) return

      const r = trigger.getBoundingClientRect()
      const width = this.el.offsetWidth || 192
      const gap = 4

      this.el.style.left = `${Math.min(Math.max(8, r.right - width), window.innerWidth - width - 8)}px`

      if (r.bottom > window.innerHeight / 2) {
        this.el.style.top = "auto"
        this.el.style.bottom = `${window.innerHeight - r.top + gap}px`
      } else {
        this.el.style.bottom = "auto"
        this.el.style.top = `${r.bottom + gap}px`
      }
    })
  },
}

// The phone's list strip above the board. A 390pt screen fits one list, so
// the board becomes a pager: the strip says which lists exist and how full
// they are, tapping one slides to it, and swiping the board moves the
// highlight. Entirely client-side — paging is not the server's business.
Hooks.ListPager = {
  mounted() {
    this.scroller = document.getElementById("board-scroll")
    if (!this.scroller) return

    this.el.addEventListener("click", e => {
      const tab = e.target.closest("[data-column]")
      if (!tab) return
      const column = document.getElementById(`column-${tab.dataset.column}`)
      column?.scrollIntoView({behavior: "smooth", inline: "start", block: "nearest"})
    })

    let frame = null
    this.onScroll = () => {
      if (frame) return
      frame = requestAnimationFrame(() => {
        frame = null
        this.highlight()
      })
    }
    this.scroller.addEventListener("scroll", this.onScroll, {passive: true})
    this.highlight()
  },

  updated() {
    this.highlight()
  },

  destroyed() {
    this.scroller?.removeEventListener("scroll", this.onScroll)
  },

  // Whichever list covers the middle of the screen is the one you are on.
  highlight() {
    const mid = this.scroller.scrollLeft + this.scroller.clientWidth / 2
    let best = null

    for (const column of this.scroller.querySelectorAll(".kanban-column[data-id]")) {
      const centre = column.offsetLeft + column.offsetWidth / 2
      const distance = Math.abs(centre - mid)
      if (!best || distance < best.distance) best = {distance, id: column.dataset.id}
    }

    for (const tab of this.el.querySelectorAll("[data-column]")) {
      const on = best && tab.dataset.column === best.id
      if (on) {
        tab.setAttribute("data-on", "")
        tab.setAttribute("aria-current", "true")
        // Keep the live tab in view as you swipe past the strip's edge.
        const left = tab.offsetLeft - (this.el.clientWidth - tab.offsetWidth) / 2
        this.el.scrollTo({left, behavior: "smooth"})
      } else {
        tab.removeAttribute("data-on")
        tab.removeAttribute("aria-current")
      }
    }
  },
}

// Drag-and-drop for cards (and columns). Sortable moves the DOM node itself;
// we put it back where it came from before telling the server, so that the
// LiveView patch is the single source of truth and nodes never duplicate.
Hooks.Sortable = {
  mounted() {
    const hook = this
    const opts = {
      group: this.el.dataset.group || "cards",
      animation: 150,
      forceFallback: true,
      fallbackTolerance: 4,
      delay: 120,
      delayOnTouchOnly: true,
      touchStartThreshold: 4,
      ghostClass: "sortable-ghost",
      chosenClass: "sortable-chosen",
      dragClass: "sortable-drag",
      onEnd(evt) {
        const {item, from, to, oldIndex, newIndex} = evt
        if (from === to && oldIndex === newIndex) return
        const next = item.nextElementSibling
        const before = next && next.dataset.id ? next.dataset.id : null
        to.removeChild(item)
        from.insertBefore(item, from.children[oldIndex] || null)
        hook.pushEvent(hook.el.dataset.event || "move_card", {
          id: item.dataset.id,
          from: from.dataset.id,
          to: to.dataset.id,
          before: before,
        })
      },
    }
    // Only pass these when set: Sortable treats a present-but-undefined key
    // as an override of its defaults.
    if (this.el.dataset.draggable) opts.draggable = this.el.dataset.draggable
    if (this.el.dataset.handle) opts.handle = this.el.dataset.handle
    // A list sorted by an attribute has no order of its own to rearrange:
    // cards can still be dropped into it, not reordered inside it.
    if (this.el.dataset.sort === "false") opts.sort = false
    // Read-only viewers can look but not drag.
    if (this.el.dataset.disabled === "true") opts.disabled = true
    this.sortable = new Sortable(this.el, opts)
  },
  updated() {
    if (this.sortable) {
      this.sortable.option("disabled", this.el.dataset.disabled === "true")
      this.sortable.option("sort", this.el.dataset.sort !== "false")
    }
  },
  destroyed() {
    this.sortable && this.sortable.destroy()
  },
}

// Timeline bars: drag a bar to move the card, or one of its edges to change
// its start or due date. Movement is snapped to whole days (data-px is the
// width of a day); a drag of less than 4px is treated as a click.
// Dependency connectors: a curve from the end of each blocker's bar to the
// start of the bar it blocks, red when the blocked card starts first.
function drawTimelineLinks(el) {
  const svg = el.querySelector("#tl-links")
  if (!svg) return
  let links = []
  try { links = JSON.parse(el.dataset.links || "[]") } catch (_) { links = [] }
  const box = el.getBoundingClientRect()
  svg.setAttribute("width", el.scrollWidth)
  svg.setAttribute("height", el.scrollHeight)
  const bars = {}
  el.querySelectorAll(".tl-bar[data-id]").forEach(b => {
    (bars[b.dataset.id] ||= []).push(b)
  })
  const paths = []
  for (const link of links) {
    for (const from of bars[link.from] || []) {
      for (const to of bars[link.to] || []) {
        const a = from.getBoundingClientRect(), b = to.getBoundingClientRect()
        const x1 = a.right - box.left, y1 = a.top + a.height / 2 - box.top
        const x2 = b.left - box.left, y2 = b.top + b.height / 2 - box.top
        const dx = Math.max(16, Math.abs(x2 - x1) / 2)
        const d = `M${x1},${y1} C${x1 + dx},${y1} ${x2 - dx},${y2} ${x2},${y2}`
        paths.push(`<path d="${d}" class="${link.violated ? "tl-link tl-link-violated" : "tl-link"}"/>` +
          `<circle cx="${x2}" cy="${y2}" r="2.5" class="${link.violated ? "tl-link-end tl-link-violated" : "tl-link-end"}"/>`)
      }
    }
  }
  svg.innerHTML = paths.join("")
}

Hooks.Timeline = {
  updated() { drawTimelineLinks(this.el) },
  mounted() {
    const el = this.el
    const px = () => parseFloat(el.dataset.px) || 14
    let drag = null
    drawTimelineLinks(el)
    this.redraw = () => drawTimelineLinks(el)
    window.addEventListener("resize", this.redraw)

    el.addEventListener("pointerdown", e => {
      if (el.dataset.disabled === "true" || e.button !== 0) return
      const bar = e.target.closest(".tl-bar")
      if (!bar || bar.dataset.locked === "true") return
      const handle = e.target.closest(".tl-handle")
      drag = {bar, id: bar.dataset.id, edge: handle ? handle.dataset.edge : "both",
              x: e.clientX, moved: false, delta: 0}
      bar.setPointerCapture(e.pointerId)
    })

    el.addEventListener("pointermove", e => {
      if (!drag) return
      const dx = e.clientX - drag.x
      if (!drag.moved && Math.abs(dx) < 4) return
      drag.moved = true
      drag.delta = Math.round(dx / px())
      const shift = drag.delta * px()
      const s = drag.bar.style
      if (drag.edge === "both") s.transform = `translateX(${shift}px)`
      else if (drag.edge === "start") s.marginLeft = `${shift}px`
      else s.marginRight = `${-shift}px`
      drag.bar.classList.add("tl-dragging")
    })

    const finish = () => {
      if (!drag) return
      const {bar, id, edge, delta, moved} = drag
      drag = null
      bar.style.transform = ""
      bar.style.marginLeft = ""
      bar.style.marginRight = ""
      bar.classList.remove("tl-dragging")
      if (moved) {
        bar.dataset.suppressClick = "1"
        setTimeout(() => delete bar.dataset.suppressClick, 0)
        if (delta !== 0) this.pushEvent("timeline_move", {id, edge, delta})
      }
    }
    el.addEventListener("pointerup", finish)
    el.addEventListener("pointercancel", finish)
    // A drag must not also open the card.
    el.addEventListener("click", e => {
      const bar = e.target.closest(".tl-bar")
      if (bar && bar.dataset.suppressClick) { e.stopPropagation(); e.preventDefault() }
    }, true)
  },
  destroyed() { if (this.redraw) window.removeEventListener("resize", this.redraw) },
}

// Unscheduled tray on the timeline: drag a chip onto a day column to give the
// card that due date. A floating copy of the chip follows the pointer and the
// target column is highlighted; a move of less than 4px is treated as a click.
Hooks.TimelineTray = {
  mounted() {
    const tray = this.el
    let drag = null

    const grid = () => document.getElementById("timeline")
    const drop = () => document.getElementById("tl-drop")

    // Day index under the pointer, or null when it is not over the grid's tracks.
    const dayAt = (e) => {
      const el = grid()
      const track = el && el.querySelector(".tl-track")
      const scroll = document.getElementById("timeline-scroll")
      if (!el || !track || !scroll) return null
      const box = scroll.getBoundingClientRect()
      if (e.clientY < box.top || e.clientY > box.bottom) return null
      const px = parseFloat(el.dataset.px) || 14
      const days = parseInt(el.dataset.days, 10) || 0
      const left = track.getBoundingClientRect().left
      if (e.clientX < left || e.clientX < box.left) return null
      const day = Math.floor((e.clientX - left) / px)
      return day >= 0 && day < days ? day : null
    }

    const label = (day) => {
      const el = grid()
      if (day === null || !el || !el.dataset.from) return ""
      const d = new Date(el.dataset.from + "T00:00:00")
      d.setDate(d.getDate() + day)
      return d.toLocaleDateString(undefined, {weekday: "short", day: "numeric", month: "short"})
    }

    const highlight = (day) => {
      const el = grid(), mark = drop()
      if (!el || !mark) return
      if (day === null) { mark.hidden = true; return }
      const px = parseFloat(el.dataset.px) || 14
      const track = el.querySelector(".tl-track")
      const offset = track ? track.getBoundingClientRect().left - el.getBoundingClientRect().left : 0
      mark.style.left = `${offset + day * px}px`
      mark.style.width = `${px}px`
      mark.hidden = false
    }

    tray.addEventListener("pointerdown", e => {
      if (tray.dataset.disabled === "true" || e.button !== 0) return
      if (e.target.closest("input, button, a, form")) return
      const chip = e.target.closest(".cal-chip")
      if (!chip || !grid()) return
      drag = {chip, id: chip.dataset.id, x: e.clientX, y: e.clientY, moved: false, ghost: null, day: null}
      chip.setPointerCapture(e.pointerId)
    })

    tray.addEventListener("pointermove", e => {
      if (!drag) return
      if (!drag.moved) {
        if (Math.abs(e.clientX - drag.x) < 4 && Math.abs(e.clientY - drag.y) < 4) return
        drag.moved = true
        const ghost = drag.chip.cloneNode(true)
        ghost.removeAttribute("id")
        ghost.querySelectorAll("form").forEach(f => f.remove())
        ghost.classList.add("tl-chip-ghost")
        const tag = document.createElement("span")
        tag.className = "tl-chip-date"
        ghost.appendChild(tag)
        document.body.appendChild(ghost)
        drag.ghost = ghost
        drag.tag = tag
        drag.chip.classList.add("tl-chip-dragging")
        document.body.classList.add("tl-tray-dragging")
      }
      drag.ghost.style.transform = `translate(${e.clientX + 12}px, ${e.clientY + 12}px)`
      drag.day = dayAt(e)
      drag.tag.textContent = drag.day === null ? "" : "→ " + label(drag.day)
      drag.ghost.classList.toggle("tl-chip-over", drag.day !== null)
      highlight(drag.day)
    })

    const finish = (e) => {
      if (!drag) return
      const {chip, id, moved, ghost} = drag
      const day = e.type === "pointerup" ? drag.day : null
      drag = null
      ghost && ghost.remove()
      chip.classList.remove("tl-chip-dragging")
      document.body.classList.remove("tl-tray-dragging")
      highlight(null)
      if (moved) {
        chip.dataset.suppressClick = "1"
        setTimeout(() => delete chip.dataset.suppressClick, 0)
        if (day !== null) this.pushEvent("timeline_schedule", {id, day})
      }
    }
    tray.addEventListener("pointerup", finish)
    tray.addEventListener("pointercancel", finish)
    // A drag must not also open the card.
    tray.addEventListener("click", e => {
      const chip = e.target.closest(".cal-chip")
      if (chip && chip.dataset.suppressClick) { e.stopPropagation(); e.preventDefault() }
    }, true)
  },
}

// Focus (and optionally select) an input as soon as it appears.
Hooks.Focus = {
  mounted() {
    this.el.focus()
    if (this.el.dataset.select !== undefined) this.el.select()
  },
}

// Dismisses a flash after a few seconds, exactly as a click on it would.
Hooks.AutoDismiss = {
  mounted() { this.timer = setTimeout(() => this.el.click(), 4500) },
  destroyed() { clearTimeout(this.timer) },
}

// A running card timer: counts up from `data-since` once a second, so the
// server needn't push a tick. Keyed on the start time, so a restart remounts.
Hooks.Elapsed = {
  mounted() {
    const since = Date.parse(this.el.dataset.since)
    const pad = n => String(n).padStart(2, "0")
    const tick = () => {
      const s = Math.max(0, Math.floor((Date.now() - since) / 1000))
      this.el.textContent = `Stop · ${Math.floor(s / 3600)}:${pad(Math.floor(s / 60) % 60)}:${pad(s % 60)}`
    }
    tick()
    this.timer = setInterval(tick, 1000)
  },
  destroyed() { clearInterval(this.timer) },
}

// Keeps the horizontal board scrolled to the far right after adding a list.
Hooks.ScrollEnd = {
  mounted() {
    this.handleEvent("scroll_end", () => {
      this.el.scrollTo({left: this.el.scrollWidth, behavior: "smooth"})
    })
  },
}

// Wraps a textarea and a hidden LiveView file input (named by data-upload).
// Pasting or dropping an image uploads it through that input; once the server
// has stored it, an "image_uploaded" event carries back the Markdown to put
// where a placeholder was left at the cursor.
Hooks.PasteImage = {
  mounted() {
    this.textarea = this.el.querySelector("textarea")
    this.upload = this.el.dataset.upload
    this.placeholder = "![Uploading image…]()"
    this.textarea.addEventListener("paste", e => this.take(e, e.clipboardData))
    this.textarea.addEventListener("drop", e => this.take(e, e.dataTransfer))
    this.textarea.addEventListener("dragover", e => {
      if (Array.from(e.dataTransfer?.items || []).some(i => i.kind === "file")) e.preventDefault()
    })
    this.handleEvent("image_uploaded", ({upload, markdown}) => {
      if (upload !== this.upload) return
      this.replacePlaceholder(markdown)
    })
    this.handleEvent("image_failed", ({upload}) => {
      if (upload !== this.upload) return
      this.replacePlaceholder("")
    })
  },
  take(e, data) {
    const files = Array.from(data?.files || []).filter(f => f.type.startsWith("image/"))
    if (files.length === 0 || this.textarea.disabled) return
    e.preventDefault()
    files.forEach(() => this.insertAtCursor(this.placeholder + "\n"))
    this.uploadFiles(files)
  },
  insertAtCursor(text) {
    const ta = this.textarea
    const start = ta.selectionStart ?? ta.value.length
    const end = ta.selectionEnd ?? start
    const before = ta.value.slice(0, start)
    const pad = before.length > 0 && !before.endsWith("\n") ? "\n" : ""
    ta.value = before + pad + text + ta.value.slice(end)
    ta.selectionStart = ta.selectionEnd = start + pad.length + text.length
    this.changed()
  },
  replacePlaceholder(markdown) {
    const ta = this.textarea
    const at = ta.value.indexOf(this.placeholder)
    if (at >= 0) {
      const keep = ta.selectionStart
      ta.value = ta.value.slice(0, at) + markdown + ta.value.slice(at + this.placeholder.length)
      const shift = markdown.length - this.placeholder.length
      ta.selectionStart = ta.selectionEnd = keep > at ? keep + shift : keep
    } else if (markdown) {
      ta.value = ta.value.replace(/\s*$/, "") + (ta.value.trim() ? "\n" : "") + markdown + "\n"
    }
    this.changed()
  },
  changed() {
    this.textarea.dispatchEvent(new Event("input", {bubbles: true}))
  },
  uploadFiles(files) {
    const named = files.map(f => {
      if (f.name && f.name !== "image.png" && f.name !== "blob") return f
      const ext = (f.type.split("/")[1] || "png").replace("jpeg", "jpg")
      const stamp = new Date().toISOString().replace(/[:.]/g, "-").slice(0, 19)
      return new File([f], `pasted-${stamp}.${ext}`, {type: f.type})
    })
    this.uploadTo(this.el, this.upload, named)
  },
}

// Typing @ in a card's description or a comment offers the board's members
// (data-people, from SlipdockWeb.Mention). Arrow keys pick, Enter or Tab
// takes, Escape closes. The list lives on <body> so a LiveView patch of the
// form cannot take it away mid-word.
Hooks.Mention = {
  mounted() {
    this.textarea = this.el.querySelector("textarea")
    if (!this.textarea) return
    this.menu = document.createElement("ul")
    this.menu.className = "menu menu-sm fixed z-[100] hidden w-64 rounded-box border border-base-300 bg-base-100 p-1 shadow-lg"
    document.body.appendChild(this.menu)
    this.matches = []
    this.textarea.addEventListener("input", () => this.refresh())
    this.textarea.addEventListener("click", () => this.refresh())
    this.textarea.addEventListener("blur", () => setTimeout(() => this.close(), 150))
    // On the wrapper, so a key the list uses never reaches the textarea's
    // own bindings (Escape there stops editing the description).
    this.el.addEventListener("keydown", e => this.key(e), true)
  },
  destroyed() { this.menu && this.menu.remove() },
  people() {
    try { return JSON.parse(this.el.dataset.people || "[]") } catch (_) { return [] }
  },
  // The "@word" the caret is at the end of, if any.
  query() {
    const ta = this.textarea
    const upto = ta.value.slice(0, ta.selectionStart)
    const m = upto.match(/(^|[^\w@\/])@([\w.\-]{0,62})$/)
    return m ? {start: upto.length - m[2].length - 1, text: m[2].toLowerCase()} : null
  },
  refresh() {
    const q = this.query()
    if (!q) return this.close()
    this.at = q
    this.matches = this.people().filter(p =>
      [p.handle, p.email, ...(p.name || "").split(/\s+/)].some(w => w && w.toLowerCase().startsWith(q.text))
    ).slice(0, 8)
    if (this.matches.length === 0) return this.close()
    this.selected = 0
    this.render()
  },
  render() {
    this.menu.replaceChildren(...this.matches.map((p, i) => {
      const li = document.createElement("li")
      const a = document.createElement("a")
      if (i === this.selected) a.classList.add("menu-active")
      const name = document.createElement("span")
      name.textContent = p.name || p.email
      const handle = document.createElement("span")
      handle.className = "text-base-content/60"
      handle.textContent = "@" + p.handle
      a.append(name, handle)
      a.addEventListener("mousedown", e => { e.preventDefault(); this.take(p) })
      li.appendChild(a)
      return li
    }))
    const r = this.textarea.getBoundingClientRect()
    this.menu.style.left = r.left + "px"
    this.menu.style.top = Math.min(r.bottom + 4, window.innerHeight - 280) + "px"
    this.menu.classList.remove("hidden")
  },
  close() { this.matches = []; this.menu && this.menu.classList.add("hidden") },
  key(e) {
    if (this.matches.length === 0) return
    if (e.key === "ArrowDown" || e.key === "ArrowUp") {
      const n = this.matches.length
      this.selected = (this.selected + (e.key === "ArrowDown" ? 1 : n - 1)) % n
      this.render()
    } else if (e.key === "Enter" || e.key === "Tab") {
      this.take(this.matches[this.selected])
    } else if (e.key === "Escape") {
      this.close()
    } else {
      return
    }
    e.preventDefault()
    e.stopPropagation()
  },
  take(person) {
    const ta = this.textarea
    const end = ta.selectionStart
    const insert = "@" + person.handle + " "
    ta.value = ta.value.slice(0, this.at.start) + insert + ta.value.slice(end)
    ta.selectionStart = ta.selectionEnd = this.at.start + insert.length
    ta.dispatchEvent(new Event("input", {bubbles: true}))
    this.close()
    ta.focus()
  },
}

// A passage of a wiki page becomes a card. Selecting text inside the element
// raises a small button beside the selection; pressing it sends the text to
// the server, which makes the card and writes the link into both ends.
Hooks.WikiSelection = {
  mounted() {
    this.button = document.getElementById(this.el.dataset.button)
    if (!this.button) return
    this.onUp = () => this.sync()
    document.addEventListener("selectionchange", this.onUp)
    this.button.addEventListener("mousedown", e => {
      e.preventDefault()
      const text = this.selectedText()
      if (text) this.pushEvent("card_from_selection", {text})
      this.hide()
    })
  },
  destroyed() {
    document.removeEventListener("selectionchange", this.onUp)
  },
  selectedText() {
    const sel = window.getSelection()
    if (!sel || sel.isCollapsed || sel.rangeCount === 0) return null
    const range = sel.getRangeAt(0)
    if (!this.el.contains(range.commonAncestorContainer)) return null
    const text = sel.toString().trim()
    return text.length > 2 ? text : null
  },
  sync() {
    const text = this.selectedText()
    if (!text) return this.hide()
    const rect = window.getSelection().getRangeAt(0).getBoundingClientRect()
    this.button.style.top = `${rect.top + window.scrollY - 40}px`
    this.button.style.left = `${rect.left + window.scrollX}px`
    this.button.hidden = false
  },
  hide() {
    this.button.hidden = true
  },
}

// Textarea that grows with its content.
// With data-single-line, Enter commits (blurs) instead of adding a line.
Hooks.AutoGrow = {
  mounted() {
    this.resize()
    this.el.addEventListener("input", () => this.resize())
    if (this.el.dataset.singleLine !== undefined) {
      this.el.addEventListener("keydown", (e) => {
        if (e.key === "Enter") { e.preventDefault(); this.el.blur() }
      })
    }
    // With data-submit-on-enter, Enter submits the form; Shift+Enter adds a line.
    if (this.el.dataset.submitOnEnter !== undefined) {
      this.el.addEventListener("keydown", (e) => {
        if (e.key === "Enter" && !e.shiftKey && !e.isComposing) {
          e.preventDefault()
          this.el.form && this.el.form.requestSubmit()
        }
      })
      this.el.focus()
    }
  },
  updated() { this.resize() },
  resize() { this.el.style.height = "auto"; this.el.style.height = this.el.scrollHeight + "px" },
}

// The quick-add input: stays focused and empties itself after each card is
// added (the server names the form in a "quick_added" event); Escape clears it.
Hooks.QuickAdd = {
  mounted() {
    this.handleEvent("quick_added", ({form}) => {
      if (this.el.form && this.el.form.id === form) {
        this.el.value = ""
        this.el.focus()
      }
    })
    this.el.addEventListener("keydown", (e) => {
      if (e.key === "Escape") {
        this.el.value = ""
        this.el.dispatchEvent(new Event("input", {bubbles: true}))
        this.el.blur()
      }
    })
  },
}

// The header's quick add: "c" anywhere outside a field opens the box, the
// same way the boards' own quick add rows are reached by clicking them.
Hooks.QuickAddKey = {
  mounted() {
    document.addEventListener("keydown", this.onKey = (e) => {
      if (e.key !== "c" || e.metaKey || e.ctrlKey || e.altKey) return
      const el = document.activeElement
      if (el && (el.isContentEditable || ["INPUT", "TEXTAREA", "SELECT"].includes(el.tagName))) return
      if (document.getElementById("quick-add-panel")) return
      e.preventDefault()
      this.pushEvent("toggle_quick_add", {})
    })
  },
  destroyed() { document.removeEventListener("keydown", this.onKey) },
}

// Keyboard shortcuts. Two hooks share the keyboard: `Keys` rides in the
// layout and answers the ones that work on any page, `BoardKeys` rides on a
// board and answers the ones that need cards and lists. They keep out of each
// other's way through `claimed` — whichever is mid-gesture holds the keyboard
// until it is done.
//
// The catalogue of what these keys do, for people, is SlipdockWeb.Shortcuts.
const keyboard = {claimed: null}

// Vim's own movement keys. Wherever the arrows walk the board — pointing at a
// card or carrying one — these walk it too, so a hand need not leave the home
// row. "h" and "l" are the page's own keys elsewhere (all boards, alerts), and
// `boardFocus` is how they stand down while the board is holding them.
const VIM_DIRS = {h: "left", j: "down", k: "up", l: "right"}

function vimDir(e) {
  return !e.shiftKey && VIM_DIRS[e.key]
}

// Labels, the way a Vim browser plugin does links: they favour the home keys,
// and only grow to pairs once the board shows more things than there are
// characters. The pairs reuse the home keys first in both positions, and the
// set stays prefix-free so no label swallows another.
const HINT_CHARS = "asdfkjlghwertyuiopvbcnmxzq".split("")

function hintLabels(count) {
  if (count <= HINT_CHARS.length) return HINT_CHARS.slice(0, count)
  const labels = [""]
  let offset = 0
  while (labels.length - offset < count) {
    const prefix = labels[offset++]
    for (const c of HINT_CHARS) labels.push(prefix + c)
  }
  return labels.slice(offset, offset + count)
}

// Things the user can actually see: on screen, and not scrolled out of sight
// inside a list or the board's own horizontal scroller.
function onScreen(selector) {
  return Array.from(document.querySelectorAll(selector)).filter(el => {
    const r = el.getBoundingClientRect()
    if (r.width < 8 || r.height < 8) return false
    if (r.bottom < 1 || r.right < 1 || r.top > innerHeight - 1 || r.left > innerWidth - 1) return false
    for (let p = el.parentElement; p && p !== document.body; p = p.parentElement) {
      const {overflowX, overflowY} = getComputedStyle(p)
      if (overflowX === "visible" && overflowY === "visible") continue
      const c = p.getBoundingClientRect()
      if (r.bottom < c.top + 1 || r.top > c.bottom - 1) return false
      if (r.right < c.left + 1 || r.left > c.right - 1) return false
    }
    return true
  })
}

// Is the user typing into something, rather than at the page?
function typing() {
  const el = document.activeElement
  return !!el && (el.isContentEditable || ["INPUT", "TEXTAREA", "SELECT"].includes(el.tagName))
}

// A shifted "j". Some layouts and synthetic events report the unshifted
// character, so the shift key is read as well as the character itself.
function pickUpKey(e) {
  return e.key === "J" || (e.shiftKey && e.key.toLowerCase() === "j")
}

// The palettes "b", "v" and "?" open mark themselves for capture; while one
// is up it owns the keyboard, and the rows are matched by their own keys.
function palette() {
  return document.querySelector("[data-key-capture]")
}

// The card dialog, while one is open. It owns the keyboard too: its arrows
// scroll it and its letters jump to its sections, so the page and the board
// behind it stand down rather than answer the same keys.
function cardDialog() {
  return document.querySelector("[data-card-keys]")
}

// The board, while the keyboard is on it: pointing at a card or carrying one.
// It answers "hjkl" then, so the page's "h" and "l" leave those alone until
// Escape hands the keyboard back.
function boardFocus() {
  return document.querySelector("#board-keys[data-focus]")
}

// Reading a card: the arrows, PageUp/Down and Home/End scroll the dialog, and
// a section's own letter jumps to it. The letters are the ones underlined in
// the dialog's headings — the markup carries each as `data-section-key`, so
// what is underlined and what is answered here cannot drift apart. They are
// written down for people in SlipdockWeb.Shortcuts.
//
// "hjkl" walk a card as they walk a board: "j" and "k" scroll it a line at a
// time like the arrows, and "h" and "l" step between its sections, for when
// the letter escapes you. Those four letters are the movement keys' alone here,
// so no section may claim one — Checklist is "e" and Links is "n" for that
// reason, as Checklist and Dependencies already gave way to Comments and
// Description.
const CARD_LINE = 80

Hooks.CardKeys = {
  mounted() {
    this.aim = null
    document.addEventListener("keydown", (this.onKey = e => this.key(e)), true)
  },

  destroyed() {
    document.removeEventListener("keydown", this.onKey, true)
  },

  key(e) {
    if (e.metaKey || e.ctrlKey || e.altKey) return
    // Escape is the modal's own, and a field the user is in keeps its keys.
    if (palette() || typing()) return

    // "h" and "l" are a step sideways through the sections; everything else
    // that moves the card abandons whichever step was last aimed at.
    const dir = vimDir(e)
    if (dir === "left") return this.step(e, -1)
    if (dir === "right") return this.step(e, 1)
    this.aim = null

    const page = Math.max(this.el.clientHeight - CARD_LINE, CARD_LINE)

    switch (e.key) {
      case "ArrowDown": return this.by(e, CARD_LINE)
      case "ArrowUp": return this.by(e, -CARD_LINE)
      case "PageDown": return this.by(e, page)
      case "PageUp": return this.by(e, -page)
      case "Home": return this.to(e, 0, "smooth")
      case "End": return this.to(e, this.el.scrollHeight, "smooth")
    }

    if (dir === "down") return this.by(e, CARD_LINE)
    if (dir === "up") return this.by(e, -CARD_LINE)

    if (!/^[a-z]$/.test(e.key)) return
    const section = this.el.querySelector(`[data-section-key="${e.key}"]`)
    if (!section) return
    this.to(e, this.topOf(section), "smooth")
  },

  // The sections in the order the card shows them, with the scroll position
  // each one sits at.
  sections() {
    return Array.from(this.el.querySelectorAll("[data-section-key]")).map(el => this.topOf(el))
  },

  // A heading sits a little clear of the top edge rather than against it.
  topOf(section) {
    return this.el.scrollTop + section.getBoundingClientRect().top -
      this.el.getBoundingClientRect().top - 12
  },

  // One section on from where the card is: the section you are in is the last
  // heading to have reached the top. A step still gliding there counts as
  // arrived, so two quick presses move two sections rather than twice to the
  // same one; after half a second the card's real position is trusted again,
  // which is how a scroll by hand takes over.
  step(e, by) {
    const tops = this.sections()
    if (!tops.length) return

    let at = -1
    for (let i = 0; i < tops.length; i++) if (tops[i] <= this.el.scrollTop + 4) at = i
    if (this.aim && Date.now() - this.aim.when < 500) at = this.aim.at

    const next = Math.min(Math.max(at + by, 0), tops.length - 1)
    this.aim = {at: next, when: Date.now()}
    this.to(e, tops[next], "smooth")
  },

  by(e, amount) {
    e.preventDefault()
    e.stopPropagation()
    this.el.scrollBy({top: amount})
  },

  to(e, top, behavior) {
    e.preventDefault()
    e.stopPropagation()
    this.el.scrollTo({top, behavior})
  },
}

// The shortcuts that work on every page. The palettes themselves are rendered
// by SlipdockWeb.ShortcutsHook; this only opens them and picks rows out of them.
Hooks.Keys = {
  mounted() {
    this.typed = ""
    this.open = null
    document.addEventListener("keydown", (this.onKey = e => this.key(e)), true)
  },

  destroyed() {
    document.removeEventListener("keydown", this.onKey, true)
  },

  key(e) {
    // Ctrl-P and Ctrl-O reach the command palette and the card finder from
    // anywhere at all — mid-sentence, over a card, over another palette —
    // which is the point of them, so they come before every other guard.
    if ((e.ctrlKey || e.metaKey) && !e.altKey && !e.shiftKey) {
      const panel = {p: "command", o: "find"}[e.key.toLowerCase()]
      if (panel) return this.send(e, "shortcut_panel", {panel})
    }

    if (e.metaKey || e.ctrlKey || e.altKey) return

    const open = palette()
    if (open) return this.choose(e, open)
    if (keyboard.claimed || typing()) return
    // A card dialog answers these letters itself; only the help sheet is
    // still worth reaching from inside one.
    if (cardDialog() && e.key !== "?") return
    // The board holds "hjkl" while the keyboard is on it, so "h" and "l" walk
    // it rather than leaving the page for all boards or the alerts.
    if (boardFocus() && vimDir(e)) return

    switch (e.key) {
      case "h": return this.send(e, "go_home", {})
      case "b": return this.send(e, "shortcut_panel", {panel: "boards"})
      case "q": return this.send(e, "toggle_quick_add", {})
      case "l": return this.send(e, "toggle_alerts", {})
      case "?": return this.send(e, "shortcut_panel", {panel: "help"})
      case "v":
        if (this.el.dataset.views === "true") return this.send(e, "shortcut_panel", {panel: "views"})
        return
      case "a": {
        // The AI drawer is a live component, so the event goes straight to it.
        if (!document.getElementById("page-ai")) return
        e.preventDefault()
        return this.pushEventTo("#page-ai", "toggle", {})
      }
      case "/": {
        const search = document.querySelector("input[name=q]")
        if (!search) return
        e.preventDefault()
        search.focus()
        search.select()
        return
      }
    }
  },

  // A palette is up. A filtered one (Ctrl-P, Ctrl-O) wants the letters for
  // its box and only takes the keys that walk the answer; a keyed one takes
  // every letter, as a key.
  choose(e, open) {
    if (open.dataset.keyCapture === "filter") return this.walk(e, open)

    if (open !== this.open) {
      this.open = open
      this.typed = ""
    }

    e.preventDefault()
    e.stopPropagation()

    if (e.key === "Escape") return this.send(e, "close_shortcuts", {})
    if (e.key === "Backspace") return this.narrow(open, this.typed.slice(0, -1))
    if (e.key.length !== 1) return

    const next = this.typed + e.key.toLowerCase()
    const rows = this.rows(open).filter(r => r.key.startsWith(next))
    if (!rows.length) return
    if (rows.length === 1 && rows[0].key === next) return rows[0].el.click()
    this.narrow(open, next)
  },

  // Escape closes, the arrows move the server's cursor, Enter follows the row
  // it is on, and everything else falls through to the box being typed into.
  walk(e, open) {
    switch (e.key) {
      case "Escape": return this.send(e, "close_shortcuts", {})
      case "ArrowDown": return this.send(e, "palette_move", {dir: "down"})
      case "ArrowUp": return this.send(e, "palette_move", {dir: "up"})
      case "Enter": {
        e.preventDefault()
        e.stopPropagation()
        const row = open.querySelector("[data-row][data-on]")
        if (row) row.click()
        return
      }
    }
  },

  rows(open) {
    return Array.from(open.querySelectorAll("[data-shortcut]")).map(el => ({
      key: el.dataset.shortcut.toLowerCase(),
      el,
    }))
  },

  narrow(open, typed) {
    this.typed = typed
    for (const {key, el} of this.rows(open)) {
      const row = el.closest("li") || el
      row.hidden = !key.startsWith(typed)
    }
  },

  send(e, event, params) {
    e.preventDefault()
    e.stopPropagation()
    this.pushEvent(event, params)
  },
}

// What each set of labels is painted on, and what picking one does.
const HINT_TARGETS = {
  open: {selector: ".kanban-card[data-id]", event: "open_card", params: id => ({id})},
  select: {selector: ".kanban-card[data-id]", event: "focus_card", params: id => ({id, hold: true})},
  column: {selector: ".kanban-column[data-id]", event: "focus_column", params: id => ({id})},
}

// The shortcuts that need a board: "j" opens a card by its label, "J" picks
// one up to move it, and "c" steps into a list. Once the keyboard is on the
// board — pointing at a card or carrying one — the arrows, "hjkl", Enter and
// Escape belong to it, and the server holds that position so it survives a
// re-render. "j" walks down then rather than labelling the cards again, so
// Escape comes first if what you want is a label.
Hooks.BoardKeys = {
  mounted() {
    this.hints = null
    this.overlay = null
    this.mode = null
    this.typed = ""
    document.addEventListener("keydown", (this.onKey = e => this.key(e)), true)
    window.addEventListener("resize", (this.onBail = () => this.hide()))
    document.addEventListener("scroll", this.onBail, true)
  },

  // Keep whatever the keyboard is on in sight as it walks the board.
  updated() {
    document.querySelector(".kanban-card[data-focus]")?.scrollIntoView({block: "nearest"})
  },

  destroyed() {
    document.removeEventListener("keydown", this.onKey, true)
    window.removeEventListener("resize", this.onBail)
    document.removeEventListener("scroll", this.onBail, true)
    this.hide()
  },

  key(e) {
    if (e.metaKey || e.ctrlKey || e.altKey) return

    // While the labels are up they swallow every key, so nothing else on the
    // page acts on a character the user meant for a label.
    if (this.mode) {
      e.preventDefault()
      e.stopPropagation()
      if (e.key === "Escape") return this.hide()
      if (e.key === "Backspace") return this.trim()
      if (e.key.length === 1 && HINT_CHARS.includes(e.key.toLowerCase())) this.type(e.key.toLowerCase())
      return
    }

    if (palette() || cardDialog() || typing()) return

    // Pointing at a card, or carrying one: the arrows are the board's.
    const focus = this.el.dataset.focus
    if (focus) {
      const dir =
        {ArrowLeft: "left", ArrowRight: "right", ArrowUp: "up", ArrowDown: "down"}[e.key] ||
        vimDir(e)
      if (dir) return this.send(e, "focus_move", {dir})
      if (e.key === "Escape") return this.send(e, "focus_end", {})
      if (e.key === "Enter") return this.send(e, focus === "hold" ? "focus_end" : "focus_open", {})
      if (pickUpKey(e) && focus === "point" && this.can("move")) return this.send(e, "focus_hold", {})
      if (e.key === "c" && focus === "point" && this.can("move")) return this.send(e, "focus_add", {})
    }

    if (!this.can("board")) return
    if (pickUpKey(e)) return this.can("move") && this.start(e, "select")
    if (e.key === "j") return this.start(e, "open")
    if (e.key === "c") return this.start(e, "column")
  },

  can(what) {
    return this.el.dataset[what] === "true"
  },

  send(e, event, params) {
    e.preventDefault()
    e.stopPropagation()
    this.pushEvent(event, params)
  },

  start(e, mode) {
    e.preventDefault()
    e.stopPropagation()
    this.show(mode)
  },

  show(mode) {
    this.hide()
    const targets = onScreen(HINT_TARGETS[mode].selector)
    if (!targets.length) return

    const labels = hintLabels(targets.length)
    const overlay = document.createElement("div")
    overlay.className = "kanban-hints"

    this.hints = targets.map((target, i) => {
      const r = target.getBoundingClientRect()
      const tag = document.createElement("span")
      tag.className = `kanban-hint kanban-hint-${mode}`
      tag.style.left = `${Math.round(r.left) + 4}px`
      tag.style.top = `${Math.round(r.top) + 4}px`
      overlay.appendChild(tag)
      return {label: labels[i], id: target.dataset.id, tag}
    })

    document.body.appendChild(overlay)
    this.overlay = overlay
    this.mode = mode
    this.typed = ""
    keyboard.claimed = "hints"
    this.paint()
  },

  hide() {
    if (this.overlay) this.overlay.remove()
    this.overlay = null
    this.hints = null
    this.mode = null
    this.typed = ""
    keyboard.claimed = null
  },

  type(char) {
    const next = this.typed + char
    const hits = this.hints.filter(h => h.label.startsWith(next))
    if (!hits.length) return
    this.typed = next
    if (hits.length === 1 && hits[0].label === next) return this.pick(hits[0].id)
    this.paint()
  },

  trim() {
    this.typed = this.typed.slice(0, -1)
    this.paint()
  },

  // Labels still in the running keep their place; the characters already typed
  // are dimmed so the ones still to come stand out.
  paint() {
    for (const {label, tag} of this.hints) {
      const match = label.startsWith(this.typed)
      tag.hidden = !match
      if (!match) continue
      tag.textContent = ""
      if (this.typed) {
        const done = document.createElement("span")
        done.textContent = this.typed
        tag.appendChild(done)
      }
      tag.appendChild(document.createTextNode(label.slice(this.typed.length)))
    }
  },

  pick(id) {
    const {event, params} = HINT_TARGETS[this.mode]
    this.hide()
    this.pushEvent(event, params(id))
  },
}


Hooks.DropdownAlign = {
  mounted() {
    this.align()
    this.el.addEventListener("focusin", () => this.align())
    window.addEventListener("resize", this.onResize = () => this.align())
  },
  destroyed() { window.removeEventListener("resize", this.onResize) },
  align() {
    const menu = this.el.querySelector(".dropdown-content")
    if (!menu) return
    const width = menu.offsetWidth || parseFloat(getComputedStyle(menu).width) || 288
    const left = this.el.getBoundingClientRect().left
    this.el.classList.toggle("dropdown-end", left + width > window.innerWidth - 8)
  },
}

// The wiki's tree, in organise mode: every list in it becomes a Sortable, and
// a drop pushes where the thing landed rather than the whole new shape —
// the server owns the order, as it does on the board.
//
// Folders and pages are separate Sortable groups, so a folder can only be
// dropped where a folder belongs. The list a thing lands in says where that
// is, in `data-into`: "folder:4", "folder:" for the top of the wiki, or
// "page:7" for inside a page.
Hooks.WikiTree = {
  mounted() { this.build() },
  updated() { this.build() },
  destroyed() { this.teardown() },

  teardown() {
    (this.sortables || []).forEach(s => s.destroy())
    this.sortables = []
  },

  build() {
    this.teardown()
    if (this.el.dataset.organising !== "true") return
    const hook = this

    this.sortables = [...this.el.querySelectorAll("[data-tree-list]")].map(list =>
      new Sortable(list, {
        group: `wiki-${list.dataset.treeList}`,
        animation: 150,
        fallbackOnBody: true,
        forceFallback: true,
        fallbackTolerance: 4,
        swapThreshold: 0.7,
        // An empty folder is a target like any other: without this, Sortable
        // only notices a list that already has something in it, and the one
        // place you most want to drop the first page is the one place you
        // cannot.
        emptyInsertThreshold: 12,
        handle: "[data-drag]",
        ghostClass: "sortable-ghost",
        chosenClass: "sortable-chosen",
        dragClass: "sortable-drag",
        // While a drag is on, the empty lists open into targets you can hit
        // (see `#wiki-tree.wiki-dragging` in app.css).
        onStart() { hook.el.classList.add("wiki-dragging") },
        onEnd(evt) {
          hook.el.classList.remove("wiki-dragging")
          const {item, from, to, oldIndex, newIndex} = evt
          if (from === to && oldIndex === newIndex) return
          const next = item.nextElementSibling
          const before = next && next.dataset.id ? next.dataset.id : null
          // Put the DOM back as it was: what comes back from the server is
          // the tree, and a half-applied drag on screen is a lie.
          to.removeChild(item)
          from.insertBefore(item, from.children[oldIndex] || null)
          hook.pushEvent("tree_move", {
            kind: to.dataset.treeList === "folders" ? "folder" : "page",
            id: item.dataset.id,
            into: to.dataset.into,
            before: before,
          })
        },
      })
    )
  },
}

// The folder picker (see `SlipdockWeb.FolderPicker`): a tree of folders you can
// type at. Filtering, the arrow keys and — in form mode — remembering the
// choice all happen here, because the whole tree is already on the page and
// narrowing it is not worth a round trip.
Hooks.FolderPicker = {
  mounted() {
    this.panel = this.el.querySelector("[data-panel]")
    this.filter = this.el.querySelector("[data-filter]")
    this.list = this.el.querySelector("[data-list]")
    this.value = this.el.querySelector("[data-value]")
    this.labelEl = this.el.querySelector("[data-label]")
    this.empty = this.el.querySelector("[data-empty]")
    this.formMode = this.el.dataset.mode === "form"

    this.el.querySelector("[data-toggle]").addEventListener("click", (e) => {
      e.preventDefault()
      e.stopPropagation()
      this.open(this.panel.hidden)
    })

    this.filter.addEventListener("input", () => this.apply())
    this.filter.addEventListener("keydown", (e) => this.keys(e))

    this.el.addEventListener("click", (e) => {
      const row = e.target.closest("[data-row]")
      if (row && !row.disabled) this.choose(row)
    })

    document.addEventListener("click", this.away = (e) => {
      if (!this.el.contains(e.target)) this.open(false)
    })
  },

  destroyed() { document.removeEventListener("click", this.away) },

  open(on) {
    this.panel.hidden = !on
    if (!on) return
    this.filter.value = ""
    this.apply()
    this.filter.focus()
    const chosen = this.rows().find((r) => r.dataset.id === (this.value ? this.value.value : ""))
    if (chosen) chosen.scrollIntoView({block: "nearest"})
  },

  rows() {
    return [...this.el.querySelectorAll("[data-row]")].filter((r) => !r.disabled && !r.closest("li").hidden)
  },

  // A folder matches on any part of its path, so "dec" finds Design/Decisions
  // and "design/" finds everything filed under Design. While a query is on,
  // each row shows its full path instead of its name and loses its indent:
  // the nesting it stood in is no longer on the screen to indent against.
  apply() {
    const q = this.filter.value.trim().toLowerCase()
    let shown = 0

    for (const row of this.el.querySelectorAll("[data-row]")) {
      const li = row.closest("li")
      const hit = q === "" || row.dataset.path.includes(q)
      // The root is a destination, not a folder: it has no path to match, so
      // it stays while nothing is typed and goes as soon as something is.
      const isRoot = li.hasAttribute("data-root-row")
      li.hidden = isRoot ? q !== "" : !hit
      if (!li.hidden && !row.disabled) shown++

      const name = row.querySelector("[data-name]")
      const full = row.querySelector("[data-full]")
      if (name && full) {
        name.hidden = q !== ""
        full.hidden = q === ""
      }
      row.style.paddingLeft = q === "" ? `${row.dataset.indent}rem` : "0.5rem"
      row.removeAttribute("data-on")
    }

    if (this.empty) this.empty.hidden = shown > 0
    const first = this.rows()[0]
    if (q !== "" && first) first.setAttribute("data-on", "")
  },

  keys(e) {
    const rows = this.rows()
    const at = rows.findIndex((r) => r.hasAttribute("data-on"))

    if (e.key === "Escape") {
      e.preventDefault()
      e.stopPropagation()
      this.open(false)
    } else if (e.key === "ArrowDown" || e.key === "ArrowUp") {
      e.preventDefault()
      if (rows.length === 0) return
      const next = e.key === "ArrowDown"
        ? Math.min(at < 0 ? 0 : at + 1, rows.length - 1)
        : Math.max(at < 0 ? 0 : at - 1, 0)
      rows.forEach((r) => r.removeAttribute("data-on"))
      rows[next].setAttribute("data-on", "")
      rows[next].scrollIntoView({block: "nearest"})
    } else if (e.key === "Enter") {
      e.preventDefault()
      const row = at >= 0 ? rows[at] : rows[0]
      if (row) row.click()
    }
  },

  // In form mode the choice lives in a hidden input, and the `input` event is
  // what a form with phx-change is listening for. In event mode the row's own
  // phx-click has already gone; all that is left is to shut the panel.
  choose(row) {
    if (this.formMode && this.value) {
      this.value.value = row.dataset.id
      this.labelEl.textContent = row.dataset.id === ""
        ? this.el.dataset.rootLabel
        : row.querySelector("[data-full]").textContent
      this.value.dispatchEvent(new Event("input", {bubbles: true}))
    }
    this.open(false)
  },
}

// Keeps the palette row the arrows are on in sight as they walk past the
// bottom of the list.
Hooks.PaletteCursor = {
  updated() { this.el.querySelector("[data-row][data-on]")?.scrollIntoView({block: "nearest"}) },
}

// Keeps a chat log scrolled to its newest message.
Hooks.ScrollBottom = {
  mounted() { this.scroll() },
  updated() { this.scroll() },
  scroll() { this.el.scrollTop = this.el.scrollHeight },
}

// Copies the text of the element named by data-target to the clipboard,
// briefly relabelling the button (its [data-label] child) to say so.
Hooks.CopyText = {
  mounted() {
    this.el.addEventListener("click", () => {
      const target = document.getElementById(this.el.dataset.target)
      if (!target || !navigator.clipboard) return
      navigator.clipboard.writeText(target.innerText).then(() => {
        const label = this.el.querySelector("[data-label]")
        if (!label) return
        const old = label.textContent
        label.textContent = "Copied"
        setTimeout(() => { label.textContent = old }, 1500)
      })
    })
  },
}

// A link that copies its own href to the clipboard rather than being
// followed, briefly relabelling its [data-label] child to say so.
Hooks.CopyLink = {
  mounted() {
    this.el.addEventListener("click", e => {
      if (!navigator.clipboard) return
      e.preventDefault()
      navigator.clipboard.writeText(this.el.href).then(() => {
        const label = this.el.querySelector("[data-label]")
        if (!label) return
        const old = label.textContent
        label.textContent = "Copied"
        setTimeout(() => { label.textContent = old }, 1500)
      })
    })
  },
}

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  // A function, so a reconnect after the phone is turned carries the new width.
  params: () => ({_csrf_token: csrfToken, viewport_width: window.innerWidth}),
  hooks: {...colocatedHooks, ...Hooks},
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// A favourited list, opened from /favourites: the board arrives scrolled to
// the left, and the list you asked for may be four screens along. The server
// names it (see `scroll_to_list`); getting there is the browser's job. The
// board's columns are rendered after this fires on the first load, so it
// waits a frame for the one it wants rather than giving up.
window.addEventListener("phx:scroll-to-list", ({detail: {id}}) => {
  let tries = 0
  const find = () => {
    const column = document.getElementById(`column-${id}`)
    if (column) return column.scrollIntoView({inline: "start", block: "nearest"})
    if (tries++ < 20) requestAnimationFrame(find)
  }
  requestAnimationFrame(find)
})

// data-confirm asks with the app's own dialog rather than the browser's.
installConfirm(window)

// Product analytics, only if this server has a PostHog key configured.
installPosthog(window, document)

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", _e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}

