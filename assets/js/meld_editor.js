// Encrypting in the page editor, in Meld Encrypt's format (W-103 R6.2, R6.4).
//
// The body textarea sends every change to the server (phx-change), so a
// secret must never be typed there. New secrets are typed into the
// passphrase dialog, which lives outside LiveView, and only the ciphertext is
// put into the textarea. Encrypting text that is already in the body is
// allowed, but that text has been on the server: the browser then fetches
// the page's revisions, finds those still holding it here, says how many,
// and (for the board's owner, once they confirm) names them in a hidden
// field the save purges. The server is told revision ids, never the text.

import {findBlocks, encryptBlock, hasEncrypted} from "./meld.js"
import {dialogPrompt, unlockWith, session} from "./meld_view.js"
import {ask} from "./confirm.js"

const REMOVE = "Put the decrypted text back into the page as ordinary text? It is sent to the server and kept in the page's history."

// The block the caret (or the start of the selection) is in, or null.
export function blockAt(text, position) {
  return findBlocks(text).find(b => position >= b.start && position <= b.end) || null
}

// True when [start, end) overlaps an encrypted block.
export function touchesBlock(text, start, end) {
  return findBlocks(text).some(b => start < b.end && end > b.start)
}

export function splice(text, start, end, insert) {
  return text.slice(0, start) + insert + text.slice(end)
}

// The revisions whose body still holds the plaintext.
export function revisionsHolding(revisions, plaintext) {
  const needle = (plaintext || "").trim()
  if (!needle) return []
  return revisions.filter(r => (r.body || "").includes(needle)).map(r => r.id)
}

export function mergeIds(current, more) {
  const ids = new Set((current || "").split(",").filter(Boolean).map(Number))
  more.forEach(id => ids.add(Number(id)))
  return [...ids].sort((a, b) => a - b).join(",")
}

// Each action takes the textarea's text and selection and the means to ask,
// and resolves to {text, caret, exposed} or null; `exposed` is plaintext that
// was already in the body, for the history check. They never touch the DOM.
export async function encryptAction({text, start, end, prompt, encrypt = encryptBlock}) {
  if (start === end) {
    const answer = await prompt({mode: "insert"})
    if (!answer) return null
    const block = await encrypt(answer.text, answer.passphrase, {hint: answer.hint})
    if (answer.remember) session.remember(answer.passphrase)
    return {text: splice(text, start, end, block), caret: start + block.length, exposed: null}
  }
  if (touchesBlock(text, start, end)) return {error: "The selection holds encrypted text already."}
  const plain = text.slice(start, end)
  const answer = await prompt({mode: "encrypt"})
  if (!answer) return null
  const block = await encrypt(plain, answer.passphrase, {hint: answer.hint})
  if (answer.remember) session.remember(answer.passphrase)
  return {text: splice(text, start, end, block), caret: start + block.length, exposed: plain}
}

export async function wholeAction({text, prompt, encrypt = encryptBlock}) {
  if (!text.trim()) return {error: "There is nothing to encrypt yet."}
  if (hasEncrypted(text)) return {error: "The note holds encrypted text already. Remove that encryption first, then encrypt the whole note."}
  const answer = await prompt({mode: "encrypt"})
  if (!answer) return null
  const block = await encrypt(text, answer.passphrase, {hint: answer.hint})
  if (answer.remember) session.remember(answer.passphrase)
  return {text: block, caret: block.length, exposed: text}
}

export async function editAction({text, start, prompt, confirmRemove, encrypt = encryptBlock}) {
  const block = blockAt(text, start)
  if (!block) return {error: "Put the cursor in an encrypted block first."}
  const opened = await unlockWith({kind: "block", data: block.text}, {hint: block.hint, prompt})
  if (!opened) return null
  const answer = await prompt({mode: "edit", hint: block.hint, text: opened.plain})
  if (!answer) return null
  if (answer.action === "remove") {
    if (!(await confirmRemove())) return null
    return {text: splice(text, block.start, block.end, answer.text), caret: block.start + answer.text.length, exposed: null}
  }
  const again = await encrypt(answer.text, opened.passphrase, {hint: block.hint, visible: block.visible})
  return {text: splice(text, block.start, block.end, again), caret: block.start + again.length, exposed: null}
}

const ACTIONS = {encrypt: encryptAction, whole: wholeAction, edit: editAction}

export const MeldEditor = {
  mounted() {
    this.textarea = document.getElementById(this.el.dataset.textarea)
    this.note = this.el.querySelector("[data-meld-note]")
    this.purge = this.el.querySelector("[data-meld-purge]")
    this.prompt = dialogPrompt(document)
    this.el.addEventListener("click", e => {
      const button = e.target.closest("[data-meld-action]")
      if (button) this.run(button.dataset.meldAction)
      // The button carries data-confirm, so confirm.js has asked by now.
      if (e.target.closest("[data-meld-purge-confirm]")) this.choosePurge(true)
      if (e.target.closest("[data-meld-purge-undo]")) this.choosePurge(false)
    })
  },

  async run(name) {
    const ta = this.textarea
    if (!ta) return
    this.say("")
    const result = await ACTIONS[name]({
      text: ta.value,
      start: ta.selectionStart,
      end: ta.selectionEnd,
      prompt: this.prompt,
      confirmRemove: () => {
        const dialog = document.getElementById("confirm-dialog")
        return dialog && dialog.showModal ? ask(dialog, REMOVE, "Remove encryption", "danger") : Promise.resolve(window.confirm(REMOVE))
      },
    })
    if (!result) return
    if (result.error) return this.say(result.error)
    ta.value = result.text
    ta.selectionStart = ta.selectionEnd = result.caret
    ta.dispatchEvent(new Event("input", {bubbles: true}))
    ta.focus()
    if (result.exposed) this.checkHistory(result.exposed)
  },

  checkHistory(plaintext) {
    this.pushEvent("meld_history", {}, reply => {
      const ids = revisionsHolding(reply.revisions || [], plaintext)
      if (!ids.length) return
      const n = ids.length === 1 ? "1 earlier revision still holds" : `${ids.length} earlier revisions still hold`
      if (!reply.owner) return this.say(`${n} this text in plain. Only the board's owner can purge them.`)
      this.pending = mergeIds(this.pending ? this.pending.join(",") : "", ids).split(",").map(Number)
      this.say(`${n} this text in plain.`, this.pending.length)
    })
  },

  choosePurge(yes) {
    this.purge.value = yes ? mergeIds("", this.pending || []) : ""
    const n = (this.pending || []).length
    const words = n === 1 ? "1 earlier revision" : `${n} earlier revisions`
    this.say(yes ? `${words} holding this text in plain will be purged when you save.` : `${words} still hold this text in plain.`, n, yes)
  },

  say(message, purgeable = 0, chosen = false) {
    if (!this.note) return
    this.note.textContent = message
    this.note.hidden = !message
    if (!purgeable) return
    const button = document.createElement("button")
    button.type = "button"
    button.className = "btn btn-ghost btn-xs ml-2"
    if (chosen) {
      button.setAttribute("data-meld-purge-undo", "")
      button.textContent = "Keep them"
    } else {
      button.setAttribute("data-meld-purge-confirm", "")
      button.setAttribute("data-confirm", `Purge ${purgeable === 1 ? "that revision" : `those ${purgeable} revisions`} when you save? They are deleted for good; the page as you save it is kept.`)
      button.setAttribute("data-confirm-label", "Purge when saved")
      button.textContent = "Purge them when I save"
    }
    this.note.append(button)
  },
}
