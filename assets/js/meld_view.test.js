// node --test assets/js — opening Meld blocks in the page. No browser, so the
// DOM here is the little meld_view.js touches.
import {test, beforeEach} from "node:test"
import assert from "node:assert/strict"
import {readFileSync} from "node:fs"
import {session, unlockCipher, showPlain, relock, relockAll, hintOf, installMeld, tryRemembered} from "./meld_view.js"

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
  assert.equal(await tryRemembered({kind: "block", data: vectors.inline[2].text}), null, "a different passphrase's block still asks")
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
