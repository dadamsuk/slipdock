// The app's own "are you sure?" box, in place of the browser's.
//
// Anything that asks first carries `data-confirm="Delete this card?"`. On its
// own, phoenix_html answers that with `window.confirm` — a grey box in the
// browser's chrome, headed by the site's address, with buttons that say OK
// and Cancel whatever is about to happen. This takes the click first, in the
// capture phase on window, before phoenix_html or LiveView see it; asks with
// the `<dialog id="confirm-dialog">` the root layout renders; and on a yes
// clicks the same element again with its `data-confirm` lifted for that one
// click, so whatever it was going to do — a phx-click, a form submit, a
// data-method link — happens exactly as it would have.
//
// A page without the dialog (or a browser without <dialog>) is left alone,
// and phoenix_html's window.confirm still asks: never go ahead unasked.

// Words that start something that cannot be taken back. The confirm button
// goes red for these, and Cancel is the one that has the focus.
const DANGER = /^\s*(delete|remove|revoke|discard|withdraw)\b/i

// What the yes button says: `data-confirm-label` if the element names it,
// otherwise the element's own words when they are short enough to be a
// button ("Delete", "Revoke"), otherwise its aria-label or title, and only
// then plain OK — an icon-only button has no words of its own.
export function confirmLabel(el) {
  const explicit = el.getAttribute("data-confirm-label")
  if (explicit) return explicit

  const text = (el.textContent || "").replace(/\s+/g, " ").trim()
  if (text && text.length <= 24) return text

  return el.getAttribute("aria-label") || el.getAttribute("title") || "OK"
}

export function confirmTone(message, label) {
  return DANGER.test(label || "") || DANGER.test(message || "") ? "danger" : "normal"
}

// Shows the dialog and resolves to true only when the confirm button closed
// it. Escape, the backdrop and Cancel all leave returnValue as something else.
export function ask(dialog, message, label, tone) {
  const text = dialog.querySelector("#confirm-dialog-message")
  const ok = dialog.querySelector("[data-confirm-ok]")
  const cancel = dialog.querySelector("[data-confirm-cancel]")

  text.textContent = message
  ok.textContent = label
  ok.classList.toggle("btn-error", tone === "danger")
  ok.classList.toggle("btn-primary", tone !== "danger")
  dialog.returnValue = ""

  return new Promise(resolve => {
    dialog.addEventListener("close", () => resolve(dialog.returnValue === "confirm"), {once: true})
    dialog.showModal()
    ;(tone === "danger" ? cancel : ok).focus()
  })
}

// The yes: the same click again, with nothing left to ask. The attribute
// comes back straight afterwards, so the next click asks again. An element
// LiveView has taken off the page while the box was open is not clicked —
// it is no longer the thing that was asked about.
export function proceed(el) {
  if (!el.isConnected) return false
  const message = el.getAttribute("data-confirm")
  el.removeAttribute("data-confirm")
  try {
    el.click()
  } finally {
    el.setAttribute("data-confirm", message)
  }
  return true
}

export function installConfirm(win) {
  const doc = win.document

  win.addEventListener("click", e => {
    const el = e.target && e.target.closest ? e.target.closest("[data-confirm]") : null
    if (!el) return

    const dialog = doc.getElementById("confirm-dialog")
    if (!dialog || typeof dialog.showModal !== "function") return

    e.preventDefault()
    e.stopImmediatePropagation()
    if (dialog.open) return

    const message = el.getAttribute("data-confirm")
    const label = confirmLabel(el)
    ask(dialog, message, label, confirmTone(message, label)).then(yes => {
      if (yes) proceed(el)
    })
  }, true)
}
