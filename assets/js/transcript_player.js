// A meeting's recording, played in time with its transcript (W-1690).
//
// The hook sits on an element holding a transcript — `[data-transcript]`,
// drawn by SlipdockWeb.TranscriptView, each turn an `<li>` with
// `data-start-ms` — and, on a meeting page, `data-recording-src`: the page's
// recording, streamed from Google Drive by the server. It draws a bar that
// stays in view above the transcript:
//
//   * play/pause, a scrubber, the time and the length, ±10 s, speed
//     0.75×–2×. Nothing is fetched until play is pressed;
//   * the turn being spoken is highlighted and kept in view. Scrolling by
//     hand stops following, and "Follow" starts it again;
//   * clicking a turn plays from there;
//   * a search box marks the turns that match, and steps through them;
//   * space, ← →, [ ] while nothing is being typed;
//   * for anybody who can edit the page (`data-can-name-speakers`), a
//     speaker's name opens a box to name that voice: "Speaker 1" becomes
//     the person, everywhere in the page's transcript (#1157);
//   * a recording that won't play says why, in words.
//
// Without a recording (a .vtt file, a page with a transcript but no
// `recording:`) the bar is the search box alone.
//
// The bar is built here rather than on the server: the page's HTML is
// sanitised, and an <audio> or a <button> would not survive it. The <audio>
// itself is never put in the page, so a LiveView patch that redraws the
// transcript (somebody saved the page) cannot stop it playing: `updated`
// puts the bar back and the highlight with it.

export const SPEEDS = [0.75, 1, 1.25, 1.5, 2]
export const SKIP_MS = 10_000

// "7:38", "1:02:05".
export function clock(ms) {
  const total = Math.floor(Math.max(Number(ms) || 0, 0) / 1000)
  const h = Math.floor(total / 3600)
  const m = Math.floor((total % 3600) / 60)
  const s = String(total % 60).padStart(2, "0")
  return h > 0 ? `${h}:${String(m).padStart(2, "0")}:${s}` : `${m}:${s}`
}

// The turn being spoken at `ms`: the last to have started, or -1 before the
// first. `starts` is in order, as a transcript is.
export function currentTurn(starts, ms) {
  let lo = 0
  let hi = starts.length - 1
  let found = -1
  while (lo <= hi) {
    const mid = (lo + hi) >> 1
    if (starts[mid] <= ms) {
      found = mid
      lo = mid + 1
    } else {
      hi = mid - 1
    }
  }
  return found
}

// The next speed up (`step` 1) or down (-1), stopping at either end.
export function nextSpeed(current, step) {
  let i = SPEEDS.indexOf(current)
  if (i === -1) i = SPEEDS.indexOf(1)
  return SPEEDS[Math.min(SPEEDS.length - 1, Math.max(0, i + step))]
}

// Which of `texts` contain `query`, ignoring case and spacing. An empty
// query matches nothing.
export function matches(texts, query) {
  const q = normalise(query)
  if (q === "") return []
  return texts.reduce((found, text, i) => (normalise(text).includes(q) ? [...found, i] : found), [])
}

function normalise(text) {
  return String(text || "").toLowerCase().replace(/\s+/g, " ").trim()
}

// What the server's refusal means, for the person pressing play (see
// SlipdockWeb.RecordingController). `help` is what the page knows about
// where the setting is: the vault owner gets its url, anybody else the
// owner's name to ask (#784).
export function problemMessage(reason, help = {}) {
  switch (reason) {
    case "not_connected":
      return "Google Drive isn't connected for this vault."
    case "revoked":
      return "Drive access was revoked — reconnect on your account page."
    case "no_folder":
      if (help.settingsUrl) return "This vault has no recordings folder set —"
      if (help.owner) return `Ask ${help.owner} to set this vault's recordings folder.`
      return "This vault has no recordings folder set."
    case "no_vault":
      return "This page isn't in a vault, so its recording can't be played. Recordings play from a vault's recordings folder on Google Drive."
    case "not_configured":
      return "Google Drive isn't set up on this server."
    case "not_found":
      return "Recording not found on Drive."
    case "outside_folder":
      return "This recording isn't in the vault's recordings folder."
    case "not_audio":
      return "That file on Drive isn't audio."
    case "unavailable":
      return "Google Drive couldn't be reached. Try again."
    default:
      return "The recording couldn't be played."
  }
}

// The link that follows a problem's words, or null: only ever the setting
// the page itself named.
export function problemLink(reason, help = {}) {
  if (reason === "no_folder" && help.settingsUrl) return {href: help.settingsUrl, label: "Vault settings"}
  return null
}

// Keys belong to whatever is being typed in.
export function typing(target) {
  if (!target) return false
  const tag = (target.tagName || "").toLowerCase()
  return tag === "input" || tag === "textarea" || tag === "select" || target.isContentEditable === true
}

// What a key does to the player, or null.
export function keyAction(e) {
  if (e.metaKey || e.ctrlKey || e.altKey || typing(e.target)) return null
  return {" ": "toggle", ArrowLeft: "back", ArrowRight: "forward", "[": "slower", "]": "faster"}[e.key] || null
}

// What a speaker-name box asks the server for: `{from, to}`, or null when
// there is nothing to change. The server says whether the name will do.
export function speakerRename(from, typed) {
  const to = String(typed || "").trim()
  const was = String(from || "").trim()
  if (to === "" || was === "" || to === was) return null
  return {from: was, to}
}

const ICON_PLAY = "▶"
const ICON_PAUSE = "❚❚"

export const TranscriptPlayer = {
  mounted() {
    this.src = this.el.dataset.recordingSrc || null
    this.canName = this.el.dataset.canNameSpeakers === "true"
    this.problem = this.el.dataset.recordingProblem || null
    this.help = {settingsUrl: this.el.dataset.settingsUrl || null, owner: this.el.dataset.vaultOwner || null}
    this.following = true
    this.current = -1
    this.hits = []
    this.hit = -1
    this.naming = null
    this.audio = null
    this.bar = null
    this.ensure()

    this.onClick = e => this.click(e)
    this.el.addEventListener("click", this.onClick)

    // A hand on the wheel, the screen or the keys means the reader is
    // looking somewhere; the player stops dragging them back.
    this.onManualScroll = () => this.unfollow()
    window.addEventListener("wheel", this.onManualScroll, {passive: true})
    window.addEventListener("touchmove", this.onManualScroll, {passive: true})

    this.onKey = e => this.key(e)
    window.addEventListener("keydown", this.onKey)

    // Arriving at #recording scrolls there; it does not start playing.
    if (window.location.hash === "#recording" && this.bar && this.src) {
      requestAnimationFrame(() => this.bar.scrollIntoView({block: "start"}))
    }
  },

  updated() {
    // The server redrew the transcript: put the bar and the marks back.
    if (!this.ensure()) return
    this.restoreNaming()
    this.mark(this.current, false)
    this.search(this.query.value, false)
  },

  // A bar only where there is something to play or search: most pages have
  // neither, and get nothing.
  ensure() {
    if (!this.src && !this.transcript()) {
      if (this.bar) this.bar.remove()
      return false
    }
    if (!this.bar) this.build()
    this.attach()
    const transcript = this.transcript()
    if (transcript && this.src) transcript.classList.add("transcript-seekable")
    if (transcript && this.canName) {
      transcript.classList.add("transcript-nameable")
      transcript.querySelectorAll(".wiki-transcript-speaker").forEach(name => {
        name.title = "Name this voice"
      })
    }
    return true
  },

  destroyed() {
    this.el.removeEventListener("click", this.onClick)
    window.removeEventListener("wheel", this.onManualScroll)
    window.removeEventListener("touchmove", this.onManualScroll)
    window.removeEventListener("keydown", this.onKey)
    if (this.audio) {
      this.audio.pause()
      this.audio.removeAttribute("src")
      this.audio.load()
    }
  },

  // The transcript this player drives: the page's own, not one inside an
  // embedded note.
  transcript() {
    return [...this.el.querySelectorAll("[data-transcript]")].find(t => !t.closest(".wiki-embed")) || null
  },

  turns() {
    const t = this.transcript()
    return t ? [...t.querySelectorAll("li[data-start-ms]")] : []
  },

  build() {
    const bar = document.createElement("div")
    bar.className = "transcript-player"
    bar.setAttribute("data-transcript-player", "")
    bar.setAttribute("role", "region")
    bar.setAttribute("aria-label", this.src ? "Recording" : "Search the transcript")

    if (this.src) {
      bar.innerHTML = `
        <div class="transcript-player-row">
          <button type="button" class="btn btn-primary btn-sm btn-circle" data-action="toggle" aria-label="Play">${ICON_PLAY}</button>
          <button type="button" class="btn btn-ghost btn-xs" data-action="back" title="Back 10 s (←)">−10s</button>
          <button type="button" class="btn btn-ghost btn-xs" data-action="forward" title="Forward 10 s (→)">+10s</button>
          <span class="transcript-player-time font-mono text-xs tabular-nums" data-time>0:00</span>
          <input type="range" class="range range-xs flex-1" min="0" max="0" step="1" value="0" data-scrub aria-label="Position">
          <span class="transcript-player-time font-mono text-xs tabular-nums" data-duration>–:––</span>
          <select class="select select-xs w-20" data-speed aria-label="Speed" title="Speed ([ and ])">
            ${SPEEDS.map(s => `<option value="${s}"${s === 1 ? " selected" : ""}>${s}×</option>`).join("")}
          </select>
        </div>`
    }

    const tools = document.createElement("div")
    tools.className = "transcript-player-row"
    tools.innerHTML = `
      <input type="search" class="input input-xs flex-1" placeholder="Search the transcript" data-search aria-label="Search the transcript">
      <span class="text-xs text-base-content/60 tabular-nums" data-hits></span>
      <button type="button" class="btn btn-ghost btn-xs" data-action="prev-hit" aria-label="Previous match" hidden>↑</button>
      <button type="button" class="btn btn-ghost btn-xs" data-action="next-hit" aria-label="Next match" hidden>↓</button>
      <button type="button" class="btn btn-ghost btn-xs" data-action="follow" hidden>Follow</button>`
    bar.appendChild(tools)

    const problem = document.createElement("p")
    problem.className = "transcript-player-problem text-sm text-warning"
    problem.setAttribute("data-problem", "")
    problem.setAttribute("role", "status")
    problem.hidden = true
    bar.appendChild(problem)

    this.bar = bar
    this.query = bar.querySelector("[data-search]")
    this.query.addEventListener("input", () => this.search(this.query.value, true))
    this.query.addEventListener("keydown", e => {
      if (e.key === "Enter") {
        e.preventDefault()
        this.step(e.shiftKey ? -1 : 1)
      }
    })

    if (this.src) {
      this.scrub = bar.querySelector("[data-scrub]")
      this.scrub.addEventListener("input", () => this.seek(Number(this.scrub.value), false))
      this.speed = bar.querySelector("[data-speed]")
      this.speed.addEventListener("change", () => this.setSpeed(Number(this.speed.value)))
    }

    if (this.problem) this.showProblem(this.problem)
  },

  // Under the page's ## Recording heading when it has one, otherwise just
  // above the transcript, otherwise at the top.
  attach() {
    if (this.bar.isConnected && this.el.contains(this.bar)) return
    const heading = this.src && this.el.querySelector("h2#recording")
    const transcript = this.transcript()

    if (heading) heading.insertAdjacentElement("afterend", this.bar)
    else if (transcript) transcript.insertAdjacentElement("beforebegin", this.bar)
    else this.el.prepend(this.bar)
  },

  click(e) {
    if (!this.bar) return
    const action = e.target.closest("[data-action]")
    if (action && this.bar.contains(action)) {
      e.preventDefault()
      return this.act(action.dataset.action)
    }

    // A speaker's name, to put a name on that voice (#1157).
    const name = this.canName && e.target.closest(".wiki-transcript-speaker")
    if (name && this.transcript() && this.transcript().contains(name)) {
      e.preventDefault()
      return this.nameSpeaker(name)
    }
    if (e.target.closest("[data-speaker-input]")) return

    // The page's own "▶ Play recording and transcript" link: a click is a
    // gesture, so it may start the sound.
    const link = e.target.closest('a[href="#recording"]')
    if (link && this.src) {
      e.preventDefault()
      this.bar.scrollIntoView({behavior: "smooth", block: "start"})
      history.replaceState(null, "", "#recording")
      return this.play()
    }

    // A tag pressed during the recording (#785): to the moment it was pressed.
    // So is a tag's link in the summary (#787); without a recording it is
    // just a link to the chip.
    const tag = e.target.closest("[data-seek-ms]")
    if (tag && this.src && this.el.contains(tag)) {
      e.preventDefault()
      this.seek(Number(tag.dataset.seekMs), true)
      this.follow()
      return this.play()
    }

    const turn = e.target.closest("li[data-start-ms]")
    if (turn && this.src && this.turns().includes(turn)) {
      // Selecting words to copy is not a request to jump.
      if (String(window.getSelection && window.getSelection()) !== "") return
      this.seek(Number(turn.dataset.startMs), true)
      this.follow()
      this.play()
    }
  },

  act(action) {
    switch (action) {
      case "toggle":
        return this.toggle()
      case "back":
        return this.skip(-SKIP_MS)
      case "forward":
        return this.skip(SKIP_MS)
      case "slower":
        return this.setSpeed(nextSpeed(this.rate(), -1))
      case "faster":
        return this.setSpeed(nextSpeed(this.rate(), 1))
      case "follow":
        return this.follow()
      case "next-hit":
        return this.step(1)
      case "prev-hit":
        return this.step(-1)
    }
  },

  key(e) {
    if (!this.src || !this.bar || !this.bar.isConnected) return
    const action = keyAction(e)
    if (!action) return
    // A focused button acts on space itself; don't do it twice.
    if (action === "toggle" && e.target && e.target.closest && e.target.closest("button, a, summary")) return
    e.preventDefault()
    this.act(action)
  },

  // The <audio> is made on the first play, so a page that is only read
  // costs Drive nothing.
  player() {
    if (this.audio) return this.audio
    const audio = new Audio()
    audio.preload = "none"
    audio.src = this.src
    audio.playbackRate = this.speed ? Number(this.speed.value) : 1
    audio.addEventListener("timeupdate", () => this.tick())
    audio.addEventListener("durationchange", () => this.tick())
    audio.addEventListener("play", () => this.playing(true))
    audio.addEventListener("pause", () => this.playing(false))
    audio.addEventListener("error", () => this.failed())
    this.audio = audio
    return audio
  },

  play() {
    if (!this.src) return
    const result = this.player().play()
    if (result && result.catch) result.catch(() => {})
  },

  toggle() {
    if (this.audio && !this.audio.paused) this.audio.pause()
    else this.play()
  },

  rate() {
    return this.audio ? this.audio.playbackRate : Number(this.speed.value)
  },

  setSpeed(rate) {
    if (this.speed) this.speed.value = String(rate)
    if (this.audio) this.audio.playbackRate = rate
  },

  skip(ms) {
    const now = this.audio ? this.audio.currentTime * 1000 : 0
    this.seek(Math.max(0, now + ms), true)
  },

  seek(ms, play) {
    const audio = this.player()
    audio.currentTime = ms / 1000
    this.tick(ms)
    if (play && audio.paused) this.play()
  },

  playing(on) {
    const button = this.bar.querySelector('[data-action="toggle"]')
    if (!button) return
    button.textContent = on ? ICON_PAUSE : ICON_PLAY
    button.setAttribute("aria-label", on ? "Pause" : "Play")
    if (on) this.clearProblem()
  },

  tick(atMs) {
    const audio = this.audio
    const ms = atMs !== undefined ? atMs : audio ? audio.currentTime * 1000 : 0
    const duration = audio && Number.isFinite(audio.duration) ? audio.duration * 1000 : null

    this.bar.querySelector("[data-time]").textContent = clock(ms)
    if (duration) {
      this.bar.querySelector("[data-duration]").textContent = clock(duration)
      this.scrub.max = String(Math.round(duration))
    }
    this.scrub.value = String(Math.round(ms))

    const turns = this.turns()
    const index = currentTurn(turns.map(t => Number(t.dataset.startMs)), ms)
    if (index !== this.current) this.mark(index, this.following)
  },

  mark(index, scroll) {
    const turns = this.turns()
    turns.forEach((t, i) => t.classList.toggle("is-current", i === index))
    this.current = index
    if (scroll && index >= 0 && turns[index]) {
      turns[index].scrollIntoView({behavior: "smooth", block: "center"})
    }
  },

  unfollow() {
    if (!this.bar || !this.audio || this.audio.paused || !this.following) return
    this.following = false
    this.bar.querySelector('[data-action="follow"]').hidden = false
  },

  follow() {
    this.following = true
    this.bar.querySelector('[data-action="follow"]').hidden = true
    this.mark(this.current, true)
  },

  search(query, scroll) {
    const turns = this.turns()
    this.hits = matches(turns.map(t => t.textContent), query)
    turns.forEach((t, i) => t.classList.toggle("is-match", this.hits.includes(i)))
    this.hit = this.hits.length ? 0 : -1
    this.showHit(scroll)
  },

  step(direction) {
    if (!this.hits.length) return
    this.hit = (this.hit + direction + this.hits.length) % this.hits.length
    this.showHit(true)
  },

  showHit(scroll) {
    const turns = this.turns()
    const label = this.bar.querySelector("[data-hits]")
    const query = this.query.value.trim()
    label.textContent = query === "" ? "" : this.hits.length ? `${this.hit + 1}/${this.hits.length}` : "0 found"
    const many = this.hits.length > 1
    this.bar.querySelector('[data-action="next-hit"]').hidden = !many
    this.bar.querySelector('[data-action="prev-hit"]').hidden = !many
    turns.forEach(t => t.classList.remove("is-hit"))
    const turn = this.hit >= 0 ? turns[this.hits[this.hit]] : null
    if (turn) {
      turn.classList.add("is-hit")
      if (scroll) {
        this.following = false
        if (this.audio && !this.audio.paused) this.bar.querySelector('[data-action="follow"]').hidden = false
        turn.scrollIntoView({behavior: "smooth", block: "center"})
      }
    }
  },

  // A box in place of the name; Enter asks the server to rename the voice
  // throughout, which redraws the transcript. Escape, or leaving the box,
  // puts the name back. A redraw while it is open (somebody saved the page)
  // takes the box out of the page: `updated` puts it back.
  nameSpeaker(name) {
    if (this.naming) this.naming.close()
    const from = name.textContent.trim()
    const input = document.createElement("input")
    input.type = "text"
    input.className = "input input-xs w-48"
    input.value = from
    input.maxLength = 60
    input.setAttribute("data-speaker-input", "")
    input.setAttribute("aria-label", `Name for ${from}`)

    const naming = {from, input}
    naming.close = () => {
      if (this.naming !== naming) return
      this.naming = null
      input.remove()
      this.speakerName(from)?.removeAttribute("hidden")
    }

    input.addEventListener("keydown", e => {
      if (e.key === "Escape") {
        e.preventDefault()
        naming.close()
      } else if (e.key === "Enter") {
        e.preventDefault()
        const rename = speakerRename(from, input.value)
        if (rename) this.pushEvent("rename_speaker", rename)
        naming.close()
      }
    })
    // Taken out by a redraw is not leaving it.
    input.addEventListener("blur", () => setTimeout(() => {
      if (input.isConnected && document.activeElement !== input) naming.close()
    }, 0))

    this.naming = naming
    this.placeNaming(name)
    input.select()
  },

  placeNaming(name) {
    name.hidden = true
    name.insertAdjacentElement("afterend", this.naming.input)
    this.naming.input.focus()
  },

  // After a redraw: the box back beside the name it is for, or gone if that
  // voice is no longer in the transcript.
  restoreNaming() {
    if (!this.naming || this.naming.input.isConnected) return
    const name = this.speakerName(this.naming.from)
    if (name) this.placeNaming(name)
    else this.naming = null
  },

  speakerName(who) {
    const t = this.transcript()
    return t && [...t.querySelectorAll(".wiki-transcript-speaker")].find(n => n.textContent.trim() === who)
  },

  // The <audio> only says that it failed; the server says why.
  async failed() {
    let reason = null
    try {
      const response = await fetch(this.src, {headers: {Range: "bytes=0-0"}, credentials: "same-origin"})
      if (!response.ok) reason = (await response.json()).reason
    } catch (_e) {}
    this.showProblem(reason)
  },

  showProblem(reason) {
    const p = this.bar.querySelector("[data-problem]")
    p.textContent = problemMessage(reason, this.help)
    const link = problemLink(reason, this.help)
    if (link) {
      const a = document.createElement("a")
      a.className = "link"
      a.href = link.href
      a.textContent = link.label
      p.append(" ", a, ".")
    }
    p.dataset.reason = reason || ""
    p.hidden = false
  },

  clearProblem() {
    const p = this.bar.querySelector("[data-problem]")
    p.hidden = true
    p.textContent = ""
  },
}
