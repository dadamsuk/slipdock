// node --test assets/js — encrypting in the page editor. The actions take
// text and a selection and give text back, so no DOM is needed; what the
// textarea (and so the server) would be sent is exactly `result.text`.
import {test, beforeEach} from "node:test"
import assert from "node:assert/strict"
import {readFileSync} from "node:fs"
import {blockAt, touchesBlock, splice, revisionsHolding, mergeIds, encryptAction, wholeAction, editAction, MeldEditor} from "./meld_editor.js"
import {decryptBlock, findBlocks} from "./meld.js"
import {session} from "./meld_view.js"
import {CryptoHelperFactory, InlineParser} from "../../test/support/fixtures/meld_reference.mjs"

const vectors = JSON.parse(readFileSync(new URL("../../test/support/fixtures/meld_vectors.json", import.meta.url)))
const v2 = vectors.inline[0]
const hidden = vectors.inline[1]

// A prompt that answers each mode from a script, and records what it was asked.
function scripted(answers) {
  const asked = []
  const prompt = o => {
    asked.push(o)
    const next = answers.shift()
    return Promise.resolve(typeof next === "function" ? next(o) : next)
  }
  return {prompt, asked}
}

async function meldReads(block, passphrase) {
  const parsed = new InlineParser(block)
  assert.ok(parsed.canDecrypt, block)
  return CryptoHelperFactory.BuildFromDecryptableOrThrow(parsed.decryptable).decryptFromBase64(parsed.decryptable.base64CipherText, passphrase)
}

beforeEach(() => session.forget())

test("a new secret is typed in the dialog: the body gets only ciphertext, Meld reads it", async () => {
  const {prompt, asked} = scripted([{action: "ok", text: "IBAN GB00 1234", passphrase: "pw", hint: "bank"}])
  const result = await encryptAction({text: "Account: \nend", start: 9, end: 9, prompt})
  assert.equal(asked[0].mode, "insert")
  assert.ok(!result.text.includes("IBAN"), "plaintext never reaches the body")
  assert.equal(result.exposed, null, "nothing was ever in the body, so no history to check")
  const [block] = findBlocks(result.text)
  assert.ok(result.text.startsWith("Account: 🔐β 💡bank💡"))
  assert.ok(result.text.endsWith(" 🔐\nend"))
  assert.equal(result.caret, block.end)
  assert.equal(await meldReads(block.text, "pw"), "IBAN GB00 1234")
})

test("encrypting a selection replaces it, and reports it as already exposed", async () => {
  const {prompt, asked} = scripted([{action: "ok", passphrase: "pw", hint: "", remember: true}])
  const text = "keep this SECRET and this"
  const result = await encryptAction({text, start: 10, end: 16, prompt})
  assert.equal(asked[0].mode, "encrypt")
  assert.equal(result.exposed, "SECRET")
  assert.ok(!result.text.includes("SECRET"))
  assert.ok(result.text.startsWith("keep this 🔐β ") && result.text.endsWith(" 🔐 and this"))
  assert.equal(await decryptBlock(findBlocks(result.text)[0], "pw"), "SECRET")
  assert.deepEqual(session.passphrases, ["pw"])
})

test("a selection that holds a block already is refused, and cancelling changes nothing", async () => {
  const text = `a ${v2.text} b`
  assert.match((await encryptAction({text, start: 0, end: 5, prompt: () => assert.fail()})).error, /encrypted text already/)
  assert.equal(await encryptAction({text: "abc", start: 0, end: 2, prompt: () => Promise.resolve(null)}), null)
  assert.equal(await encryptAction({text: "abc", start: 1, end: 1, prompt: () => Promise.resolve(null)}), null)
})

test("encrypt whole note: the body becomes one block Meld reads back whole", async () => {
  const body = "# Diary\n\nDear diary,\n- one\n"
  const {prompt} = scripted([{action: "ok", passphrase: "pw", hint: "d"}])
  const result = await wholeAction({text: body, prompt})
  const blocks = findBlocks(result.text)
  assert.equal(blocks.length, 1)
  assert.equal(blocks[0].text, result.text)
  assert.equal(result.exposed, body)
  assert.equal(await meldReads(result.text, "pw"), body)
})

test("encrypt whole note refuses an empty note and one holding a block", async () => {
  assert.match((await wholeAction({text: "  \n", prompt: () => assert.fail()})).error, /nothing to encrypt/)
  assert.match((await wholeAction({text: `x ${v2.text}`, prompt: () => assert.fail()})).error, /already/)
})

test("decrypt to edit: changed text is encrypted again with the same passphrase, hint and marker", async () => {
  const text = `Top\n${hidden.text}\nBottom`
  const {prompt, asked} = scripted([
    {action: "ok", passphrase: hidden.passphrase},
    o => ({action: "ok", text: o.text + "\nadded line", passphrase: ""}),
  ])
  const result = await editAction({text, start: 6, prompt, confirmRemove: () => assert.fail()})
  assert.deepEqual(asked.map(a => a.mode), ["decrypt", "edit"])
  assert.equal(asked[1].text, hidden.plaintext)
  const [block] = findBlocks(result.text)
  assert.equal(block.visible, false, "a hidden (%%) block stays hidden")
  assert.equal(block.hint, hidden.hint)
  assert.ok(result.text.startsWith("Top\n%%🔐β ") && result.text.endsWith(" 🔐%%\nBottom"))
  assert.equal(await meldReads(block.text, hidden.passphrase), hidden.plaintext + "\nadded line")
  assert.equal(result.exposed, null)
})

test("decrypt to edit: a remembered passphrase is not asked for, a wrong one is asked again", async () => {
  session.remember(v2.passphrase)
  const {prompt, asked} = scripted([o => ({action: "ok", text: o.text})])
  await editAction({text: v2.text, start: 3, prompt, confirmRemove: () => assert.fail()})
  assert.deepEqual(asked.map(a => a.mode), ["edit"])

  session.forget()
  const again = scripted([{passphrase: "wrong"}, {passphrase: v2.passphrase}, null])
  assert.equal(await editAction({text: v2.text, start: 3, prompt: again.prompt}), null)
  assert.match(again.asked[1].error, /doesn't open/)
})

test("remove encryption puts the plaintext back, only once confirmed", async () => {
  const text = `PIN: ${v2.text}.`
  const answers = () => scripted([{passphrase: v2.passphrase}, o => ({action: "remove", text: o.text})])
  const yes = await editAction({text, start: 7, prompt: answers().prompt, confirmRemove: () => Promise.resolve(true)})
  assert.equal(yes.text, `PIN: ${v2.plaintext}.`)
  const no = await editAction({text, start: 7, prompt: answers().prompt, confirmRemove: () => Promise.resolve(false)})
  assert.equal(no, null)
})

test("decrypt to edit outside a block says where to put the cursor", async () => {
  assert.match((await editAction({text: `plain ${v2.text}`, start: 2, prompt: () => assert.fail()})).error, /cursor/)
})

test("blockAt, touchesBlock and splice", () => {
  const text = `ab ${v2.text} cd`
  assert.equal(blockAt(text, 3).text, v2.text)
  assert.equal(blockAt(text, 3 + v2.text.length).text, v2.text, "the caret just after the block is still in it")
  assert.equal(blockAt(text, 1), null)
  assert.ok(touchesBlock(text, 0, 4))
  assert.ok(!touchesBlock(text, 0, 3))
  assert.equal(splice("hello", 1, 3, "XY"), "hXYlo")
})

test("revisionsHolding finds only the revisions with the text, and nothing for blank text", () => {
  const revisions = [{id: 1, body: "old PIN 4921"}, {id: 2, body: "no pin"}, {id: 3, body: "PIN 4921 again"}, {id: 4, body: null}]
  assert.deepEqual(revisionsHolding(revisions, " PIN 4921 "), [1, 3])
  assert.deepEqual(revisionsHolding(revisions, "  "), [])
  assert.deepEqual(revisionsHolding(revisions, null), [])
})

test("mergeIds keeps each id once, in order", () => {
  assert.equal(mergeIds("3,1", [2, 3]), "1,2,3")
  assert.equal(mergeIds("", []), "")
})

// The hook itself, on a fake element, document and pushEvent: what it shows
// in the note and what it writes to the hidden purge_revisions input, which
// names the revisions the save deletes for good.
function fakeElement(attrs = {}) {
  return {
    attrs,
    children: [],
    setAttribute(name, value) { this.attrs[name] = value },
    append(child) { this.children.push(child) },
    // Only the `[data-…]` selectors the hook's click listener uses.
    closest(selector) { return selector.slice(1, -1) in this.attrs ? this : null },
  }
}

function mountHook({value = "", start = 0, end = 0, reply = {revisions: []}, answers} = {}) {
  const ta = {
    value, selectionStart: start, selectionEnd: end,
    events: [], focused: 0,
    dispatchEvent(e) { this.events.push(e.type) },
    focus() { this.focused++ },
  }
  // Setting the text drops what was appended, as in a browser.
  const note = {
    children: [], hidden: true, text: "",
    set textContent(v) { this.text = v; this.children = [] },
    get textContent() { return this.text },
    append(child) { this.children.push(child) },
  }
  const purge = {value: ""}
  const listeners = {}
  const el = {
    dataset: {textarea: "page_body"},
    querySelector: selector => ({"[data-meld-note]": note, "[data-meld-purge]": purge})[selector] || null,
    addEventListener: (type, fn) => { listeners[type] = fn },
  }
  // No #meld-dialog: the hook's own prompt answers null, a cancelled dialog.
  globalThis.document = {
    getElementById: id => (id === "page_body" ? ta : null),
    createElement: () => fakeElement(),
  }
  const pushed = []
  const hook = Object.create(MeldEditor)
  hook.el = el
  hook.pushEvent = (event, payload, onReply) => {
    pushed.push(event)
    onReply(typeof reply === "function" ? reply() : reply)
  }
  hook.mounted()
  if (answers) hook.prompt = scripted(answers).prompt
  const click = target => listeners.click({target})
  return {hook, ta, note, purge, pushed, click}
}

const HISTORY = [
  {id: 3, body: "nothing of it"},
  {id: 2, body: "before\nthe launch code\nafter"},
  {id: 1, body: "the launch code"},
]

test("the hook: an owner is told, and only confirming names the revisions to purge; undo empties the field", async () => {
  const {hook, ta, note, purge, pushed, click} = mountHook({
    value: "the launch code",
    reply: {owner: true, revisions: HISTORY},
    answers: [{action: "ok", passphrase: "pw", hint: ""}],
  })
  await hook.run("whole")

  assert.equal(await meldReads(ta.value, "pw"), "the launch code")
  assert.deepEqual(ta.events, ["input"], "the server is sent the ciphertext")
  assert.equal(ta.focused, 1)
  assert.deepEqual(pushed, ["meld_history"])
  assert.equal(note.textContent, "2 earlier revisions still hold this text in plain.")
  assert.equal(note.hidden, false)
  assert.equal(note.children.length, 1)
  const confirm = note.children[0]
  assert.ok("data-meld-purge-confirm" in confirm.attrs)
  assert.match(confirm.attrs["data-confirm"], /^Purge those 2 revisions when you save\?/)
  assert.equal(confirm.type, "button")
  assert.equal(purge.value, "", "nothing is purged until the owner confirms")

  click(confirm)
  assert.equal(purge.value, "1,2")
  assert.equal(note.textContent, "2 earlier revisions holding this text in plain will be purged when you save.")
  assert.equal(note.children.length, 1)
  const undo = note.children[0]
  assert.ok("data-meld-purge-undo" in undo.attrs)
  assert.ok(!("data-meld-purge-confirm" in undo.attrs))

  click(undo)
  assert.equal(purge.value, "")
  assert.equal(note.textContent, "2 earlier revisions still hold this text in plain.")
  assert.ok("data-meld-purge-confirm" in note.children[0].attrs, "the purge is offered again")

  click(note.children[0])
  assert.equal(purge.value, "1,2", "and can be chosen again")
})

test("the hook: a click elsewhere in the element leaves the purge field alone", async () => {
  const {hook, purge, note, click} = mountHook({
    value: "the launch code",
    reply: {owner: true, revisions: HISTORY},
    answers: [{action: "ok", passphrase: "pw", hint: ""}],
  })
  await hook.run("whole")
  click(fakeElement({"data-other": ""}))
  assert.equal(purge.value, "")
  assert.ok("data-meld-purge-confirm" in note.children[0].attrs)
})

test("the hook: a second encryption adds its revisions to the first's, each id once", async () => {
  const revisions = [{id: 7, body: "alpha and beta"}, {id: 5, body: "alpha here"}, {id: 2, body: "beta"}, {id: 9, body: "no match"}]
  const {hook, ta, note, purge, click} = mountHook({
    value: "alpha and beta",
    start: 0,
    end: 5,
    reply: {owner: true, revisions},
    answers: [{action: "ok", passphrase: "pw", hint: ""}, {action: "ok", passphrase: "pw", hint: ""}],
  })
  await hook.run("encrypt")
  assert.equal(note.textContent, "2 earlier revisions still hold this text in plain.")
  assert.match(note.children[0].attrs["data-confirm"], /^Purge those 2 revisions when you save\?/)

  ta.selectionStart = ta.value.indexOf("beta")
  ta.selectionEnd = ta.value.length
  await hook.run("encrypt")
  assert.ok(!ta.value.includes("alpha") && !ta.value.includes("beta"))
  assert.equal(note.textContent, "2 earlier revisions still hold this text in plain.", "the note counts this text's revisions")
  assert.match(note.children[0].attrs["data-confirm"], /^Purge those 3 revisions when you save\?/, "the button counts every pending revision")

  click(note.children[0])
  assert.equal(purge.value, "2,5,7", "the first text's revisions are still named")
  assert.equal(note.textContent, "3 earlier revisions holding this text in plain will be purged when you save.")
})

test("the hook: one revision is purged and undone in the singular", async () => {
  const {hook, note, purge, click} = mountHook({
    value: "the launch code",
    reply: {owner: true, revisions: [HISTORY[2]]},
    answers: [{action: "ok", passphrase: "pw", hint: ""}],
  })
  await hook.run("whole")
  assert.equal(note.textContent, "1 earlier revision still holds this text in plain.")
  assert.match(note.children[0].attrs["data-confirm"], /^Purge that revision when you save\?/)
  click(note.children[0])
  assert.equal(purge.value, "1")
  assert.equal(note.textContent, "1 earlier revision holding this text in plain will be purged when you save.")
  click(note.children[0])
  assert.equal(purge.value, "")
  assert.equal(note.textContent, "1 earlier revision still holds this text in plain.")
})

test("the hook: someone who isn't the owner is told, and is offered no purge button", async () => {
  const {hook, ta, note, purge} = mountHook({
    value: "the launch code",
    reply: {owner: false, revisions: HISTORY},
    answers: [{action: "ok", passphrase: "pw", hint: ""}],
  })
  await hook.run("whole")
  assert.equal(await meldReads(ta.value, "pw"), "the launch code", "the text is encrypted all the same")
  assert.equal(note.textContent, "2 earlier revisions still hold this text in plain. Only the board's owner can purge them.")
  assert.equal(note.hidden, false)
  assert.deepEqual(note.children, [])
  assert.equal(hook.pending, undefined, "nothing is kept to purge")
  assert.equal(purge.value, "")
})

test("the hook: no revision holding the text means no note and no button, and a reply without revisions is read as none", async () => {
  for (const reply of [{owner: true, revisions: [HISTORY[0]]}, {owner: true}]) {
    const {hook, note, purge, pushed} = mountHook({
      value: "the launch code",
      reply,
      answers: [{action: "ok", passphrase: "pw", hint: ""}],
    })
    await hook.run("whole")
    assert.deepEqual(pushed, ["meld_history"])
    assert.equal(note.textContent, "")
    assert.equal(note.hidden, true)
    assert.deepEqual(note.children, [])
    assert.equal(purge.value, "")
  }
})

test("the hook: a secret typed in the dialog was never in the body, so the history isn't asked for", async () => {
  const {hook, ta, pushed, note} = mountHook({
    value: "Account: ",
    start: 9,
    end: 9,
    answers: [{action: "ok", text: "IBAN GB00 1234", passphrase: "pw", hint: ""}],
  })
  await hook.run("encrypt")
  assert.ok(ta.value.startsWith("Account: ") && ta.value.length > 9)
  assert.ok(!ta.value.includes("IBAN"))
  assert.equal(ta.selectionStart, ta.value.length, "the caret ends after the block")
  assert.deepEqual(pushed, [])
  assert.equal(note.hidden, true)
})

test("the hook: an action that errors says why and leaves the textarea as it was", async () => {
  const {hook, ta, note, purge, pushed} = mountHook({value: "   ", start: 1, end: 2, answers: []})
  await hook.run("whole")
  assert.equal(ta.value, "   ")
  assert.deepEqual([ta.selectionStart, ta.selectionEnd], [1, 2])
  assert.deepEqual(ta.events, [], "the server is sent nothing")
  assert.equal(ta.focused, 0)
  assert.equal(note.textContent, "There is nothing to encrypt yet.")
  assert.equal(note.hidden, false)
  assert.deepEqual(note.children, [])
  assert.deepEqual(pushed, [])
  assert.equal(purge.value, "")
})

test("the hook: a cancelled dialog leaves the textarea as it was, and clears an earlier message", async () => {
  // No answers given: the hook's own prompt finds no dialog and answers null.
  const {hook, ta, note, purge, pushed} = mountHook({value: "the launch code", start: 4, end: 10})
  hook.say("An earlier message.")
  await hook.run("encrypt")
  assert.equal(ta.value, "the launch code")
  assert.deepEqual([ta.selectionStart, ta.selectionEnd], [4, 10])
  assert.deepEqual(ta.events, [])
  assert.equal(ta.focused, 0)
  assert.equal(note.textContent, "")
  assert.equal(note.hidden, true)
  assert.deepEqual(pushed, [])
  assert.equal(purge.value, "")
})

test("the hook: clicking an action button runs that action, and no textarea means nothing runs", async () => {
  const {hook, ta, note, click} = mountHook({value: ""})
  const ran = []
  hook.run = name => ran.push(name)
  click({...fakeElement({"data-meld-action": "whole"}), dataset: {meldAction: "whole"}})
  assert.deepEqual(ran, ["whole"])
  delete hook.run

  hook.textarea = null
  hook.say("Still here.")
  await hook.run("whole")
  assert.equal(note.textContent, "Still here.")
  assert.equal(ta.value, "")
})

