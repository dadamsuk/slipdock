// node --test cloudflare/inbound-email
import {test} from "node:test"
import assert from "node:assert/strict"
import {createHmac} from "node:crypto"
import {handle, isSlipdockAddress, localPart, sign} from "./worker.js"

const RAW = "From: a@example.com\r\nSubject: Hi\r\n\r\nBody é\r\n"
const env = {APP_URL: "https://app.example.com/", INBOUND_SECRET: "s3cret"}

function fakeMessage(to, raw = RAW) {
  const message = {
    to,
    from: "bounce@example.com",
    raw: new Blob([raw]).stream(),
    rejected: null,
    forwardedTo: null,
    setReject(reason) {
      message.rejected = reason
    },
    async forward(address) {
      message.forwardedTo = address
    },
  }
  return message
}

function fakeFetch(status, body = {}) {
  const calls = []
  const fetch = async (url, init) => {
    calls.push({url, init})
    return new Response(JSON.stringify(body), {status, headers: {"content-type": "application/json"}})
  }
  return {fetch, calls}
}

test("the address pattern", () => {
  assert.ok(isSlipdockAddress("card-abc123@example.com"))
  assert.ok(isSlipdockAddress("Reply-XYZ9@example.com"))
  assert.ok(isSlipdockAddress("add-tok+detail@example.com"))
  assert.equal(localPart("Page-A1+x@example.com"), "page-a1")
  assert.ok(!isSlipdockAddress("hello@example.com"))
  assert.ok(!isSlipdockAddress("card-@example.com"))
  assert.ok(!isSlipdockAddress("card-ab_c@example.com"))
  assert.ok(!isSlipdockAddress("xcard-abc@example.com"))
})

test("the signature is the one the app checks: hex HMAC-SHA256 of timestamp.body", async () => {
  const body = new TextEncoder().encode(RAW)
  const expected = createHmac("sha256", "s3cret").update(`1700000000.${RAW}`).digest("hex")
  assert.equal(await sign("s3cret", "1700000000", body), expected)
})

// The same pair is pinned in test/slipdock_web/controllers/api/inbound_controller_test.exs,
// so the Worker and the app can't drift apart.
test("a known message signs to the known value", async () => {
  assert.equal(
    await sign("s3cret", "1700000000", new TextEncoder().encode(RAW)),
    "715b15c9a88842253a77c748601654d98800b068ee04ca81d1be4dd7499e14e0",
  )
})

test("a Slipdock address is signed and posted raw, with the envelope", async () => {
  const {fetch, calls} = fakeFetch(202, {ok: true})
  const message = fakeMessage("card-abc@example.com")

  assert.equal(await handle(message, env, {fetch, now: () => 1_700_000_000_000}), "delivered")
  assert.equal(calls.length, 1)

  const {url, init} = calls[0]
  assert.equal(url, "https://app.example.com/api/inbound/email")
  assert.equal(init.method, "POST")
  assert.equal(init.headers["content-type"], "message/rfc822")
  assert.equal(init.headers["x-envelope-to"], "card-abc@example.com")
  assert.equal(init.headers["x-envelope-from"], "bounce@example.com")
  assert.equal(init.headers["x-slipdock-timestamp"], "1700000000")
  assert.equal(new TextDecoder().decode(init.body), RAW)
  assert.equal(
    init.headers["x-slipdock-signature"],
    createHmac("sha256", "s3cret").update(`1700000000.${RAW}`).digest("hex"),
  )
  assert.equal(message.rejected, null)
})

test("a 200 duplicate and a 202 drop are both delivered, never rejected", async () => {
  for (const status of [200, 202]) {
    const message = fakeMessage("card-abc@example.com")
    assert.equal(await handle(message, env, fakeFetch(status, {ok: true})), "delivered")
    assert.equal(message.rejected, null)
  }
})

test("a 4xx with a reason is a bounce with that reason", async () => {
  const message = fakeMessage("card-abc@example.com")
  const outcome = await handle(message, env, fakeFetch(422, {reject: "You can no longer add to this board."}))
  assert.equal(outcome, "rejected")
  assert.equal(message.rejected, "You can no longer add to this board.")
})

test("a 4xx without a reason still bounces, saying the status", async () => {
  const message = fakeMessage("card-abc@example.com")
  await handle(message, env, fakeFetch(413, {}))
  assert.match(message.rejected, /413/)
})

test("401, 404 and 5xx throw, so the sender retries rather than gets a bounce", async () => {
  for (const status of [401, 404, 500, 503]) {
    const message = fakeMessage("card-abc@example.com")
    await assert.rejects(handle(message, env, fakeFetch(status)), new RegExp(String(status)))
    assert.equal(message.rejected, null)
  }
})

test("a network error throws too", async () => {
  const fetch = async () => {
    throw new TypeError("fetch failed")
  }
  await assert.rejects(handle(fakeMessage("card-abc@example.com"), env, {fetch}), /fetch failed/)
})

test("another address is forwarded when FORWARD_TO is set, and the app is not called", async () => {
  const {fetch, calls} = fakeFetch(202)
  const message = fakeMessage("hello@example.com")
  assert.equal(await handle(message, {...env, FORWARD_TO: "me@example.com"}, {fetch}), "forwarded")
  assert.equal(message.forwardedTo, "me@example.com")
  assert.equal(calls.length, 0)
})

test("another address is rejected when there is nowhere to forward it", async () => {
  const {fetch, calls} = fakeFetch(202)
  const message = fakeMessage("hello@example.com")
  assert.equal(await handle(message, env, {fetch}), "rejected")
  assert.equal(message.rejected, "No such address here.")
  assert.equal(calls.length, 0)
})

test("missing settings throw instead of posting unsigned mail", async () => {
  const {fetch, calls} = fakeFetch(202)
  await assert.rejects(handle(fakeMessage("card-abc@example.com"), {APP_URL: "https://x.example.com"}, {fetch}))
  assert.equal(calls.length, 0)
})
