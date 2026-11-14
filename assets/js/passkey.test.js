// node --test assets/js — no browser: `credentials` and `fetch` are fakes
// that record what they were given, and the form is the two methods
// signIn() touches.
import {test} from "node:test"
import assert from "node:assert/strict"
import {
  toBase64url, fromBase64url, creationOptions, requestOptions, attestationJSON,
  assertionJSON, failureMessage, supported, signIn, register, PasskeyLogin, PasskeyRegister,
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
  await assert.rejects(
    signIn({form, credentials: {get: async () => assertion}, fetchFn: refused.fetchFn, csrf: ""}),
    /didn't start a passkey sign-in/,
  )

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

test("signIn: a fetch that rejects is passed on, and nothing is submitted", async () => {
  const form = fakeForm()
  let asked = 0
  const credentials = {get: async () => { asked++; return assertion }}
  const fetchFn = async () => { throw new TypeError("Failed to fetch") }

  await assert.rejects(signIn({form, credentials, fetchFn, csrf: ""}), /Failed to fetch/)
  assert.equal(asked, 0)
  assert.equal(form.submitted, 0)
})

// The hooks reach for the browser's globals: `navigator.credentials`,
// `fetch`, `PublicKeyCredential` and the CSRF meta tag on `document`. Each
// hook test swaps fakes in for them and puts the originals back.
async function withBrowser({credentials, fetchFn}, body) {
  const saved = {
    navigator: Object.getOwnPropertyDescriptor(globalThis, "navigator"),
    fetch: globalThis.fetch, PKC: globalThis.PublicKeyCredential, document: globalThis.document,
  }
  Object.defineProperty(globalThis, "navigator", {value: {credentials}, configurable: true, writable: true})
  globalThis.fetch = fetchFn
  globalThis.PublicKeyCredential = function() {}
  globalThis.document = {querySelector: () => ({getAttribute: () => "tok"})}
  try {
    await body()
  } finally {
    Object.defineProperty(globalThis, "navigator", saved.navigator)
    globalThis.fetch = saved.fetch
    if (saved.PKC === undefined) delete globalThis.PublicKeyCredential
    else globalThis.PublicKeyCredential = saved.PKC
    globalThis.document = saved.document
  }
}

// An element the hook listens on: it keeps its listeners so a test can fire
// one with a fake event. `found` is what its querySelector answers.
function fakeEl(found = {}) {
  const listeners = {}
  return {
    listeners,
    addEventListener(type, fn) { listeners[type] = fn },
    querySelector(sel) { return found[sel] || null },
  }
}

// A hook as LiveView mounts it, with its pushes recorded. `start` is wrapped
// so the test can await the run a click or a submit set off.
function mountHook(hook, el) {
  const pushed = []
  const h = Object.create(hook)
  h.el = el
  h.pushEvent = (event, payload) => pushed.push({event, payload})
  h.pushEventTo = (target, event, payload) => pushed.push({target, event, payload})
  h.runs = []
  h.start = function(...args) {
    const run = hook.start.apply(this, args)
    this.runs.push(run)
    return run
  }
  h.mounted()
  return {h, pushed}
}

const notAllowed = () => Object.assign(new Error("The operation was cancelled."), {name: "NotAllowedError"})

function loginHook() {
  const form = fakeForm()
  const button = {disabled: false, closest: sel => (sel === "[data-passkey-start]" ? button : null)}
  const el = fakeEl({form})
  return {form, button, el}
}

test("PasskeyLogin: says on mounting whether passkeys work here", async () => {
  await withBrowser({credentials: {}, fetchFn: async () => {}}, async () => {
    const {pushed} = mountHook(PasskeyLogin, fakeEl())
    assert.deepEqual(pushed, [{event: "passkey_support", payload: {supported: true}}])
  })
})

test("PasskeyLogin: a click elsewhere starts nothing", async () => {
  let fetched = 0
  await withBrowser({credentials: {}, fetchFn: async () => { fetched++ }}, async () => {
    const {h} = mountHook(PasskeyLogin, fakeEl())
    h.el.listeners.click({target: {closest: () => null}})
    assert.equal(h.runs.length, 0)
    assert.equal(fetched, 0)
  })
})

test("PasskeyLogin: success submits the form and leaves the button disabled", async () => {
  const {fetchFn, calls} = fakeFetch({"/login/passkey/options": [200, {publicKey: {challenge: "AQ"}}]})
  await withBrowser({credentials: {get: async () => assertion}, fetchFn}, async () => {
    const {form, button, el} = loginHook()
    const {h, pushed} = mountHook(PasskeyLogin, el)
    el.listeners.click({target: button})
    assert.equal(button.disabled, true)
    await h.runs[0]
    assert.equal(calls[0].init.headers["x-csrf-token"], "tok")
    assert.equal(form.submitted, 1)
    assert.equal(form.inputs["passkey[id]"].value, "CQ")
    // The page is leaving for the redirect: a second press would only race it.
    assert.equal(button.disabled, true)
    assert.deepEqual(pushed.map(p => p.event), ["passkey_support"])
  })
})

test("PasskeyLogin: a failure enables the button again and pushes passkey_failed", async () => {
  const fetchFn = async () => { throw new TypeError("Failed to fetch") }
  await withBrowser({credentials: {get: async () => assertion}, fetchFn}, async () => {
    const {form, button, el} = loginHook()
    const {h, pushed} = mountHook(PasskeyLogin, el)
    el.listeners.click({target: button})
    assert.equal(button.disabled, true)
    await h.runs[0]
    assert.equal(button.disabled, false)
    assert.equal(form.submitted, 0)
    assert.deepEqual(pushed.slice(1), [{event: "passkey_failed", payload: {message: "Failed to fetch"}}])
  })
})

test("PasskeyLogin: a cancel enables the button again and pushes nothing", async () => {
  const {fetchFn} = fakeFetch({"/login/passkey/options": [200, {publicKey: {challenge: "AQ"}}]})
  await withBrowser({credentials: {get: async () => { throw notAllowed() }}, fetchFn}, async () => {
    const {form, button, el} = loginHook()
    const {h, pushed} = mountHook(PasskeyLogin, el)
    el.listeners.click({target: button})
    await h.runs[0]
    assert.equal(button.disabled, false)
    assert.equal(form.submitted, 0)
    assert.deepEqual(pushed.map(p => p.event), ["passkey_support"])
  })
})

// The account page's form: a submit button and the name input.
function addForm({add = true, name = "Desk"} = {}) {
  const button = {disabled: false}
  const input = {value: name}
  const found = {"button[type='submit']": button, "input[name='name']": input}
  const form = {
    button, input, prevented: 0,
    matches: sel => add && sel === "[data-passkey-add]",
    querySelector: sel => found[sel] || null,
  }
  return form
}

function submit(el, form) {
  const event = {target: form, preventDefault() { form.prevented++ }}
  el.listeners.submit(event)
}

const registerAnswers = saved => ({
  "/account/passkeys/options": [200, {publicKey: {challenge: "AQ", user: {id: "Ag"}}}],
  "/account/passkeys": saved,
})

test("PasskeyRegister: says on mounting, to itself, whether passkeys work here", async () => {
  await withBrowser({credentials: {}, fetchFn: async () => {}}, async () => {
    const el = fakeEl()
    const {pushed} = mountHook(PasskeyRegister, el)
    assert.deepEqual(pushed, [{target: el, event: "passkey_support", payload: {supported: true}}])
  })
})

test("PasskeyRegister: a submit from another form is ignored", async () => {
  let fetched = 0
  await withBrowser({credentials: {create: async () => created}, fetchFn: async () => { fetched++ }}, async () => {
    const el = fakeEl()
    const {h, pushed} = mountHook(PasskeyRegister, el)
    const other = addForm({add: false})
    submit(el, other)
    assert.equal(other.prevented, 0)
    assert.equal(h.runs.length, 0)
    assert.equal(fetched, 0)
    assert.equal(other.button.disabled, false)
    assert.deepEqual(pushed.map(p => p.event), ["passkey_support"])
  })
})

test("PasskeyRegister: success clears the name, pushes passkey_added and enables the button", async () => {
  const {fetchFn, calls} = fakeFetch(registerAnswers([201, {passkey: {id: 5, name: "Desk"}}]))
  await withBrowser({credentials: {create: async () => created}, fetchFn}, async () => {
    const el = fakeEl()
    const {h, pushed} = mountHook(PasskeyRegister, el)
    const form = addForm({name: "Desk"})
    submit(el, form)
    assert.equal(form.prevented, 1)
    assert.equal(form.button.disabled, true)
    await h.runs[0]
    assert.equal(calls[1].body.name, "Desk")
    assert.equal(calls[1].init.headers["x-csrf-token"], "tok")
    assert.equal(form.input.value, "")
    assert.equal(form.button.disabled, false)
    assert.deepEqual(pushed.slice(1), [{target: el, event: "passkey_added", payload: {name: "Desk"}}])
  })
})

test("PasskeyRegister: a failure keeps the name, enables the button and pushes passkey_failed", async () => {
  const {fetchFn} = fakeFetch(registerAnswers([422, {error: "That passkey is already on an account here."}]))
  await withBrowser({credentials: {create: async () => created}, fetchFn}, async () => {
    const el = fakeEl()
    const {h, pushed} = mountHook(PasskeyRegister, el)
    const form = addForm({name: "Desk"})
    submit(el, form)
    await h.runs[0]
    assert.equal(form.input.value, "Desk")
    assert.equal(form.button.disabled, false)
    assert.deepEqual(pushed.slice(1), [
      {target: el, event: "passkey_failed", payload: {message: "That passkey is already on an account here."}},
    ])
  })
})

test("PasskeyRegister: a cancel enables the button and pushes nothing", async () => {
  const {fetchFn, calls} = fakeFetch(registerAnswers([201, {passkey: {id: 5, name: "Desk"}}]))
  await withBrowser({credentials: {create: async () => { throw notAllowed() }}, fetchFn}, async () => {
    const el = fakeEl()
    const {h, pushed} = mountHook(PasskeyRegister, el)
    const form = addForm({name: "Desk"})
    submit(el, form)
    await h.runs[0]
    assert.equal(calls.length, 1)
    assert.equal(form.input.value, "Desk")
    assert.equal(form.button.disabled, false)
    assert.deepEqual(pushed.map(p => p.event), ["passkey_support"])
  })
})
