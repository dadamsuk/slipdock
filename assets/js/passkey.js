// Passkeys (#828): the browser's half of WebAuthn.
//
// The server speaks JSON, where every binary is unpadded base64url; the
// browser's `navigator.credentials` speaks ArrayBuffers. This file turns one
// into the other in both directions, and holds the two hooks that run the
// ceremonies:
//
// - `PasskeyLogin` on the sign-in page's button. It asks the server for a
//   challenge, lets the authenticator pick the account, and posts the answer
//   as an ordinary form, so signing in ends in the same redirect a magic link
//   does (a LiveView cannot set the session cookie).
// - `PasskeyRegister` on the account page's form. Same shape, but the answer
//   is posted with fetch and the outcome is pushed to the LiveView, which
//   shows the new passkey or says what went wrong.
//
// Where the browser has no WebAuthn there are no passkey controls at all: a
// button that can only fail is worse than no button.

export function toBase64url(buffer) {
  const bytes = new Uint8Array(buffer)
  let binary = ""
  for (const b of bytes) binary += String.fromCharCode(b)
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")
}

export function fromBase64url(string) {
  const base64 = string.replace(/-/g, "+").replace(/_/g, "/")
  const padded = base64 + "=".repeat((4 - (base64.length % 4)) % 4)
  const binary = atob(padded)
  const bytes = new Uint8Array(binary.length)
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i)
  return bytes.buffer
}

// The server's options for `credentials.create()`, with the binaries decoded.
export function creationOptions(publicKey) {
  return {
    ...publicKey,
    challenge: fromBase64url(publicKey.challenge),
    user: {...publicKey.user, id: fromBase64url(publicKey.user.id)},
    excludeCredentials: (publicKey.excludeCredentials || []).map(c => ({
      ...c,
      id: fromBase64url(c.id),
    })),
  }
}

// The server's options for `credentials.get()`, likewise.
export function requestOptions(publicKey) {
  const options = {...publicKey, challenge: fromBase64url(publicKey.challenge)}
  if (publicKey.allowCredentials) {
    options.allowCredentials = publicKey.allowCredentials.map(c => ({
      ...c,
      id: fromBase64url(c.id),
    }))
  }
  return options
}

// What a new credential sends back: the attestation and the client data.
export function attestationJSON(credential) {
  return {
    id: credential.id,
    attestationObject: toBase64url(credential.response.attestationObject),
    clientDataJSON: toBase64url(credential.response.clientDataJSON),
  }
}

// What a sign-in sends back. `userHandle` is null from a credential that is
// not discoverable, and then it is left out.
export function assertionJSON(credential) {
  const r = credential.response
  const json = {
    id: toBase64url(credential.rawId),
    authenticatorData: toBase64url(r.authenticatorData),
    signature: toBase64url(r.signature),
    clientDataJSON: toBase64url(r.clientDataJSON),
  }
  if (r.userHandle && r.userHandle.byteLength > 0) json.userHandle = toBase64url(r.userHandle)
  return json
}

// What to tell the person when the browser refuses. Cancelling is not an
// error worth a red box, so it comes back as null.
export function failureMessage(error) {
  switch (error && error.name) {
    case "NotAllowedError":
    case "AbortError":
      return null
    case "InvalidStateError":
      return "That passkey is already on your account."
    case "SecurityError":
      return "Passkeys only work over https, on the address this server is set up for."
    default:
      return (error && error.message) || "The passkey didn't work."
  }
}

export function supported(win = globalThis) {
  return !!(win.PublicKeyCredential && win.navigator && win.navigator.credentials)
}

function csrfToken(doc = globalThis.document) {
  const meta = doc && doc.querySelector("meta[name='csrf-token']")
  return meta ? meta.getAttribute("content") : ""
}

async function postJSON(fetchFn, url, body, csrf) {
  const response = await fetchFn(url, {
    method: "POST",
    headers: {"content-type": "application/json", "x-csrf-token": csrf},
    credentials: "same-origin",
    body: JSON.stringify(body || {}),
  })
  const json = await response.json().catch(() => ({}))
  return {ok: response.ok, json}
}

// Signing in: challenge, authenticator, then the form. `form` is the hidden
// form the button sits beside; its `passkey[...]` inputs take the answer.
export async function signIn({form, credentials, fetchFn, csrf}) {
  const {ok, json} = await postJSON(fetchFn, "/login/passkey/options", {}, csrf)
  if (!ok) throw new Error("The server didn't start a passkey sign-in.")

  const credential = await credentials.get({publicKey: requestOptions(json.publicKey)})
  const answer = assertionJSON(credential)

  for (const [key, value] of Object.entries(answer)) {
    const input = form.querySelector(`input[name='passkey[${key}]']`)
    if (input) input.value = value
  }
  form.submit()
}

// Adding one: challenge, authenticator, then the answer with the name.
// Resolves to the new passkey, or throws with the server's reason.
export async function register({name, credentials, fetchFn, csrf}) {
  const options = await postJSON(fetchFn, "/account/passkeys/options", {}, csrf)
  if (!options.ok) throw new Error("The server didn't start adding a passkey.")

  const credential = await credentials.create({publicKey: creationOptions(options.json.publicKey)})
  const saved = await postJSON(fetchFn, "/account/passkeys", {...attestationJSON(credential), name}, csrf)
  if (!saved.ok) throw new Error(saved.json.error || "The passkey wasn't added.")
  return saved.json.passkey
}

// Both hooks sit on an element the LiveView always renders and tell it, on
// mounting, whether this browser can do passkeys; the LiveView draws the
// controls only when it can. (Hiding them from here would not last: the next
// patch puts back whatever the server rendered.) Clicks and submits are
// caught on the hook's element, so they survive the controls being redrawn.

export const PasskeyLogin = {
  mounted() {
    this.pushEvent("passkey_support", {supported: supported()})
    this.el.addEventListener("click", e => {
      const button = e.target.closest("[data-passkey-start]")
      if (button) this.start(button)
    })
  },
  async start(button) {
    button.disabled = true
    try {
      await signIn({
        form: this.el.querySelector("form"),
        credentials: navigator.credentials,
        fetchFn: fetch,
        csrf: csrfToken(),
      })
    } catch (error) {
      button.disabled = false
      const message = failureMessage(error)
      if (message) this.pushEvent("passkey_failed", {message})
    }
  },
}

export const PasskeyRegister = {
  mounted() {
    this.pushEventTo(this.el, "passkey_support", {supported: supported()})
    this.el.addEventListener("submit", e => {
      if (!e.target.matches("[data-passkey-add]")) return
      e.preventDefault()
      this.start(e.target)
    })
  },
  async start(form) {
    const button = form.querySelector("button[type='submit']")
    const input = form.querySelector("input[name='name']")
    button.disabled = true
    try {
      const passkey = await register({
        name: input ? input.value : "",
        credentials: navigator.credentials,
        fetchFn: fetch,
        csrf: csrfToken(),
      })
      if (input) input.value = ""
      this.pushEventTo(this.el, "passkey_added", {name: passkey.name})
    } catch (error) {
      const message = failureMessage(error)
      if (message) this.pushEventTo(this.el, "passkey_failed", {message})
    } finally {
      button.disabled = false
    }
  },
}
