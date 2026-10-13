// node --test assets/js — Meld's format both ways: the vectors were made by
// Meld Encrypt's own code, and its code (cut out of the plugin) reads ours.
import {test} from "node:test"
import assert from "node:assert/strict"
import {readFileSync} from "node:fs"
import * as meld from "./meld.js"
import {CryptoHelperFactory, InlineParser, FileDataHelper} from "../../test/support/fixtures/meld_reference.mjs"

const vectors = JSON.parse(readFileSync(new URL("../../test/support/fixtures/meld_vectors.json", import.meta.url)))

test("decrypts every inline block Meld wrote, in every version", async () => {
  for (const v of vectors.inline) {
    const block = meld.parseBlock(v.text)
    assert.ok(block, v.text)
    assert.equal(block.version, v.version)
    assert.equal(block.hint, v.hint)
    assert.equal(block.visible, v.visible)
    assert.equal(await meld.decryptBlock(block, v.passphrase), v.plaintext)
  }
})

test("a wrong passphrase gives null, not garbage or a throw", async () => {
  for (const v of vectors.inline) assert.equal(await meld.decryptBlock(v.text, v.passphrase + "x"), null)
})

test("damaged ciphertext gives null", async () => {
  const v = vectors.inline[0]
  const block = meld.parseBlock(v.text)
  const flipped = (block.base64[10] === "A" ? "B" : "A")
  assert.equal(await meld.decryptBase64(block.base64.slice(0, 10) + flipped + block.base64.slice(11), v.passphrase), null)
  assert.equal(await meld.decryptBase64("not base64 at all!", v.passphrase), null)
  assert.equal(await meld.decryptBase64(block.base64, v.passphrase, 7), null)
})

test("Meld decrypts what Slipdock encrypts, hint and reading-view marker kept", async () => {
  for (const visible of [true, false]) {
    const plaintext = "Sort code 12-34-56\nün 🎉"
    const text = await meld.encryptBlock(plaintext, "s3cret ü", {hint: "bank", visible})
    const parsed = new InlineParser(text)
    assert.ok(parsed.canDecrypt)
    assert.equal(parsed.decryptable.version, 2)
    assert.equal(parsed.decryptable.hint, "bank")
    assert.equal(parsed.decryptable.showInReadingView, visible)
    const helper = CryptoHelperFactory.BuildFromDecryptableOrThrow(parsed.decryptable)
    assert.equal(await helper.decryptFromBase64(parsed.decryptable.base64CipherText, "s3cret ü"), plaintext)
  }
})

test("encrypting twice gives different ciphertext (fresh salt and iv)", async () => {
  const a = await meld.encryptBase64("same", "pw")
  const b = await meld.encryptBase64("same", "pw")
  assert.notEqual(a, b)
})

test("no hint writes no 💡 pair", async () => {
  const text = await meld.encryptBlock("x", "pw")
  assert.ok(text.startsWith("🔐β ") && text.endsWith(" 🔐"))
  assert.ok(!text.includes("💡"))
})

test("findBlocks finds each block in a page, with where it sits", () => {
  const [a, b] = vectors.inline
  const page = `# Title\n\nPIN: ${a.text} and\n${b.text}\nend 🔐 not a block`
  const blocks = meld.findBlocks(page)
  assert.equal(blocks.length, 2)
  assert.equal(page.slice(blocks[0].start, blocks[0].end), a.text)
  assert.equal(page.slice(blocks[1].start, blocks[1].end), b.text)
  assert.ok(meld.hasEncrypted(page))
  assert.ok(!meld.hasEncrypted("just 🔐 an emoji 🔐"))
  assert.ok(!meld.hasEncrypted(null))
})

test("parseBlock wants exactly one block and nothing else", () => {
  const t = vectors.inline[0].text
  assert.equal(meld.parseBlock("x" + t), null)
  assert.equal(meld.parseBlock("plain"), null)
})

test("hints that would break the format are refused", () => {
  assert.equal(meld.checkHint("fine"), null)
  assert.equal(meld.checkHint(""), null)
  for (const bad of ["a💡b", "a🔐", "two\nlines"]) assert.ok(meld.checkHint(bad))
})

test("whole-note files: Meld's read here, ours read by Meld", async () => {
  for (const n of vectors.notes) {
    assert.equal((await meld.decryptNote(n.file, n.passphrase)), n.plaintext)
    if (n.plaintext !== "") assert.equal(await meld.decryptNote(n.file, "wrong"), null)
  }
  const ours = await meld.encryptNote("# Whole\nnote", "pw", "h")
  assert.match(ours, /^\{\n  "version": "2.0",\n  "hint": "h",\n  "encodedData": "/)
  assert.equal(await FileDataHelper.decrypt(JSON.parse(ours), "pw"), "# Whole\nnote")
  assert.equal(meld.parseNote("{\"version\": \"3.0\", \"encodedData\": \"\"}"), null)
  assert.equal(meld.parseNote("# not json"), null)
  assert.equal(await meld.decryptNote("nope", "pw"), null)
})
