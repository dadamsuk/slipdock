// Meld Encrypt's encrypted text on a page, opened in the browser (W-103 R6).
//
// The server draws each block locked: `.meld-locked` carrying its ciphertext
// in `data-meld-block` (an inline block) or `data-meld-note` (a whole .mdenc
// note). Selecting one asks for the passphrase in the root layout's
// `#meld-dialog`, decrypts with WebCrypto (meld.js), and shows the plaintext
// in place, as text. Nothing here talks to the server: no pushEvent, no
// fetch, no storage, no console. The plaintext is gone again when the reader
// locks it, after RELOCK_MS, on navigation, or on reload; a passphrase kept
// "for this session" lives in this module's memory and nowhere else.

import {decryptBlock, decryptNote, parseBlock, parseNote, checkHint} from "./meld.js"

export const RELOCK_MS = 5 * 60 * 1000

// Passphrases the reader asked to keep, newest first. Memory only.
export const session = {
  passphrases: [],
  remember(passphrase) {
    this.passphrases = [passphrase, ...this.passphrases.filter(p => p !== passphrase)].slice(0, 5)
  },
  forget() {
    this.passphrases = []
  },
}

function cipherOf(el) {
  if (el.dataset.meldBlock !== undefined) return {kind: "block", data: el.dataset.meldBlock}
  if (el.dataset.meldNote !== undefined) return {kind: "note", data: el.dataset.meldNote}
  return null
}

export function hintOf(el) {
  const c = cipherOf(el)
  if (!c) return ""
  const parsed = c.kind === "block" ? parseBlock(c.data) : parseNote(c.data)
  return (parsed && parsed.hint) || ""
}

export function decryptCipher(cipher, passphrase) {
  return cipher.kind === "block" ? decryptBlock(cipher.data, passphrase) : decryptNote(cipher.data, passphrase)
}

// The plaintext with the first remembered passphrase that opens it, or null.
export async function tryRemembered(cipher) {
  for (const p of session.passphrases) {
    const plain = await decryptCipher(cipher, p)
    if (plain !== null) return plain
  }
  return null
}

// Opens the dialog and resolves to {passphrase, remember, hint} or null.
// mode "decrypt" asks once; "encrypt" asks twice and for a hint, and will
// not close on a mismatch or a hint that would break the format.
export function askPassphrase(dialog, {mode = "decrypt", hint = "", error = ""} = {}) {
  const q = sel => dialog.querySelector(sel)
  const form = q("[data-meld-form]")
  const pass = q("[data-meld-passphrase]")
  const confirm = q("[data-meld-confirm]")
  const newHint = q("[data-meld-new-hint]")
  const remember = q("[data-meld-remember]")
  const err = q("[data-meld-error]")
  const encrypting = mode === "encrypt"

  q("#meld-dialog-title").textContent = encrypting ? "Encrypt" : "Decrypt"
  q("[data-meld-ok]").textContent = encrypting ? "Encrypt" : "Decrypt"
  q("[data-meld-hint]").textContent = hint ? `Hint: ${hint}` : ""
  q("[data-meld-hint]").hidden = !hint
  q("[data-meld-confirm-row]").hidden = !encrypting
  q("[data-meld-hint-row]").hidden = !encrypting
  err.textContent = error
  err.hidden = !error
  pass.value = confirm.value = newHint.value = ""
  dialog.returnValue = ""

  const check = e => {
    if (!encrypting || e.submitter?.value !== "ok") return
    const problem = !pass.value ? "Enter a passphrase."
      : pass.value !== confirm.value ? "The two passphrases don't match."
      : checkHint(newHint.value)
    if (problem) {
      e.preventDefault()
      err.textContent = problem
      err.hidden = false
    }
  }
  form.addEventListener("submit", check)

  return new Promise(resolve => {
    dialog.addEventListener("close", () => {
      form.removeEventListener("submit", check)
      const result = dialog.returnValue === "ok" && pass.value
        ? {passphrase: pass.value, remember: remember.checked, hint: newHint.value}
        : null
      // The passphrase does not stay in the page once it has been read.
      pass.value = confirm.value = ""
      resolve(result)
    }, {once: true})
    dialog.showModal()
    pass.focus()
  })
}

// Asks until the passphrase opens it or the reader gives up. Resolves to the
// plaintext, or null.
export async function unlockCipher(cipher, {hint = "", prompt}) {
  const remembered = await tryRemembered(cipher)
  if (remembered !== null) return remembered
  let error = ""
  for (;;) {
    const answer = await prompt({mode: "decrypt", hint, error})
    if (!answer) return null
    const plain = await decryptCipher(cipher, answer.passphrase)
    if (plain !== null) {
      if (answer.remember) session.remember(answer.passphrase)
      return plain
    }
    error = "That passphrase doesn't open it."
  }
}

// Puts the plaintext beside the locked element (hidden meanwhile), with a
// Lock button. Returns the open element.
export function showPlain(el, plaintext, {relockMs = RELOCK_MS, setTimer = setTimeout, clearTimer = clearTimeout} = {}) {
  const doc = el.ownerDocument
  const open = doc.createElement(el.dataset.meldNote !== undefined ? "div" : "span")
  open.className = "meld-open"
  open.setAttribute("data-meld-open", "")
  const text = doc.createElement("span")
  text.className = "meld-plain"
  text.textContent = plaintext
  const lock = doc.createElement("button")
  lock.type = "button"
  lock.className = "meld-lock"
  lock.setAttribute("data-meld-lock", "")
  lock.title = "Lock again"
  lock.textContent = "🔒 Lock"
  open.append(text, lock)
  el.hidden = true
  el.after(open)
  const timer = setTimer(() => relock(open), relockMs)
  open.meldRelock = () => clearTimer(timer)
  return open
}

export function relock(open) {
  if (!open || !open.isConnected) return
  if (open.meldRelock) open.meldRelock()
  const locked = open.previousElementSibling
  open.remove()
  if (locked && locked.classList.contains("meld-locked")) locked.hidden = false
}

export function relockAll(doc) {
  doc.querySelectorAll("[data-meld-open]").forEach(relock)
}

export function installMeld(win, opts = {}) {
  const doc = win.document
  const prompt = opts.prompt || (o => {
    const dialog = doc.getElementById("meld-dialog")
    return dialog && dialog.showModal ? askPassphrase(dialog, o) : Promise.resolve(null)
  })

  const open = async el => {
    if (el.dataset.meldBusy) return
    el.dataset.meldBusy = "1"
    try {
      const cipher = cipherOf(el)
      const plain = cipher && (await unlockCipher(cipher, {hint: hintOf(el), prompt}))
      if (plain !== null && plain !== undefined && el.isConnected && !el.hidden) showPlain(el, plain, opts)
    } finally {
      delete el.dataset.meldBusy
    }
  }

  doc.addEventListener("click", e => {
    const target = e.target && e.target.closest ? e.target : null
    if (!target) return
    const lock = target.closest("[data-meld-lock]")
    if (lock) return relock(lock.closest("[data-meld-open]"))
    const el = target.closest(".meld-locked")
    if (el) {
      e.preventDefault()
      open(el)
    }
  })

  doc.addEventListener("keydown", e => {
    if (e.key !== "Enter" && e.key !== " ") return
    const el = e.target && e.target.closest ? e.target.closest(".meld-locked") : null
    if (el) {
      e.preventDefault()
      open(el)
    }
  })

  // Leaving the page locks everything: a live navigation keeps this script
  // running, so the plaintext would otherwise outlive the page it was on.
  win.addEventListener("phx:page-loading-start", () => relockAll(doc))
  win.addEventListener("pagehide", () => relockAll(doc))
}
