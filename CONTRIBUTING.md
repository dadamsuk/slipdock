# Contributing

Thanks for looking. This is a self-hosted kanban and wiki built in Phoenix
LiveView; the README explains what it does, `docs/manual.md` is the full
reference, and this file explains how to work on it.

## Getting it running

You need Elixir 1.17 or newer on Erlang/OTP 27 and a Postgres; the asset
pipeline installs its own Tailwind and esbuild. `compose.dev.yaml` runs a
Postgres for development and tests if you would rather not install one.

```sh
docker compose -f compose.dev.yaml up -d   # Postgres on 127.0.0.1:5434
mix setup          # deps, database, seeds, Tailwind and esbuild
mix phx.server     # then open the address it prints
```

`mix setup` seeds two sample boards, so there is something to look at. In
development the server binds to this machine's Tailscale address if it has one;
`KANBAN_BIND_IP=127.0.0.1` keeps it on loopback and `PORT` moves the port.

Sign-in is by emailed magic link, and in development no mail leaves the
machine: the link is written to the log and the message is kept in the
in-memory mailbox at `/dev/mailbox`. Enter any address on the sign-in page and
follow the link from either. (Development also enables **Agentic Login**, which
writes that link to a file in `/tmp` so a script can sign itself in. It is an
authentication bypass — see `SECURITY.md` — so never carry that setting over to
a server anyone else can reach.)

The AI features (chat and edits, the narrative, deep search, rules written in
English) need an OpenRouter key per account, set under **Account → AI key**.
Everything else works without one.

If you would rather not install Elixir at all, `docker compose up -d` builds and
runs the whole thing (see the README) — but the test suite and the formatter
want a local toolchain, so development really wants `mix`.

## Before you open a pull request

```sh
mix precommit      # compile with warnings as errors, prune deps, format, test
```

That is the gate. Please make it pass rather than explaining why it does not —
there is no CI to catch it for you. The whole suite takes a little over a
minute, so run it often.

Tests live in `test/slipdock` for the domain and `test/slipdock_web` for anything
with a browser in it; LiveView tests drive the real page. Calls to a language
model are answered by a stub (`test/support/ai_stub.ex`), so no test spends
money or needs a key.

`mix test --cover` prints line coverage for `lib/`, worst module first, with a
page per module in `cover/`, and fails under 65%. It runs through
`test/support/coverage.ex` rather than Mix's own tool: `:cover` on this
Elixir and OTP cannot instrument some uses of `x in [...]` outside a guard, and Mix's tool dies on the first one. So outside a guard write
`Enum.member?([...], x)` instead (it is the same test); in a guard, `in` is
fine. A module that slips through is named at the end of the report as not
measured, not counted as covered. Every module in `lib/` is measured today.

### async: true unless something is genuinely shared

Postgres' sandbox gives every test its own connection inside its own
transaction, so **new tests should be `async: true`**. Around a third are not,
and each of those shares something the database cannot roll back:

- **`Application.put_env` / `System.put_env`** — one env for the whole node.
- **Anything writing `Slipdock.Settings`** — the row is cached in
  `:persistent_term`, which is shared between processes, so one test's
  uncommitted settings would be read by another.
- **`AIStub.share/0`** — it calls `Req.Test.set_req_test_to_shared()`, which
  makes the stub global. A test needs it when the code under test runs in
  another process (any LiveView), and two such tests at once would overwrite
  each other's scripted answers. The stub is per-process without it, so a test
  that only calls the model in its own process can stay async.
- **`Slipdock.Search.Indexer`** — one queue for the whole node. Sandbox setup
  empties it before each test (`Indexer.reset/0`), which is enough to keep
  tests independent but not enough to let two assert on it at once.
- **The uploads directory** — five files `File.rm_rf!` it in setup, and it is
  one real directory on disk.

Do not flip one of those to `async: true` without removing the sharing first.
The win is correctness, not speed: on an 8-core machine the whole suite is
CPU-bound and running it in parallel is only a few per cent quicker.

## What good work looks like here

- **Conventions are in `AGENTS.md`** — Phoenix 1.8 and LiveView idioms, the
  `<Layouts.app>` wrapper every template begins with, `<.icon>` and `<.input>`
  rather than hand-rolled markup, Tailwind v4 without a config file, `Req` for
  HTTP. Read it before writing a component.
- **Say why, not what.** The codebase explains reasoning in moduledocs and in
  comments next to the surprising line, and leaves the obvious unremarked.
  Match that: a comment that restates the code is noise, one that records the
  constraint you discovered is the valuable part.
- **One concern per pull request**, with a message that says what changed and
  why. Fixes to a bug should come with the test that would have caught it.
- **Keep the three faces in step.** Most features exist in the web UI, in the
  JSON API (`/api`), and in the `slipdock` CLI under `cli/`, and the agent guide
  at `/api/guide` documents the API for automated callers. If you add
  something people would reach for from a script, add it in all of them, or say
  in the pull request why it belongs in only one.
- **Migrations are forward-only** and should be safe to run against an
  existing database with data in it.

## Licence

The project is AGPL-3.0 (see `LICENSE`). By opening a pull request you are
offering your contribution under that licence, and if you run a modified copy
as a service you owe its users your changes — so keep `KANBAN_SOURCE_URL`
pointing at a repository they can actually reach.

## Reporting things

Bugs and feature ideas: open an issue, and say what you expected to happen.
Security problems: do **not** open an issue — see `SECURITY.md`.
