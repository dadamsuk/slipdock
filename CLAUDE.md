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

CI treats warnings as errors and checks formatting, so run both first:

```sh
mix compile --force --warnings-as-errors
mix format --check-formatted
```

`mix format` doesn't always settle in one pass, so run the check even after formatting.

## Committing and shipping

Commit with the card's id in the message (`#123`). Then ship the way the card's board does:

- **By push** (the default): push to `main`. A push to `main` deploys.
- **By pull request** (`ship_via: pull_request`; the claimed job's prompt and `slipdock card` say so): push the card's branch (`card-<id>`), open a PR, and give its URL on completion (`slipdock done --pr`). Never push to `main`: the PR is merged when the card is accepted. The PR's CI is the full suite: before pushing, run the tests you added or changed and the two checks above, not the whole suite, and complete the card once the PR's checks pass. That green CI run is the green suite.

## This repository is public

Keep anything personal out of code, tests, docs and commit messages: no real names, email addresses, hostnames, IP addresses or tokens. Tests use `example.com` addresses. `test/slipdock/nothing_personal_test.exs` checks this.
