// Slipdock's Cloudflare Email Worker (#1241, design W-1933).
//
// Email Routing hands every message for the inbound domain to `email()`. The
// Worker does as little as it can: it checks the address against the pattern,
// signs the raw message and posts it to the app, then turns the app's answer
// into the SMTP outcome. It never parses MIME, which keeps it far inside the
// Free plan's 10 ms of CPU.
//
//   2xx       delivered (or ignored on purpose: automatic mail)
//   4xx       setReject(reason): the sender gets a bounce saying why
//   401, 404  thrown: a configuration problem (wrong secret, inbound mail off),
//             so a temporary failure the sending server retries, not a bounce
//   5xx, network error   thrown, the same: try again later
//
// Settings (wrangler.toml and `wrangler secret put`):
//   APP_URL         where the app is, e.g. https://app.slipdock.us
//   INBOUND_SECRET  the app's SLIPDOCK_INBOUND_SECRET (a secret, never in git)
//   FORWARD_TO      optional: where mail for any other address goes, when the
//                   catch-all is on the main domain. A verified destination.

const LOCAL_PART = /^(card|page|add|reply)-[a-z0-9]+$/

// The local part, lower-cased, without a +detail.
export function localPart(address) {
  return String(address).split("@")[0].split("+")[0].toLowerCase()
}

export function isSlipdockAddress(address) {
  return LOCAL_PART.test(localPart(address))
}

const hex = (buffer) =>
  [...new Uint8Array(buffer)].map((b) => b.toString(16).padStart(2, "0")).join("")

// Hex HMAC-SHA256 of "<timestamp>.<body>", the app's
// SlipdockWeb.API.InboundController.sign/3.
export async function sign(secret, timestamp, body) {
  const encoder = new TextEncoder()
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(secret),
    {name: "HMAC", hash: "SHA-256"},
    false,
    ["sign"],
  )
  const prefix = encoder.encode(`${timestamp}.`)
  const data = new Uint8Array(prefix.length + body.length)
  data.set(prefix, 0)
  data.set(body, prefix.length)
  return hex(await crypto.subtle.sign("HMAC", key, data))
}

// What happened, for the Worker's logs and the tests: "delivered",
// "forwarded" or "rejected". Throws when the message should be retried.
export async function handle(message, env, {fetch: fetchImpl = fetch, now = Date.now} = {}) {
  if (!isSlipdockAddress(message.to)) {
    if (env.FORWARD_TO) {
      await message.forward(env.FORWARD_TO)
      return "forwarded"
    }
    message.setReject("No such address here.")
    return "rejected"
  }

  if (!env.APP_URL || !env.INBOUND_SECRET) {
    throw new Error("APP_URL and INBOUND_SECRET must both be set")
  }

  // Read once: the signature covers exactly these bytes.
  const body = new Uint8Array(await new Response(message.raw).arrayBuffer())
  const timestamp = String(Math.floor(now() / 1000))
  const signature = await sign(env.INBOUND_SECRET, timestamp, body)

  const response = await fetchImpl(`${env.APP_URL.replace(/\/+$/, "")}/api/inbound/email`, {
    method: "POST",
    headers: {
      "content-type": "message/rfc822",
      "x-slipdock-timestamp": timestamp,
      "x-slipdock-signature": signature,
      "x-envelope-to": message.to,
      "x-envelope-from": message.from,
    },
    body,
  })

  if (response.ok) return "delivered"

  if (response.status === 401 || response.status === 404 || response.status >= 500) {
    throw new Error(`Slipdock answered ${response.status}; the sender will retry`)
  }

  const answer = await response.json().catch(() => ({}))
  message.setReject(answer.reject || `Slipdock refused this message (${response.status}).`)
  return "rejected"
}

export default {
  async email(message, env) {
    const outcome = await handle(message, env)
    console.log(`${outcome}: ${message.to}`)
  },
}
