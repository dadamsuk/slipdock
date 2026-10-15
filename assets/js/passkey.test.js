// node --test assets/js — no browser: `credentials` and `fetch` are fakes
// that record what they were given, and the form is the two methods
// signIn() touches.
import {test} from "node:test"
import assert from "node:assert/strict"
import {
  toBase64url, fromBase64url, creationOptions, requestOptions, attestationJSON,
  assertionJSON, failureMessage, supported, signIn, register,
} from "./passkey.js"

const bytes = (...b) => new Uint8Array(b).buffer
const view = buffer => Array.from(new Uint8Array(buffer))

test("base64url round-trips, unpadded, with the url-safe alphabet", () => {
  const all = new Uint8Array(256).map((_, i) => i).buffer
  assert.deepEqual(view(fromBase64url(toBase64url(all))), view(all))
  assert.equal(toBase64url(bytes(0xfb, 0xff)), "-_8")
  assert.equal(toBase64url(bytes(1)), "AQ")
  assert.deepEqual(view(fromBase64url("-_8")), [0xfb, 0xff])
  assert.deepEqual(view(fromBase64url("AQ==")), [1])
  assert.deepEqual(view(fromBase64url("")), [])
})

test("creation options decode the challenge, the user id and the exclusions", () => {
  const options = creationOptions({
    challenge: "AQID", user: {id: "AAAAAAAAAAc", name: "a@example.com"},
    excludeCredentials: [{type: "public-key", id: "BAU"}], attestation: "none",
  })
  assert.deepEqual(view(options.challenge), [1, 2, 3])
  assert.deepEqual(view(options.user.id), [0, 0, 0, 0, 0, 0, 0, 7])
  assert.equal(options.user.name, "a@example.com")
  assert.deepEqual(view(options.excludeCredentials[0].id), [4, 5])
  assert.equal(options.attestation, "none")
  assert.deepEqual(creationOptions({challenge: "AQ", user: {id: "AQ"}}).excludeCredentials, [])
})

test("request options decode the challenge, and any allowed credentials", () => {
  const options = requestOptions({challenge: "AQID", rpId: "example.com"})
  assert.deepEqual(view(options.challenge), [1, 2, 3])
  assert.equal(options.rpId, "example.com")
  assert.equal(options.allowCredentials, undefined)
  assert.deepEqual(view(requestOptions({challenge: "AQ", allowCredentials: [{id: "Bg"}]}).allowCredentials[0].id), [6])
})

test("an attestation and an assertion are encoded for the server", () => {
  assert.deepEqual(
    attestationJSON({id: "abc", response: {attestationObject: bytes(1), clientDataJSON: bytes(2)}}),
    {id: "abc", attestationObject: "AQ", clientDataJSON: "Ag"},
  )
  const response = {authenticatorData: bytes(1), signature: bytes(2), clientDataJSON: bytes(3)}
  assert.deepEqual(
    assertionJSON({rawId: bytes(9), response: {...response, userHandle: bytes(7)}}),
    {id: "CQ", authenticatorData: "AQ", signature: "Ag", clientDataJSON: "Aw", userHandle: "Bw"},
  )
  // No handle (or an empty one) is left out rather than sent empty.
  assert.equal("userHandle" in assertionJSON({rawId: bytes(9), response: {...response, userHandle: null}}), false)
  assert.equal("userHandle" in assertionJSON({rawId: bytes(9), response: {...response, userHandle: bytes()}}), false)
})

test("cancelling is silent; other refusals say what happened", () => {
  assert.equal(failureMessage({name: "NotAllowedError"}), null)
  assert.equal(failureMessage({name: "AbortError"}), null)
  assert.match(failureMessage({name: "InvalidStateError"}), /already on your account/)
  assert.match(failureMessage({name: "SecurityError"}), /https/)
  assert.equal(failureMessage(new Error("boom")), "boom")
  assert.equal(failureMessage(undefined), "The passkey didn't work.")
})

test("supported only with both PublicKeyCredential and navigator.credentials", () => {
  assert.equal(supported({PublicKeyCredential: function() {}, navigator: {credentials: {}}}), true)
  assert.equal(supported({navigator: {credentials: {}}}), false)
  assert.equal(supported({PublicKeyCredential: function() {}, navigator: {}}), false)
})

function fakeFetch(answers) {
  const calls = []
  const fetchFn = async (url, init) => {
    calls.push({url, init, body: JSON.parse(init.body)})
    const [status, json] = answers[url]
    return {ok: status < 400, json: async () => json}
  }
  return {calls, fetchFn}
}

function fakeForm() {
  const inputs = {}
  for (const key of ["id", "authenticatorData", "signature", "clientDataJSON", "userHandle"]) {
    inputs[`passkey[${key}]`] = {value: ""}
  }
  return {
    inputs, submitted: 0,
    querySelector(sel) { return inputs[sel.match(/name='(.+)'/)[1]] || null },
    submit() { this.submitted++ },
  }
}

const assertion = {
  rawId: bytes(9),
  response: {authenticatorData: bytes(1), signature: bytes(2), clientDataJSON: bytes(3), userHandle: bytes(7)},
}

test("signIn: options with the CSRF token, the authenticator, then the form", async () => {
  const {calls, fetchFn} = fakeFetch({"/login/passkey/options": [200, {publicKey: {challenge: "AQID", rpId: "x"}}]})
  let asked
  const credentials = {get: async options => { asked = options; return assertion }}
  const form = fakeForm()

  await signIn({form, credentials, fetchFn, csrf: "tok"})

  assert.equal(calls[0].init.method, "POST")
  assert.equal(calls[0].init.headers["x-csrf-token"], "tok")
  assert.deepEqual(view(asked.publicKey.challenge), [1, 2, 3])
  assert.equal(form.inputs["passkey[id]"].value, "CQ")
  assert.equal(form.inputs["passkey[signature]"].value, "Ag")
  assert.equal(form.inputs["passkey[userHandle]"].value, "Bw")
  assert.equal(form.submitted, 1)
})

test("signIn: a refused challenge, or a cancelled prompt, submits nothing", async () => {
  const form = fakeForm()
  const refused = fakeFetch({"/login/passkey/options": [500, {}]})
  await assert.rejects(signIn({form, credentials: {get: async () => assertion}, fetchFn: refused.fetchFn, csrf: ""}))

  const ok = fakeFetch({"/login/passkey/options": [200, {publicKey: {challenge: "AQ"}}]})
  const cancelled = Object.assign(new Error("no"), {name: "NotAllowedError"})
  await assert.rejects(
    signIn({form, credentials: {get: async () => { throw cancelled }}, fetchFn: ok.fetchFn, csrf: ""}),
    e => e.name === "NotAllowedError",
  )
  assert.equal(form.submitted, 0)
})

const created = {id: "abc", response: {attestationObject: bytes(1), clientDataJSON: bytes(2)}}

test("register: options, the authenticator, then the answer with the name", async () => {
  const {calls, fetchFn} = fakeFetch({
    "/account/passkeys/options": [200, {publicKey: {challenge: "AQ", user: {id: "Ag"}}}],
    "/account/passkeys": [201, {passkey: {id: 5, name: "Desk"}}],
  })
  let asked
  const credentials = {create: async options => { asked = options; return created }}

  const passkey = await register({name: "Desk", credentials, fetchFn, csrf: "tok"})

  assert.deepEqual(passkey, {id: 5, name: "Desk"})
  assert.deepEqual(view(asked.publicKey.user.id), [2])
  assert.deepEqual(calls[1].body, {id: "abc", attestationObject: "AQ", clientDataJSON: "Ag", name: "Desk"})
  assert.equal(calls[1].init.headers["x-csrf-token"], "tok")
})

test("register: the server's reason comes back as the error", async () => {
  const {fetchFn} = fakeFetch({
    "/account/passkeys/options": [200, {publicKey: {challenge: "AQ", user: {id: "Ag"}}}],
    "/account/passkeys": [422, {error: "That passkey is already on an account here."}],
  })
  await assert.rejects(
    register({name: "", credentials: {create: async () => created}, fetchFn, csrf: ""}),
    /already on an account here/,
  )

  const refused = fakeFetch({"/account/passkeys/options": [403, {}]})
  await assert.rejects(
    register({name: "", credentials: {create: async () => created}, fetchFn: refused.fetchFn, csrf: ""}),
    /didn't start/,
  )
})
