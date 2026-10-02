# Security

## Reporting a vulnerability

Use GitHub's private vulnerability reporting: the **Security** tab of this
repository → **Report a vulnerability**. It opens a private thread with the
maintainer, so nothing is public while a fix is being written. Please do not
open a public issue for a vulnerability first.

Tell us what you found, how to reproduce it, and what an attacker gets out of
it. A proof of concept against your own instance is welcome; please do not
test against anybody else's.

This is a small self-hosted project maintained in spare time, so expect a
first reply in days rather than hours. There is no bounty programme.

## What is in scope

The application as it ships: authentication and sessions, the permission model
(boards, saved views, wiki pages, attachments), the JSON API, the automation
rules, the wiki renderer, and anything that lets one account read or change
what belongs to another.

Out of scope, because they are deployment choices rather than bugs:

- **Agentic Login** (`KANBAN_AGENTIC_LOGIN`). It writes a working sign-in link
  for *any* address to a file on the server, by design, so that an automated
  test can sign itself in. It is an authentication bypass for anyone who can
  reach the sign-in page or read that directory. It is off unless you set the
  variable, and a server with it on says so in the log on every boot. Never
  enable it on anything reachable from the internet.
- **The sign-in fallback.** When no mail server is configured, sign-in codes
  are written to a file on the server (`SLIPDOCK_LOGIN_FALLBACK_PATH`, mode
  `0600`) and to the log. Anyone who can read either can sign in as anybody.
  That is a deliberate trade: without it a fresh install with no mail has no
  way in at all, and on a machine only you can reach the log is already yours.
  It turns itself off once mail works, an admin can turn it off explicitly,
  and `SLIPDOCK_LOGIN_FALLBACK=false` forbids it for good in a way the
  application cannot undo — **set that on anything other people can reach.**
- **Deliberately opening sign-up.** Registration follows the mode an admin
  chose: *closed* (accounts exist only because somebody made them),
  *allowlist*, *approval*, or *open*. If you choose *open*, anyone who can
  reach the page gets an account — that is the setting doing what it says, not
  a vulnerability. A new account still sees only its own boards, and where
  `user_directory` is `shared_only` it cannot see that anybody else exists.
- Anything that needs filesystem or shell access to the server, which already
  implies full control of the instance.
- Reports that a hardening header could be stricter, with no concrete
  injection path shown. The policy allows `'unsafe-inline'` for *styles*
  knowingly: components and wiki content carry style attributes, and inline
  style cannot run script.

## What the app does to protect you

So you know what to expect, and what to look at twice:

- **Sign-in** is passwordless. A magic link is good for 15 minutes, works
  once, and its token is stored only as a SHA-256 hash. Browser sessions last
  30 days. API tokens are random 32-byte values, also stored hashed, shown to
  you exactly once, and revocable per token under Account.
- **Authorisation** is one module (`Slipdock.Access`), consulted by every read
  and write path: the board and its lists, cards, saved views, wiki pages,
  exports, and the files attached to any of them.
- **Uploads** live outside the static root and are served by a controller that
  checks your access to whatever the file hangs off. Names on disk are
  server-generated UUIDs with a whitelisted extension, so an upload cannot
  write outside its directory. Every response carries
  `x-content-type-options: nosniff`, and only PNG, JPEG, GIF and WebP are
  shown inline — an uploaded SVG or HTML file is always a download, so it
  cannot run as script in the app's origin.
- **Wiki Markdown** is parsed, rendered and then sanitised (ammonia, via
  MDEx): `<script>`, event handlers and `javascript:` URLs do not survive,
  whoever wrote them.
- **Published links** (`/p/:token`, `/w/:token`) are 144 bits of randomness
  and can be unpublished at any time. They are the one way to let somebody
  read something without an account, so treat the URL as the secret it is.
- **Secrets.** `SECRET_KEY_BASE` is required in production and the app refuses
  to boot without it. Per-person OpenRouter keys are kept in a `0600` JSON
  file outside the database (`Slipdock.AI.Keys`) and are never sent back to the
  browser or the API — only a masked form. Back that file up as carefully as
  you would a `.env`, and keep both out of git.
- **Sign-up and flooding.** The sign-in form is gated (above) and rate limited
  — five attempts an hour per address, twenty per source IP — so it cannot be
  used to mail strangers or to script accounts. A refused address gets exactly
  the same answer as an accepted one, so the form does not reveal who has an
  account here.
- **Transport and headers.** The production config forces HTTPS with HSTS, and
  every browser response carries a Content-Security-Policy allowing script from
  this origin only, with no inline script anywhere in the app. The default
  development server binds to a Tailscale address, not to every interface.

## Supported versions

The tip of `master` is what gets fixed. There are no release branches yet.
