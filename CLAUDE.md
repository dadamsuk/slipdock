# Working on Slipdock

Elixir and Phoenix conventions for this codebase are in `AGENTS.md`.

## When you change functionality

Consider each of these. Not every one applies to every change, but judge each:

- Every door (SPEC-2): the web UI, the REST API, the CLI (`cli/`) and the MCP tools (`lib/slipdock_web/mcp/tools/`). A door left out is said why on the card.
- The agents page and the API guide (`docs/agents.md`, `lib/slipdock_web/api_guide.ex`).
- The in-app help pages (SPEC-10): `HelpLive.Guides` for the app, `HelpLive.Agents` and `HelpLive.Flow` for agents and runners.
- The packaged skills in `priv/skills/`, their one source. Installed copies (`~/.claude/skills`) are never edited by hand: the install one-liner puts the server's there (`docs/agents.md` §Install the skills). The runner daemon also puts the server's there before each agent job (#2614), unless the machine's `local.json` sets `no_skills_update` or its jobs run as another account (the user executor), where the one-liner is the only route. No test reads an installed copy (`test/slipdock/repo_checks_test.exs`).
- `README.md` and the manual: `docs/manual.md` is its contents, and each section is a page of its own in `docs/manual/` (a new section gets a page and a line in the contents; `test/slipdock/manual_pages_test.exs`).
- The test suite.

## Tests come with the code

Not optional: new or changed code comes with tests for it, in the same commit. Cover the paths you added (the error and edge cases, not just the happy path), and assert outcomes rather than just running the lines. A card is not done until those tests exist and the suite is green; say on the card which tests you added. If something truly can't be tested (a deploy script, say), say why on the card instead. Pure refactors with no behaviour change are covered by the existing tests.

## The handbook

The project handbook is W-1943 (Handbook/Index) on the `slipdock` board. Read the sections a card needs before building (`slipdock card` lists them) and update them before closing it, with a `Handbook:` line in the closing comment.

What a card teaches about the project goes there too, never only into your own agent memory, which the verifier, other runners and other machines can't read. Settled knowledge goes into the handbook section that covers it (testing, CI and shipping are in W-1950, runbooks in W-1951). What is uncertain, cuts across cards or shows the handbook was wrong goes in a `Findings:` block beside the `Handbook:` line (`slipdock findings slipdock` lists them). Agent memory keeps only facts about the machine and the person.

## Before you push

Run `mix pre_push` (a function in `mix.exs`, `pre_push_steps/1`, not a task under `lib/mix/tasks/`). It runs what CI's static checks job and its build check, in CI's order with CI's arguments, and stops at the first that fails: `compile --force --warnings-as-errors`, `format --check-formatted`, the CLI's `format --check-formatted` and `compile --warnings-as-errors` in `cli/` (as CI's cli job does, in the CLI's own `_build`; the root `mix format` doesn't cover `cli/`), the runner daemon's `go vet ./...` and `go test ./...` in `daemon/` (as CI's daemon job does; it needs Go 1.22 on the PATH), `hex.audit`, `deps.audit`, `sobelow --config` and `credo diff` against where the branch left `origin/main`. After the CLI's compile and the daemon's tests it runs the repo checks in `test/repo_checks.txt`: the tests that hold the repo's own files, docs and skills to a rule, which a change elsewhere breaks. A new test of that kind goes on that list, or `test/slipdock/repo_checks_test.exs` fails (W-1950 §Tests). It takes about 2½ minutes (60 s the forced compile, 50 s credo, 15 s the repo checks), so start it alongside the tests you changed rather than after them: it builds in `_build/pre_push` and tests in a database of its own, one per checkout (`MIX_TEST_PARTITION=_pre_push_<8 hex digits of the checkout path's SHA-256>`, `pre_push_partition/1`), so it doesn't disturb or wait for a `mix test` running beside it, and another worktree's migrations can't break it. It drops that database just before the repo checks, so a schema left by an earlier branch in the same checkout doesn't carry over either: there is no need to drop one by hand before a run. A `TEST_DATABASE_URL` in the environment gets the same suffix on its database's name. Each checkout leaves its own `slipdock_test_pre_push_…` database behind when its worktree goes: `mix pre_push --prune` drops those whose checkout no longer exists (it runs no checks; it keeps this checkout's and every live `git worktree list` entry's, and a separate clone's it drops is made again by that clone's next run). Its first run there compiles the dependencies once. `mkdir -p _build/pre_push && cp -r _build/test _build/pre_push/` skips that (it builds in `_build/pre_push/test`; without the `mkdir` the copy lands in `_build/pre_push/lib`, which nothing reads), but leaves the dependencies' relative `priv` and `src` links one level short, and a missing `tz` priv recompiles 14 files on every step: mend them with `find _build/pre_push -xtype l -path '*/lib/*' -exec sh -c 'ln -sfn "../$(readlink "$1")" "$1"' _ {} \;`. To check a commit that has already merged, give credo a base: `mix pre_push --from-git-ref <ref>`.

`mix format` doesn't always settle in one pass, so run the check even after formatting. A function already over credo's complexity limit takes a new branch through a helper, never inline (W-1950).

## Committing and shipping

Commit with the card's id in the message (`#123`). Then ship the way the card's board does:

- **By push** (the default): push to `main`. A push to `main` deploys.
- **By pull request** (`ship_via: pull_request`; the claimed job's prompt and `slipdock card` say so): push the card's branch (`card-<id>`), open a PR, and give its URL on completion (`slipdock done --pr`). Never push to `main`: the PR is merged when the card is accepted. The PR's CI is the full suite: before pushing, run the tests you added or changed and `mix pre_push`, not the whole suite. Watch it with `gh pr checks card-<id> --watch --fail-fast`, and complete the card once the PR's checks pass. That green CI run is the green suite.

## This repository is public

Keep anything personal out of code, tests, docs and commit messages: no real names, email addresses, hostnames, IP addresses or tokens. Tests use `example.com` addresses. `test/slipdock/nothing_personal_test.exs` checks this.
