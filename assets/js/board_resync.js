// A board page that has fallen behind catches up, or says it can't (#2918).
//
// A board page is told of every change by a broadcast, and draws the board
// again. One open for hours was found showing the board as it had been in
// the afternoon, with no banner: either a broadcast never reached it, or its
// connection had stopped answering without the browser noticing. The second
// can happen on the long-poll transport the socket falls back to: it sends
// no heartbeats, so nothing finds out that its polling stopped.
//
// So the page asks. When its tab comes back into view, when the browser is
// back online, and once a minute while it is in view, it pushes `resync`:
// the server compares a hash of the board with the one it drew from, and
// draws it again if they differ. No answer within ANSWER_WITHIN means the
// connection isn't answering: the notice says the board may be out of date,
// and the socket is reconnected, which mounts the page afresh. A reconnect
// hides the notice.

export const PROBE_EVERY = 60_000
export const ANSWER_WITHIN = 15_000

// One question in flight at a time; a second asked meanwhile waits for it.
export function probe(hook) {
  if (hook.waiting) return
  hook.waiting = setTimeout(() => {
    hook.waiting = null
    noAnswer(hook)
  }, ANSWER_WITHIN)
  hook.pushEvent("resync", {}, () => {
    clearTimeout(hook.waiting)
    hook.waiting = null
    showNotice(hook, false)
  })
}

// Only while the socket says it is connected: a socket that knows it is down
// shows the reconnecting banner already, and is reconnecting by itself.
export function noAnswer(hook) {
  if (!hook.liveSocket.isConnected()) return
  showNotice(hook, true)
  hook.liveSocket.disconnect(() => hook.liveSocket.connect())
}

export function showNotice(hook, shown) {
  const notice = hook.el.querySelector("[data-stale-notice]")
  if (notice) notice.hidden = !shown
}

export const BoardResync = {
  mounted() {
    this.waiting = null
    this.ask = () => { if (document.visibilityState === "visible") probe(this) }
    document.addEventListener("visibilitychange", this.ask)
    window.addEventListener("online", this.ask)
    // A page brought back from the back-forward cache missed everything.
    window.addEventListener("pageshow", this.ask)
    this.interval = setInterval(this.ask, PROBE_EVERY)
  },
  reconnected() {
    clearTimeout(this.waiting)
    this.waiting = null
    showNotice(this, false)
  },
  destroyed() {
    clearTimeout(this.waiting)
    clearInterval(this.interval)
    document.removeEventListener("visibilitychange", this.ask)
    window.removeEventListener("online", this.ask)
    window.removeEventListener("pageshow", this.ask)
  },
}
