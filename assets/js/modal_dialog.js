// A <dialog> the server shows and hides with :if, opened with showModal():
// that puts it in the browser's top layer, so a modal it sits inside — one
// with a backdrop-filter, which would otherwise be what a fixed box is
// positioned against — can't trap or scroll it away.
//
// Escape, or a click on the backdrop (a <form method="dialog">), closes it
// natively; the hook tells the server with the event in data-close-event, so
// the :if follows. Escape stops at the dialog: the page's own Escape (closing
// the modal underneath) mustn't hear it too.
//
// The element wants phx-mounted={JS.ignore_attributes("open")}, or the next
// patch takes away the open attribute showModal() set.
export const ModalDialog = {
  mounted() {
    this.onKeydown = e => { if (e.key === "Escape") e.stopPropagation() }
    this.onClose = () => {
      const event = this.el.dataset.closeEvent
      if (event && this.el.isConnected) this.pushEventTo(this.el, event, {})
    }
    this.el.addEventListener("keydown", this.onKeydown)
    this.el.addEventListener("close", this.onClose)
    this.open()
  },

  updated() { this.open() },

  open() {
    if (!this.el.open && typeof this.el.showModal === "function") this.el.showModal()
  },

  destroyed() {
    this.el.removeEventListener("keydown", this.onKeydown)
    this.el.removeEventListener("close", this.onClose)
  },
}
