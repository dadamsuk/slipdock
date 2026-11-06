# Working on Slipdock

Elixir and Phoenix conventions for this codebase are in `AGENTS.md`.

## When you change functionality

Consider each of these. Not every one applies to every change, but judge each:

- The CLI (`cli/`), not just the UI.
- The agents page and the API guide (`docs/agents.md`, `lib/slipdock_web/api_guide.ex`).
- The packaged skills in `priv/skills/`. Installed copies of them elsewhere are edited the same way, never copied over.
- `README.md` and `docs/manual.md`.
- The test suite.

## Tests come with the code

Not optional: new or changed code comes with tests for it, in the same commit. Cover the paths you added (the error and edge cases, not just the happy path), and assert outcomes rather than just running the lines. A card is not done until those tests exist and the suite is green; say on the card which tests you added. If something truly can't be tested (a deploy script, say), say why on the card instead. Pure refactors with no behaviour change are covered by the existing tests.

## The handbook

The project handbook is W-1943 (Handbook/Index) on the `slipdock` board. Read the sections a card needs before building (`slipdock card` lists them) and update them before closing it, with a `Handbook:` line in the closing comment.

What a card teaches about the project goes there too, never only into your own agent memory, which the verifier, other runners and other machines can't read. Settled knowledge goes into the handbook section that covers it (testing, CI and shipping are in W-1950, runbooks in W-1951). What is uncertain, cuts across cards or shows the handbook was wrong goes in a `Findings:` block beside the `Handbook:` line (`slipdock findings slipdock` lists them). Agent memory keeps only facts about the machine and the person.

## Before you push

Run `mix pre_push`. It runs what CI's static checks job and its build check, in CI's order with CI's arguments, and stops at the first that fails: `compile --force --warnings-as-errors`, `format --check-formatted`, `hex.audit`, `deps.audit`, `sobelow --config` and `credo diff` against where the branch left `origin/main`. After the format check it runs the repo checks in `test/repo_checks.txt`: the tests that hold the repo's own files, docs and skills to a rule, which a change elsewhere breaks. A new test of that kind goes on that list, or `test/slipdock/repo_checks_test.exs` fails (W-1950 §Tests). It takes about 2½ minutes (60 s the forced compile, 50 s credo, 15 s the repo checks), so start it alongside the tests you changed rather than after them: it builds in `_build/pre_push` and tests in a database of its own (`MIX_TEST_PARTITION=_pre_push`), so it doesn't disturb or wait for a `mix test` running beside it. Its first run there compiles the dependencies once. `cp -r _build/test _build/pre_push/` skips that, but leaves the dependencies' relative `priv` and `src` links one level short, and a missing `tz` priv recompiles 14 files on every step: mend them with `find _build/pre_push -xtype l -path '*/lib/*' -exec sh -c 'ln -sfn "../$(readlink "$1")" "$1"' _ {} \;`. To check a commit that has already merged, give credo a base: `mix pre_push --from-git-ref <ref>`.

`mix format` doesn't always settle in one pass, so run the check even after formatting. A function already over credo's complexity limit takes a new branch through a helper, never inline (W-1950).

## Committing and shipping

Commit with the card's id in the message (`#123`). Then ship the way the card's board does:

- **By push** (the default): push to `main`. A push to `main` deploys.
- **By pull request** (`ship_via: pull_request`; the claimed job's prompt and `slipdock card` say so): push the card's branch (`card-<id>`), open a PR, and give its URL on completion (`slipdock done --pr`). Never push to `main`: the PR is merged when the card is accepted. The PR's CI is the full suite: before pushing, run the tests you added or changed and `mix pre_push`, not the whole suite. Watch it with `gh pr checks card-<id> --watch --fail-fast`, and complete the card once the PR's checks pass. That green CI run is the green suite.

## This repository is public

Keep anything personal out of code, tests, docs and commit messages: no real names, email addresses, hostnames, IP addresses or tokens. Tests use `example.com` addresses. `test/slipdock/nothing_personal_test.exs` checks this.
