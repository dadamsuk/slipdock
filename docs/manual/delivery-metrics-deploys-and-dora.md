[Slipdock — the manual](../manual.md)

## Delivery metrics: deploys and DORA

A board can record its project's deploys and say how it delivers. Off on
every board until its owner ticks **Delivery metrics** in the board's settings
(`slipdock set-board <board> --delivery-metrics`); while it is off the board
refuses deploys and shows nothing.

**Setting it up.** **Track deployments** in the board's settings asks three
things — which CI runs the deploy (GitHub Actions, GitLab CI, or another CI or
a shell script), the environments it deploys to, and how commit messages name
cards (`#123` unless you give a pattern) — then turns Delivery metrics on,
issues the board's **deploy token** and shows it once, with the step to paste.
The token records deploys for this board and can do nothing else; keep it as
the CI secret `SLIPDOCK_DEPLOY_TOKEN`. The panel waits for the first deploy and
turns green when it arrives. **Set this up for me** gives a prompt to paste into
Claude Code in the repository instead: it finds the deploy step, wraps it, tells
you the secret to add and tries it with `--dry-run`. The same from a terminal:
`slipdock deploy setup <board> [--ci github|gitlab|shell] [--env production]
[--prompt]`, and `slipdock deploy token <board> [--revoke]` for a new token.
Worked examples are served at `/deploy/examples/` (`github-actions.yml`,
`gitlab-ci.yml`, `deploy.sh`, and `curl.sh` for where the CLI can't go).

**Recording deploys.** In CI, wrap the deploy command:

```sh
slipdock deploy run --env production --tag "$TAG" -- ./deploy.sh "$TAG"
```

It asks the board for the environment's last deployed commit, sends the
commits since then (so the job needs the whole history: `fetch-depth: 0`),
records the deploy started, runs the command, and records it succeeded or
failed from its exit code, which it exits with. A board that can't be reached
never stops a deploy. Deploying a commit older than the last deploy is
recorded as a **rollback**. If the last deploy's commit has left the history
(it was rewritten), the deploy is still recorded, with a warning, and with the
commits since the newest commit made before that deploy finished (none if there
isn't one). Where the deploy is more than one command,
`slipdock deploy start` prints an id and `slipdock deploy finish --id N
--status succeeded|failed` ends it. `slipdock deploy backfill --from-tags
[--pattern 'v*']` records past releases from git tags, once.

**A note on the deploy.** `--note TEXT` on `deploy run` or `deploy start`
(or `$SLIPDOCK_DEPLOY_NOTE`, for a CLI older than the switch) keeps a line on
the deploy, up to 500 characters: `note` in the API and on `slipdock deploy
last`. Slipdock's own release workflow uses it to say how the suite was
satisfied (below).

**Slipdock's own deploys skip a suite that already passed.** After a pull
request merges, `release.yml` runs the suite again before it tags and
deploys the image, unless its first job, `suite`
(`.github/scripts/suite-gate.sh`), finds that the run would test nothing new.
That holds for a push to `main` whose pull request's latest CI run has
completed with every job passed, on a commit whose tree is the same as the
merged commit's: main didn't move between that run and the merge. The run's
name carries the commit it tested (`… · tested <sha>`), since a pull request
run's `head_sha` is the branch's head, not the merge it tested. Then the
`test` job is skipped, and the merge and deploy go ahead. Anything else runs
the suite as before: another tree, a red, missing or unfinished run, a
commit no pull request made, the GitHub API failing, a tag, or
`workflow_dispatch`. The run's summary and the deploy's note say which
(`suite: passed on PR #92 at 1a2b3c4, same tree`, or `suite: ran (<why>)`).

**Deploys the record missed.** Recording is allowed to fail, so a deploy can go
out unrecorded. `slipdock deploy backfill --from-runs FILE` (`-` reads stdin)
records them from CI's runs. It takes a JSON list as `gh run list --json
headSha,createdAt,updatedAt,conclusion` prints it, or `sha`, `started_at`,
`finished_at` and `status`. Each successful run that finished after the last
recorded deploy is recorded oldest first, with the commits since the one
before, and the cards those commits name get their Shipped line. A commit the
board already has is never recorded twice, so it is safe to run before every
deploy:

```sh
gh run list --workflow release.yml --branch main --status success --limit 100 \
  --json headSha,createdAt,updatedAt,conclusion |
  slipdock deploy backfill --from-runs - --env production
```

**Incidents** are ordinary cards tagged `incident` (the tag is a board setting).
`slipdock incident-of <card> <deploy>` says which deploy caused one. A deploy
is a **failed change** when it failed, was rolled back, has an incident linked
to it, or was followed within the hotfix window (24 hours, a board setting) by
a deploy whose commits name an incident card.

**The numbers**, for one environment over 30 days, each with the window
before: deployment frequency, lead time for changes (commit → deploy, P50 and
P85), change failure rate, time to restore (an incident card's creation to its
completion, or a failed deploy to the next good one), rework rate (deploys
naming an incident card), and **idea to production** — a card first entering an
in-progress list to the first deploy whose commits name it. Each has its DORA
band (elite, high, medium, low) where DORA defines one. A strip over the lists
says it in a line, each band a coloured pill (green elite, blue high, amber
medium, red low), and opens the Visualise view, where the numbers run over
time; `slipdock dora <board> [--env E] [--days N]`, `GET
/api/boards/:id/dora` and MCP `get_board` with `dora: true` give it all.

**Shipped lines.** A card a succeeded deploy names shows *Shipped to production
· 1a2b3c4 · 19 Oct 14:32* — one line per environment, the time in your time
zone, and *rolled back since* when a rollback went past it — in its panel, in
`slipdock card` and as `shipped` in its JSON (and `get_card`).

---

← [Visualise: flow, velocity, runners and delivery](visualise-flow-velocity-runners-and-delivery.md) · [Contents](../manual.md) · [Recurring cards](recurring-cards.md) →
