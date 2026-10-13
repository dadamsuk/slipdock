// Meld Encrypt's format (the Obsidian plugin meld-cp/obsidian-encrypt), read
// and written in the browser with WebCrypto, so the passphrase and the
// plaintext never leave it. Checked against Meld 2.4.5's own code: the test
// vectors in test/support/fixtures/meld_vectors.json were made by running it.
//
// Inline:  🔐β 💡hint💡<base64> 🔐      (visible in Obsidian's reading view)
//          %%🔐β 💡hint💡<base64> 🔐%%  (hidden there; same thing otherwise)
//   β  version 2: PBKDF2-SHA512, 210000 rounds, random 16-byte salt;
//      AES-256-GCM, random 16-byte iv; bytes are iv ‖ salt ‖ ciphertext+tag.
//   α  version 1: PBKDF2-SHA256, 1000 rounds, a fixed salt; iv ‖ ciphertext.
//   (none) version 0: key = SHA-256(passphrase), a fixed iv.
// Whole note (.mdenc): JSON {"version": "2.0"|"1.0", "hint", "encodedData"}.
// Only version 2 is written; 0 and 1 are read so old notes still open.

const enc = new TextEncoder()
const dec = new TextDecoder()
const subtle = () => globalThis.crypto.subtle

const V1_SALT = enc.encode("XHWnDAT6ehMVY2zD")
const V0_IV = new Uint8Array([196, 190, 240, 190, 188, 78, 41, 132, 15, 220, 84, 211])
const V2 = {iv: 16, salt: 16, iterations: 210000}

const PREFIX = {2: "🔐β ", 1: "🔐α ", 0: "🔐 "}

// One inline block. Meld's own parser takes the hint up to the next 💡 and
// the rest as base64; base64 never holds a space, so the closing " 🔐" is the
// first space after it.
export const INLINE = /(%%)?🔐(β |α | )(?:💡([^💡\n]*)💡)?([A-Za-z0-9+/=]*) 🔐(%%)?/gu

const versionOf = marker => (marker === "β " ? 2 : marker === "α " ? 1 : 0)

// Every inline block in a text, in order, with where it sits.
export function findBlocks(text) {
  const blocks = []
  for (const m of text.matchAll(INLINE)) {
    blocks.push({
      start: m.index,
      end: m.index + m[0].length,
      text: m[0],
      version: versionOf(m[2]),
      hint: m[3] || "",
      base64: m[4],
      visible: !m[1],
    })
  }
  return blocks
}

export function parseBlock(text) {
  const [block] = findBlocks(text)
  return block && block.start === 0 && block.end === text.length ? block : null
}

export function hasEncrypted(text) {
  return findBlocks(text || "").length > 0
}

// Writes a block the way Meld's encodeEncryption does.
export function encodeBlock(base64, hint = "", visible = true) {
  const open = visible ? PREFIX[2] : "%%" + PREFIX[2]
  const close = visible ? " 🔐" : " 🔐%%"
  return open + (hint ? `💡${hint}💡` : "") + base64 + close
}

export function checkHint(hint) {
  if (/[💡🔐\n]/u.test(hint || "")) return "The hint can't hold 💡, 🔐 or a line break."
  return null
}

function toBase64(bytes) {
  let s = ""
  for (let i = 0; i < bytes.length; i++) s += String.fromCharCode(bytes[i])
  return btoa(s)
}

function fromBase64(b64) {
  const s = atob(b64)
  const bytes = new Uint8Array(s.length)
  for (let i = 0; i < s.length; i++) bytes[i] = s.charCodeAt(i)
  return bytes
}

async function pbkdf2Key(passphrase, salt, iterations, hash) {
  const raw = await subtle().importKey("raw", enc.encode(passphrase), "PBKDF2", false, ["deriveKey"])
  return subtle().deriveKey({name: "PBKDF2", hash, salt, iterations}, raw, {name: "AES-GCM", length: 256}, false, ["encrypt", "decrypt"])
}

// Encrypts to version 2's base64, as Meld's default helper does.
export async function encryptBase64(plaintext, passphrase) {
  const salt = globalThis.crypto.getRandomValues(new Uint8Array(V2.salt))
  const iv = globalThis.crypto.getRandomValues(new Uint8Array(V2.iv))
  const key = await pbkdf2Key(passphrase, salt, V2.iterations, "SHA-512")
  const sealed = new Uint8Array(await subtle().encrypt({name: "AES-GCM", iv}, key, enc.encode(plaintext)))
  const out = new Uint8Array(iv.length + salt.length + sealed.length)
  out.set(iv, 0)
  out.set(salt, iv.length)
  out.set(sealed, iv.length + salt.length)
  return toBase64(out)
}

// The plaintext, or null for a wrong passphrase or damaged ciphertext.
export async function decryptBase64(base64, passphrase, version = 2) {
  try {
    const bytes = fromBase64(base64)
    let key, iv, sealed
    if (version === 2) {
      iv = bytes.slice(0, V2.iv)
      key = await pbkdf2Key(passphrase, bytes.slice(V2.iv, V2.iv + V2.salt), V2.iterations, "SHA-512")
      sealed = bytes.slice(V2.iv + V2.salt)
    } else if (version === 1) {
      iv = bytes.slice(0, 16)
      key = await pbkdf2Key(passphrase, V1_SALT, 1000, "SHA-256")
      sealed = bytes.slice(16)
    } else if (version === 0) {
      iv = V0_IV
      const digest = await subtle().digest("SHA-256", enc.encode(passphrase))
      key = await subtle().importKey("raw", digest, {name: "AES-GCM"}, false, ["decrypt"])
      sealed = bytes
    } else {
      return null
    }
    return dec.decode(await subtle().decrypt({name: "AES-GCM", iv}, key, sealed))
  } catch (_e) {
    return null
  }
}

export async function encryptBlock(plaintext, passphrase, {hint = "", visible = true} = {}) {
  return encodeBlock(await encryptBase64(plaintext, passphrase), hint, visible)
}

export async function decryptBlock(block, passphrase) {
  const parsed = typeof block === "string" ? parseBlock(block) : block
  return parsed ? decryptBase64(parsed.base64, passphrase, parsed.version) : null
}

// Whole-note files (.mdenc), written as Meld writes them: JSON, two-space indent.
export function parseNote(json) {
  try {
    const data = JSON.parse(json)
    if (data && typeof data.encodedData === "string" && (data.version === "1.0" || data.version === "2.0")) {
      return {version: data.version, hint: data.hint || "", encodedData: data.encodedData}
    }
  } catch (_e) {}
  return null
}

export async function encryptNote(plaintext, passphrase, hint = "") {
  const encodedData = await encryptBase64(plaintext, passphrase)
  return JSON.stringify({version: "2.0", hint, encodedData}, null, 2)
}

export async function decryptNote(json, passphrase) {
  const note = parseNote(json)
  if (!note) return null
  if (note.encodedData === "") return ""
  return decryptBase64(note.encodedData, passphrase, note.version === "1.0" ? 1 : 2)
}
