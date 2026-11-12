[Slipdock — the manual](../manual.md)

## Security notes

This is a self-hosted app that holds everything you are working on, and some of
these are decisions only you can make.

- **Sign-up is closed by default.** A server nobody has set up yet lets the
  first address in, which is how an instance gets claimed; after that
  registration follows whichever mode you chose — *closed* (accounts exist only
  because you made them), *allowlist* (named addresses and whole domains),
  *approval* (people ask, you say yes) or *open* (anybody), which is sensible
  only when the server is already behind a boundary of your own. The mode and
  the allowlist are editable in the app; `SLIPDOCK_SIGNUP_MODE` and
  `SLIPDOCK_SIGNUP_ALLOW` seed them on first boot.
- **Sign-in is passwordless and rate limited** — a one-time link valid for 15
  minutes, a session that lasts 30 days, five attempts an hour per address and
  twenty per IP, so nobody can use your server to mail strangers. A refused
  address is told exactly what an accepted one is told.
- **Responses carry a Content-Security-Policy** that allows script from this
  origin only — unless an admin turns on PostHog, which adds PostHog's script
  host and nothing else.
- **Administering the server needs its own token scope.** The admin pages
  (**Configuration** for registration and mail, **Users** for the people and the
  signup queue) are behind an admin account, and
  over HTTP it also needs a token deliberately made with the `admin` scope. API
  tokens live in agents and CI; an ordinary read/write one leaking should not be
  a key to who may register.
- **Agents get scoped tokens, not your account.** `slipdock auth` shows a code,
  you approve it in a browser you are already signed into, and the agent is
  given a token you can see and revoke. A token can be read-only, confined to
  named boards, and made to expire; Account › API tokens shows when each was last
  used and from where. A read-only token is refused anything that would change
  something, and a board-scoped one cannot even list boards outside its scope.
- **A machine running runners has a key of its own, not your token.**
  `slipdock-runner init` shows a code and the machine's fingerprint; you
  approve it at Account › Machines (`/account/machines/approve`), seeing its
  hostname, system and fingerprint, and choose the boards it may serve. Its
  machine key is bound to you, works nowhere an API token does, and stops at
  once when you revoke the machine. A one-time enrolment key (24 hours) does
  the same for a machine with nobody at its screen.
- **A machine takes data from the server, never a command.** The trust
  contract ([the manual's Machines page](machines.md#what-the-server-can-and-cannot-do),
  and `slipdock-runner show` on the machine) says what a server can make it
  do (queue jobs with prompts, set its runners' typed settings inside the
  machine's own ceiling, name a newer version), what it cannot (run a
  command, change a hook, read files, install an unsigned update), what each
  executor stops, and what nothing here bounds: first-install download
  trust, the hosted operator also being the signer, the network outside a
  container, and prompts being the board members' instructions within the
  runner's permission mode.
- **Agentic Login is an authentication bypass, by design**, and is *not* how to
  sign an agent in — [the device flow](accounts-and-sharing.md#signing-an-agent-in) is. With
  `SLIPDOCK_AGENTIC_LOGIN=true` the sign-in page will write a working link for
  *any* address to a file on the server, so a test running on that server can
  sign itself in. It is off unless you set it, and a server with it on says so
  in the log on every boot. Only ever enable it on a machine used for testing.
- **AI runs on each person's own key or endpoint**, kept in a `0600` JSON file
  outside the database. Somebody with neither gets no AI features at all, and
  no board content leaves the server on their behalf. Back that file up like a
  `.env`, because it holds secrets in the clear. Point it at a model server on
  your own network and board content never leaves the network either.
- **Outbound calls only go to public addresses.** Webhook callbacks and the
  AI endpoints people type for themselves are refused if they resolve to
  loopback, private, link-local, CGNAT (Tailscale) or other reserved
  addresses, are pinned to the address that was checked, and do not follow
  redirects — so a URL cannot turn the server into a probe of its own
  network. Admins' own endpoints and the server's default
  (`SLIPDOCK_AI_BASE_URL`) are trusted. To let everybody use a model server
  on the LAN, set `SLIPDOCK_EGRESS_ALLOW` to a comma-separated list of CIDRs,
  or to `all` to switch the check off.
- **Attachments are served with permission checks**, but they are whatever
  people upload: the app does not scan them.
- **Put TLS in front of it.** The Docker image does not force HTTPS, on the
  assumption that something in front terminates it; build with
  `--build-arg SLIPDOCK_FORCE_SSL=true` if the app itself should.
- **Back up the database** — the `slipdock-db` and `slipdock-data` volumes
  under Docker, or a `pg_dump` plus uploads and `ai_keys.json` from a
  checkout. There is no other copy.

To report a vulnerability, see [SECURITY.md](../../SECURITY.md); it also says what is
in scope and what is a deployment choice rather than a bug.

---

← [As a service](as-a-service.md) · [Contents](../manual.md) · [Licence](licence.md) →
