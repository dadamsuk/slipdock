// Replaying a passage of a meeting's recording, on the Resolve screen.
//
// The element carries `data-src` (the recording), `data-from` and `data-to`
// (the passage, in milliseconds) and `data-duration`. Its buttons replay the
// passage at normal speed or at 0.75×, and loop it; a canvas shows the
// recording's shape with the passage marked, drawn from the audio itself
// when the browser can decode it. Each replay tells the server which
// passage was listened to (`replayed`), so an answer given after it is
// recorded as given after replaying 7:38–7:44.

// "7:38", "1:02:05": how a time reads on the page and in the record.
export function clock(ms) {
  const total = Math.floor(Math.max(ms, 0) / 1000)
  const h = Math.floor(total / 3600)
  const m = Math.floor((total % 3600) / 60)
  const s = String(total % 60).padStart(2, "0")
  return h > 0 ? `${h}:${String(m).padStart(2, "0")}:${s}` : `${m}:${s}`
}

// "7:38–7:44"
export function spanLabel(from, to) {
  return `${clock(from)}–${clock(to)}`
}

// The loudest sample in each of `bins` slices: the shape a waveform draws.
export function peaks(samples, bins) {
  const out = new Array(bins).fill(0)
  if (!samples || samples.length === 0 || bins <= 0) return out
  const size = samples.length / bins
  for (let b = 0; b < bins; b++) {
    const start = Math.floor(b * size)
    const end = Math.max(start + 1, Math.floor((b + 1) * size))
    let max = 0
    for (let i = start; i < end && i < samples.length; i++) {
      const v = Math.abs(samples[i])
      if (v > max) max = v
    }
    out[b] = max
  }
  return out
}

// Where the passage sits on a strip `width` wide, as {x, w}.
export function spanBox(from, to, duration, width) {
  if (!duration || duration <= 0) return {x: 0, w: 0}
  const x = Math.max(0, Math.min(width, (from / duration) * width))
  const end = Math.max(0, Math.min(width, (to / duration) * width))
  return {x, w: Math.max(1, end - x)}
}

// Whether playback has run past the passage: stop, or go round again.
export function pastEnd(currentMs, to) {
  return currentMs >= to
}

export const Replay = {
  mounted() {
    this.audio = new Audio(this.el.dataset.src)
    this.audio.preload = "none"
    this.looping = false

    this.audio.addEventListener("timeupdate", () => {
      if (pastEnd(this.audio.currentTime * 1000, this.to())) {
        if (this.looping) this.audio.currentTime = this.from() / 1000
        else this.audio.pause()
      }
    })

    this.el.querySelectorAll("[data-replay]").forEach(button => {
      button.addEventListener("click", () => this.play(Number(button.dataset.replay) || 1))
    })

    const loop = this.el.querySelector("[data-loop]")
    if (loop) {
      loop.addEventListener("click", () => {
        this.looping = !this.looping
        loop.setAttribute("aria-pressed", String(this.looping))
        if (this.looping && this.audio.paused) this.play(this.audio.playbackRate || 1)
      })
    }

    this.draw()
  },

  destroyed() {
    if (this.audio) this.audio.pause()
  },

  from() { return Number(this.el.dataset.from) || 0 },
  to() { return Number(this.el.dataset.to) || this.from() + 5000 },

  play(rate) {
    this.audio.playbackRate = rate
    this.audio.currentTime = this.from() / 1000
    this.audio.play().catch(() => {})
    this.pushEvent("replayed", {from: this.from(), to: this.to(), rate})
  },

  // The waveform, when the browser will decode the recording; otherwise the
  // strip with the passage marked is still drawn.
  async draw() {
    const canvas = this.el.querySelector("canvas")
    if (!canvas || !canvas.getContext) return
    const ctx = canvas.getContext("2d")
    const {width, height} = canvas
    const duration = Number(this.el.dataset.duration) || this.to()
    const box = spanBox(this.from(), this.to(), duration, width)

    const paint = bars => {
      ctx.clearRect(0, 0, width, height)
      ctx.fillStyle = "rgba(234, 179, 8, 0.25)"
      ctx.fillRect(box.x, 0, box.w, height)
      ctx.fillStyle = "rgba(100, 116, 139, 0.8)"
      bars.forEach((p, i) => {
        const h = Math.max(1, p * height)
        ctx.fillRect(i, (height - h) / 2, 1, h)
      })
    }

    paint(new Array(width).fill(0.05))

    try {
      const Ctx = window.AudioContext || window.webkitAudioContext
      if (!Ctx) return
      const response = await fetch(this.el.dataset.src)
      const decoded = await new Ctx().decodeAudioData(await response.arrayBuffer())
      paint(peaks(decoded.getChannelData(0), width))
    } catch (_e) {
      // A recording the browser can't decode keeps the plain strip.
    }
  },
}
