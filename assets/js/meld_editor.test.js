// node --test assets/js — encrypting in the page editor. The actions take
// text and a selection and give text back, so no DOM is needed; what the
// textarea (and so the server) would be sent is exactly `result.text`.
import {test, beforeEach} from "node:test"
import assert from "node:assert/strict"
import {readFileSync} from "node:fs"
import {blockAt, touchesBlock, splice, revisionsHolding, mergeIds, encryptAction, wholeAction, editAction} from "./meld_editor.js"
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
