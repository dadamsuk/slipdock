// node --test assets/js — opening Meld blocks in the page. No browser, so the
// DOM here is the little meld_view.js touches.
import {test, beforeEach} from "node:test"
import assert from "node:assert/strict"
import {readFileSync} from "node:fs"
import {session, unlockCipher, showPlain, relock, relockAll, hintOf, installMeld, unlockWith, askPassphrase} from "./meld_view.js"

const vectors = JSON.parse(readFileSync(new URL("../../test/support/fixtures/meld_vectors.json", import.meta.url)))
const v2 = vectors.inline[0]
const note = vectors.notes[0]

class El {
  constructor(doc, tag) {
    this.ownerDocument = doc
    this.tagName = tag.toUpperCase()
    this.dataset = {}
    this.attrs = {}
    this.children = []
    this.parent = null
    this.hidden = false
    this.className = ""
    this.textContent = ""
  }
  get classList() { return {contains: c => this.className.split(" ").includes(c)} }
  get isConnected() { return this.parent ? this.parent.isConnected : this === this.ownerDocument.body }
  get previousElementSibling() {
    const i = this.parent.children.indexOf(this)
    return i > 0 ? this.parent.children[i - 1] : null
  }
  setAttribute(name, value) {
    this.attrs[name] = value
    if (name.startsWith("data-")) this.dataset[name.slice(5).replace(/-(\w)/g, (_, c) => c.toUpperCase())] = value
  }
  matches(sel) {
    return sel.split(",").some(s => {
      s = s.trim()
      if (s.startsWith(".")) return this.classList.contains(s.slice(1))
      if (s.startsWith("[")) return s.slice(1, -1) in this.attrs
      return false
    })
  }
  closest(sel) {
    for (let el = this; el; el = el.parent) if (el.matches && el.matches(sel)) return el
    return null
  }
  append(...els) { for (const el of els) { el.parent = this; this.children.push(el) } }
  after(el) {
    el.parent = this.parent
    this.parent.children.splice(this.parent.children.indexOf(this) + 1, 0, el)
  }
  remove() {
    this.parent.children.splice(this.parent.children.indexOf(this), 1)
    this.parent = null
  }
  all() { return this.children.flatMap(c => [c, ...c.all()]) }
}

function fakePage() {
  const listeners = {}
  const doc = {
    createElement: tag => new El(doc, tag),
    addEventListener: (type, fn) => (listeners["doc:" + type] = fn),
    querySelectorAll: sel => doc.body.all().filter(el => el.matches(sel)),
    getElementById: () => null,
  }
  doc.body = new El(doc, "body")
  const win = {document: doc, addEventListener: (type, fn) => (listeners["win:" + type] = fn)}
  return {doc, win, listeners}
}

function lockedBlock(doc, text = v2.text) {
  const el = new El(doc, "span")
  el.className = "meld-locked"
  el.setAttribute("data-meld-block", text)
  doc.body.append(el)
  return el
}

const cipher = {kind: "block", data: v2.text}

beforeEach(() => session.forget())

test("the right passphrase opens it; a wrong one asks again, saying so", async () => {
  const asked = []
  const answers = [{passphrase: "nope"}, {passphrase: v2.passphrase}]
  const plain = await unlockCipher(cipher, {hint: "h", prompt: o => (asked.push(o), Promise.resolve(answers.shift()))})
  assert.equal(plain, v2.plaintext)
  assert.equal(asked.length, 2)
  assert.equal(asked[0].error, "")
  assert.equal(asked[0].hint, "h")
  assert.match(asked[1].error, /doesn't open/)
  assert.deepEqual(session.passphrases, [], "not remembered unless asked")
})

test("cancelling gives null", async () => {
  assert.equal(await unlockCipher(cipher, {prompt: () => Promise.resolve(null)}), null)
})

test("a passphrase kept for the session opens the next block without asking", async () => {
  await unlockCipher(cipher, {prompt: () => Promise.resolve({passphrase: v2.passphrase, remember: true})})
  assert.deepEqual(session.passphrases, [v2.passphrase])
  const plain = await unlockCipher(cipher, {prompt: () => assert.fail("asked again")})
  assert.equal(plain, v2.plaintext)
  const asked = []
  const other = await unlockWith({kind: "block", data: vectors.inline[2].text}, {prompt: o => (asked.push(o), Promise.resolve(null))})
  assert.equal(other, null)
  assert.equal(asked.length, 1, "a different passphrase's block still asks")
  assert.deepEqual(await unlockWith(cipher, {prompt: () => assert.fail("asked again")}), {plain: v2.plaintext, passphrase: v2.passphrase}, "the remembered passphrase comes back for editing")
})

test("whole notes open the same way", async () => {
  const plain = await unlockCipher({kind: "note", data: note.file}, {prompt: () => Promise.resolve({passphrase: note.passphrase})})
  assert.equal(plain, note.plaintext)
})

test("the plaintext shows in place as text, and locks again on the timer", () => {
  const {doc} = fakePage()
  const el = lockedBlock(doc)
  let fire
  const open = showPlain(el, "<b>secret</b>", {setTimer: (fn, ms) => ((fire = fn), assert.equal(ms, 5 * 60 * 1000), 1), clearTimer: () => {}})
  assert.equal(el.hidden, true)
  assert.equal(open.previousElementSibling, el)
  assert.equal(open.children[0].textContent, "<b>secret</b>", "text, never HTML")
  fire()
  assert.equal(open.isConnected, false)
  assert.equal(el.hidden, false)
})

test("Lock and relockAll put every block back and stop its timer", () => {
  const {doc} = fakePage()
  let cleared = 0
  const opts = {setTimer: () => 1, clearTimer: () => cleared++}
  const a = showPlain(lockedBlock(doc), "a", opts)
  showPlain(lockedBlock(doc), "b", opts)
  relock(a)
  assert.equal(cleared, 1)
  relockAll(doc)
  assert.equal(cleared, 2)
  assert.equal(doc.querySelectorAll("[data-meld-open]").length, 0)
  assert.ok(doc.querySelectorAll(".meld-locked").every(el => !el.hidden))
  relock(a)
  relock(null)
})

test("hintOf reads the hint from the block or the note", () => {
  const {doc} = fakePage()
  assert.equal(hintOf(lockedBlock(doc)), v2.hint)
  const n = new El(doc, "div")
  n.setAttribute("data-meld-note", note.file)
  assert.equal(hintOf(n), note.hint)
  assert.equal(hintOf(new El(doc, "span")), "")
})

test("installed: a click opens a block, and navigating away locks it", async () => {
  const {doc, win, listeners} = fakePage()
  const el = lockedBlock(doc)
  let prompted = 0
  installMeld(win, {prompt: () => (prompted++, Promise.resolve({passphrase: v2.passphrase})), setTimer: () => 1, clearTimer: () => {}})
  let prevented = false
  listeners["doc:click"]({target: el, preventDefault: () => (prevented = true)})
  assert.ok(prevented)
  await new Promise(r => setTimeout(r, 400))
  assert.equal(prompted, 1)
  const [open] = doc.querySelectorAll("[data-meld-open]")
  assert.equal(open.children[0].textContent, v2.plaintext)
  listeners["win:phx:page-loading-start"]()
  assert.equal(doc.querySelectorAll("[data-meld-open]").length, 0)
  assert.equal(el.hidden, false)
})

test("installed: the Lock button locks, and Enter opens from the keyboard", async () => {
  const {doc, win, listeners} = fakePage()
  const el = lockedBlock(doc)
  installMeld(win, {prompt: () => Promise.resolve({passphrase: v2.passphrase}), setTimer: () => 1, clearTimer: () => {}})
  listeners["doc:keydown"]({key: "Enter", target: el, preventDefault() {}})
  await new Promise(r => setTimeout(r, 400))
  const [open] = doc.querySelectorAll("[data-meld-open]")
  listeners["doc:click"]({target: open.children[1], preventDefault() {}})
  assert.equal(doc.querySelectorAll("[data-meld-open]").length, 0)
  listeners["doc:keydown"]({key: "a", target: el, preventDefault: () => assert.fail("not a key that opens")})
})

test("nothing in the view can send, store or log what it decrypts", () => {
  for (const file of ["./meld_view.js", "./meld.js"]) {
    const source = readFileSync(new URL(file, import.meta.url), "utf8").replace(/^\s*\/\/.*$/gm, "")
    for (const leak of ["pushEvent", "fetch(", "XMLHttpRequest", "localStorage", "sessionStorage", "indexedDB", "console.", "sendBeacon", "WebSocket"]) {
      assert.ok(!source.includes(leak), `${file} mentions ${leak}`)
    }
  }
})

// The root layout's #meld-dialog, as little of it as askPassphrase touches. A
// submit runs the form's listeners as the browser would; one not prevented
// closes the dialog with the button's value, as method="dialog" does.
function fakeDialog() {
  const field = () => ({value: "", checked: false, hidden: false, textContent: "", focused: false, focus() { this.focused = true }})
  const sels = ["[data-meld-passphrase]", "[data-meld-confirm]", "[data-meld-new-hint]", "[data-meld-remember]", "[data-meld-text]",
    "[data-meld-error]", "#meld-dialog-title", "[data-meld-ok]", "[data-meld-hint]", "[data-meld-text-row]", "[data-meld-text-label]",
    "[data-meld-pass-rows]", "[data-meld-confirm-row]", "[data-meld-hint-row]", "[data-meld-remove]"]
  const els = Object.fromEntries(sels.map(s => [s, field()]))
  const submitListeners = new Set()
  els["[data-meld-form]"] = {
    addEventListener: (type, fn) => type === "submit" && submitListeners.add(fn),
    removeEventListener: (type, fn) => type === "submit" && submitListeners.delete(fn),
  }
  let onClose = null
  const dialog = {
    returnValue: "x",
    open: false,
    querySelector: sel => els[sel] ?? assert.fail(`unexpected selector ${sel}`),
    addEventListener: (type, fn, opts) => {
      assert.equal(type, "close")
      assert.deepEqual(opts, {once: true})
      onClose = fn
    },
    showModal() { this.open = true },
    close(value) {
      this.open = false
      this.returnValue = value
      const fn = onClose
      onClose = null
      fn && fn()
    },
  }
  // Presses a button: true when the dialog closed, false when the submit was refused.
  const press = value => {
    let prevented = false
    const e = {submitter: {value}, preventDefault: () => (prevented = true)}
    for (const fn of submitListeners) fn(e)
    if (!prevented) dialog.close(value)
    return !prevented
  }
  const el = name => els[`[data-meld-${name}]`]
  return {dialog, els, el, press, submitListeners}
}

for (const [label, mode, fill, message] of [
  ["empty text on insert", "insert", {text: "", pass: "pw", confirm: "pw"}, "Type the text to encrypt."],
  ["an empty passphrase", "encrypt", {pass: "", confirm: ""}, "Enter a passphrase."],
  ["an empty passphrase on insert", "insert", {text: "secret", pass: "", confirm: ""}, "Enter a passphrase."],
  ["passphrases that differ", "encrypt", {pass: "pw", confirm: "pW"}, "The two passphrases don't match."],
  ["passphrases that differ on insert", "insert", {text: "secret", pass: "pw", confirm: "pw "}, "The two passphrases don't match."],
  ["a hint with a line break", "encrypt", {pass: "pw", confirm: "pw", hint: "a\nb"}, "The hint can't hold 💡, 🔐 or a line break."],
  ["a hint with 🔐", "insert", {text: "secret", pass: "pw", confirm: "pw", hint: "lock 🔐"}, "The hint can't hold 💡, 🔐 or a line break."],
]) {
  test(`askPassphrase refuses ${label}: the submit is prevented and says why`, async () => {
    const {dialog, el, press} = fakeDialog()
    const answer = askPassphrase(dialog, {mode})
    assert.equal(el("error").hidden, true, "no error before the submit")
    if (fill.text !== undefined) el("text").value = fill.text
    el("passphrase").value = fill.pass
    el("confirm").value = fill.confirm
    el("new-hint").value = fill.hint ?? ""
    assert.equal(press("ok"), false, "the submit was prevented")
    assert.equal(dialog.open, true, "the dialog stays open")
    assert.equal(el("error").textContent, message)
    assert.equal(el("error").hidden, false)
    // Put right, the same dialog then closes with the answer.
    el("text").value = "secret"
    el("passphrase").value = el("confirm").value = "pw"
    el("new-hint").value = "fine"
    assert.equal(press("ok"), true)
    assert.deepEqual(await answer, {action: "ok", passphrase: "pw", remember: false, hint: "fine", text: "secret"})
  })
}

test("askPassphrase checks nothing but an encrypting OK: decrypt, edit and cancel pass straight through", async () => {
  for (const mode of ["decrypt", "edit"]) {
    const {dialog, press, el} = fakeDialog()
    const answer = askPassphrase(dialog, {mode})
    assert.equal(press("ok"), true, `${mode} is not checked`)
    await answer
    assert.equal(el("error").textContent, "")
  }
  const {dialog, press} = fakeDialog()
  const answer = askPassphrase(dialog, {mode: "insert"})
  assert.equal(press("cancel"), true, "cancel is never refused")
  assert.equal(await answer, null)
})

test("askPassphrase: cancel resolves null, and every typed field is wiped on close", async () => {
  for (const mode of ["decrypt", "encrypt", "insert", "edit"]) {
    const {dialog, el, submitListeners} = fakeDialog()
    const answer = askPassphrase(dialog, {mode, text: "old secret"})
    el("passphrase").value = "pw"
    el("confirm").value = "pw"
    el("text").value = "new secret"
    dialog.close("") // Escape, or the Cancel button
    assert.equal(await answer, null, `${mode}: cancel gives null`)
    assert.equal(el("passphrase").value, "", `${mode}: passphrase wiped`)
    assert.equal(el("confirm").value, "", `${mode}: confirm wiped`)
    assert.equal(el("text").value, "", `${mode}: text wiped`)
    assert.equal(submitListeners.size, 0, `${mode}: the submit guard is removed`)
  }
})

test("askPassphrase: an answer is read before the wipe, and the wipe still happens", async () => {
  const {dialog, el, press} = fakeDialog()
  const answer = askPassphrase(dialog, {mode: "insert"})
  el("text").value = "the secret"
  el("passphrase").value = el("confirm").value = "pw"
  el("remember").checked = true
  assert.equal(press("ok"), true)
  assert.deepEqual(await answer, {action: "ok", passphrase: "pw", remember: true, hint: "", text: "the secret"})
  assert.equal(el("passphrase").value, "")
  assert.equal(el("confirm").value, "")
  assert.equal(el("text").value, "")
})

test("askPassphrase: OK with no passphrase is null, except in edit mode", async () => {
  {
    const {dialog} = fakeDialog()
    const answer = askPassphrase(dialog, {mode: "decrypt"})
    dialog.close("ok")
    assert.equal(await answer, null)
  }
  {
    const {dialog} = fakeDialog()
    const answer = askPassphrase(dialog, {mode: "edit", text: "changed"})
    dialog.close("ok")
    assert.deepEqual(await answer, {action: "ok", passphrase: "", remember: false, hint: "", text: "changed"})
  }
})

test("askPassphrase: remove resolves only in edit mode", async () => {
  for (const mode of ["decrypt", "encrypt", "insert"]) {
    const {dialog, el} = fakeDialog()
    const answer = askPassphrase(dialog, {mode})
    el("passphrase").value = el("confirm").value = "pw"
    el("text").value = "secret"
    dialog.close("remove")
    assert.equal(await answer, null, `${mode}: remove is not an answer`)
  }
  const {dialog, el} = fakeDialog()
  const answer = askPassphrase(dialog, {mode: "edit", text: "plain"})
  assert.equal(el("remove").hidden, false, "Remove shows in edit mode")
  dialog.close("remove")
  assert.deepEqual(await answer, {action: "remove", passphrase: "", remember: false, hint: "", text: "plain"})
  assert.equal(el("text").value, "", "the decrypted text is wiped after Remove too")
})

test("askPassphrase opens on a clean dialog: fields cleared, error and hint shown, focus placed", async () => {
  const {dialog, el, els} = fakeDialog()
  el("passphrase").value = el("confirm").value = el("new-hint").value = "left over"
  const answer = askPassphrase(dialog, {mode: "decrypt", hint: "pet", error: "That passphrase doesn't open it."})
  assert.equal(dialog.open, true)
  assert.equal(dialog.returnValue, "")
  assert.equal(el("passphrase").value, "")
  assert.equal(el("confirm").value, "")
  assert.equal(el("new-hint").value, "")
  assert.equal(el("hint").textContent, "Hint: pet")
  assert.equal(el("error").textContent, "That passphrase doesn't open it.")
  assert.equal(el("error").hidden, false)
  assert.equal(els["#meld-dialog-title"].textContent, "Decrypt")
  assert.equal(el("passphrase").focused, true)
  dialog.close("")
  await answer
})
