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
mix pre_push       # CI's static checks and build, in CI's order
mix test --stale   # the tests that depend on what you changed
```

That is the gate. Please make it pass rather than explaining why it does not.
`mix pre_push` compiles with warnings as errors, checks the formatting (the
CLI's too), runs the daemon's Go checks, the dependency and security audits,
credo, and the tests that hold the repo's own files and docs to a rule. A pull
request's CI (`.github/workflows/ci.yml`) runs no static checks (they run on
`main` and the release), so this is where a change meets them first. It runs
the whole suite, split four ways across runners, when the change touches the
app; a change to docs, skills, `*.md`, `cli/` or `daemon/` alone runs the
repo checks in its place, beside the cli or daemon job. The whole suite takes about two minutes locally.

The CLI (`cli/`) is a Mix project of its own with its own suite, whose tests
`mix pre_push` does not run: `cd cli && mix test`. CI runs those in a
separate `cli` job, with PowerShell installed so the Windows service tests
run rather than skip.

### More about `mix pre_push`

- **What it needs.** The daemon's checks run `go`, so it needs Go 1.24 on the
  PATH (or Go 1.21 or later, which fetches the 1.24 toolchain `daemon/go.mod`
  asks for).
- **What it runs**, in CI's order and stopping at the first failure: a forced
  compile with warnings as errors, the format checks (the app's, then the
  CLI's, with its compile), `go vet` and `go test -race` in `daemon/`, the
  repo checks in `test/repo_checks.txt`, `hex.audit`, `deps.audit`,
  `sobelow`, and `credo diff` against where the branch left `origin/main`.
  Its steps are in `mix.exs` (`pre_push_steps/1`), not a task under
  `lib/mix/tasks/`.
- **How long it takes.** About 4 minutes, over half of it the daemon's tests
  under the race detector. Start it beside the few test files you changed,
  not a whole directory: beside a run of all of `test/slipdock_web/live` it
  has timed out. A timeout there passes when run again by itself.
- **The repo checks** are the tests that hold the repository's own files,
  docs and skills to a rule, which a change elsewhere can break. A new test of
  that kind goes on `test/repo_checks.txt`, or
  `test/slipdock/repo_checks_test.exs` fails.
- **It runs beside `mix test`.** It builds in `_build/pre_push` and tests in a
  database of its own, one per checkout (named from a hash of the checkout's
  path), which it drops and remakes each run. Removed worktrees leave theirs
  behind: `mix pre_push --prune` drops those and runs no checks.
- **For a commit already merged**, give credo a base:
  `mix pre_push --from-git-ref <ref>`.
- **Skipping the first dependency compile.** Copy the test build in, then
  mend the dependencies' relative links, which the copy leaves one level
  short (this `find` works with both GNU and macOS's BSD `find`):

  ```sh
  mkdir -p _build/pre_push && cp -r _build/test _build/pre_push/
  find _build/pre_push -type l -path '*/lib/*' ! -exec test -e {} \; \
    -exec sh -c 'ln -sfn "../$(readlink "$1")" "$1"' _ {} \;
  ```
- **Two things that trip people up.** `mix format` doesn't always settle in
  one pass, so run the check even after formatting. And a function already
  over credo's complexity limit takes a new branch through a helper, never
  inline, since `credo diff` reports any change to its score.

Tests live in `test/slipdock` for the domain and `test/slipdock_web` for anything
with a browser in it; LiveView tests drive the real page. Calls to a language
model are answered by a stub (`test/support/ai_stub.ex`), so no test spends
money or needs a key.

Browser scripts with logic of their own keep it in a module beside `app.js`
and test it with Node's built-in runner — no packages, no browser:
`node --test 'assets/js/**/*.test.js'` (Node 22 or later). The confirm dialog
(`assets/js/confirm.js`) is the example to copy.

A flow LiveView tests can't reach — a drag in the wiki's tree, say — gets an
end-to-end script under `tools/e2e/`: a throwaway database, a server of its
own, and Playwright driving Chromium (`NODE_PATH` pointing at a
`playwright-core` install, `CHROME_PATH` at the browser). Run one with
`tools/e2e/folder-move-drag.sh`, `tools/e2e/tree-drag.sh`, `tools/e2e/tree-preview.sh`,
`tools/e2e/file-viewer.sh` or `tools/e2e/vault-view.sh`; each says `ok` or why not, and drops its
database on the way out. `tools/e2e/lib.sh` is the shared set-up for a new
one.

New or changed code comes with tests for it, in the same commit: the paths
you added, error and edge cases included, with assertions on what happens
rather than tests that only run the lines. A change that cannot be tested (a
deploy script, say) says why in its commit message. A refactor that changes no
behaviour is covered by the tests already there.

`mix test --cover` prints line coverage for `lib/`, worst module first, with a
page per module in `cover/`, and fails under the threshold in `mix.exs` (71%).
CI holds the whole suite to it: each partition exports its share (`mix test
--cover --export-coverage NAME`), and `mix slipdock.coverage` merges the
exports and fails below the threshold. It runs through
`test/support/coverage.ex` rather than Mix's own tool: `:cover` on this
Elixir and OTP cannot instrument some uses of `x in [...]` outside a guard, and Mix's tool dies on the first one. So outside a guard write
`Enum.member?([...], x)` instead (it is the same test); in a guard, `in` is
fine. A module that slips through is named at the end of the report as not
measured, not counted as covered.

### async: true unless something is genuinely shared

Postgres' sandbox gives every test its own connection inside its own
transaction, so **new tests should be `async: true`**. Around a third are not,
and each of those shares something the database cannot roll back:

- **`Application.put_env` / `System.put_env`** — one env for the whole node.
  For the app's own config there is no need: read it with
  `Slipdock.Config.get/2`, and in the test call
  `Slipdock.TestConfig.put/2` or `merge/2`, which change it for that test and
  the processes it starts only. A process started at boot (the indexer, the
  automation scheduler) does not see the override.
- **`Slipdock.Settings`** is no longer one of them: the cache is off in
  tests, and every async test saves settings into a row of its own (see
  `Slipdock.DataCase`), so tests about limits and registration can be async.
  Sync tests keep the real row, id 1.
- **Fixed unique values** — two async tests inserting the same user email,
  board code or shortcut wait on each other's uncommitted row until one
  finishes, and two such values taken in opposite orders are a deadlock. The
  fixtures keep them apart: in an async test the default user, and any
  `user_fixture("x@example.com")`, gets an address on the test's own domain
  (compare with `fixture_email("x@example.com")`, not the literal); board
  fixtures get unique codes and shortcuts; `sub_board/2` is
  `Boards.create_sub_board/2` with a unique code. A test *about* derived codes
  needs real ones, so it is sync.
- **`AIStub.share/0`** — it calls `Req.Test.set_req_test_to_shared()`, which
  makes the stub global. LiveViews and tasks do not need it (they find the
  test's stub through `$callers`); only code running in a process started at
  boot does, which in practice means the search indexer.
- **`Slipdock.Search.Indexer`** — one queue for the whole node. Sandbox setup
  empties it before each test (`Indexer.reset/0`), which is enough to keep
  tests independent but not enough to let two assert on it at once.
- **The uploads directory** is one real directory on disk; a test that looks
  at or clears what is in it calls `Slipdock.TestConfig.own_uploads_dir/0`
  and gets an empty one of its own.

What is still sync shares something there is no per-test copy of: rate-limit
counts, the Logger level, OS environment variables, the search indexer's
queue, or real board codes. Each such file says which above its `use` line.

Do not flip one of those to `async: true` without removing the sharing first.
Shared values cost time even when nothing fails. While every test inserted
`tester@example.com`, async tests queued behind one another on that row and
the suite took two minutes on 8 cores; with nothing shared it takes one.

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
