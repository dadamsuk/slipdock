// A toast that closes itself after a few seconds (#1847).
//
// It runs the toast's own `phx-click` commands (clear the flash, hide it)
// rather than clicking it. A real click bubbles to the document, and every
// open modal's `phx-click-away` reads that as a click outside and closes: the
// person panel, board settings and the card all shut 4.5s after a save.

export const DISMISS_AFTER = 4500

// Runs `el`'s phx-click through `exec(js)`; a toast with none is left.
export function dismiss(el, exec) {
  const js = el.getAttribute("phx-click")
  if (js) exec(js)
}

export const AutoDismiss = {
  mounted() {
    this.timer = setTimeout(
      // A hook's js().exec runs the commands on the hook's own element.
      () => dismiss(this.el, js => this.js().exec(js)),
      DISMISS_AFTER
    )
  },
  destroyed() { clearTimeout(this.timer) },
}
