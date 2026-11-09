[Slipdock — the manual](../manual.md)

## Profiles

A card's **profile** is one word for what kind of change it is:
`security`, `schema`, `feature`, `fix`, `docs` or `spike`. The six are
fixed, not a board setting. It decides how much checking a change gets:
its **human tier** says whether an agent's acceptance merges it or waits
for a person first (below). How much a verifier spends on it is still to
come.

**The board switch.** Profiles are off until you turn them on: *Profiles*
on the board's [Agentic Building](the-header-and-the-avatar-menu.md#agentic-building) page, `slipdock set-board slipdock --profiles on` (`off`
turns them off), `update_board` `profiles`, or `PATCH /api/boards/:id
{"profiles": true}`. Sub-boards made afterwards inherit the switch, and
export and import carry it. With it off nothing changes, and a card that
has no profile shows none.

**Inferred when an agent starts a card.** With profiles on, a card with
no profile gets one inferred and stored when an agent claims or starts it:
it moves the card into an in-progress list, creates it in one, or a runner
takes the card's job (a verify or merge job doesn't count). A person, the
in-app assistant or an automation rule starting a card infers nothing,
and a profile already set is kept. The card's activity records it
(*profile inferred: schema*). The inference reads the card's paths and
tags, and takes the first of these that matches, so a card touching a
migration and a docs file is `schema`:

1. `security`: tagged `security`, or any path in an auth, access, token,
   OAuth or egress module (a path segment such as `access.ex`,
   `user_auth.ex` or `user_token.ex`).
2. `schema`: any migration (`…/migrations/…`) or schema file
   (`structure.sql`, `schema.ex`, `schema.rb`).
3. `spike`: tagged `spike`. A spike is only ever said by tag.
4. `fix`: tagged `bug`.
5. `docs`: it has paths, and every one is under `docs/`, a `README.md` or
   a `.md` file.
6. `feature`: anything else, including a card with no paths.

**Checked again at completion.** At the claim there is no diff yet, so
inference reads the paths the card declares. When an agent completes the
card it gives the change it actually made: `slipdock done --diff-base
origin/main` counts the changed lines and files from git (or give them as
`--changed-lines N --changed-files a,b`; `complete_card` and `PATCH
/api/cards/:id` take `changed_lines` and `changed_files`). The profile is
then raised, never lowered, and the card's activity says why (*profile
raised: fix → feature, 612 lines changed*):

- a changed file on a security path raises it to `security`, and a
  migration or schema file to `schema`, even when a person set it;
- a `fix` or `docs` change over 400 changed lines (added plus removed) is
  raised to `feature`, unless a person set the profile: their call on the
  card stands against its size.

On a board that verifies work the raise lands with the submission, so a
`docs` card whose change adds a migration is verified and held like any
`schema` card. A person completing a card raises nothing; nor does a
board with profiles off.

**Setting it yourself.** Anyone who can edit a card can set or clear its
profile: the *Profile* select in the card panel (shown on a board with
profiles on, or on a card that has one), `slipdock add` or `edit
--profile fix` (`--no-profile` clears it), `PATCH /api/cards/:id
{"profile": "fix"}` (`""` clears it), and `create_card` or `update_card`
`profile`. An unknown name is refused with the list.

**Where it shows.** A chip with the word on the card's front, the card
panel, `slipdock card` (*Profile:*), the `profile:fix` mark in `slipdock
cards`, the card's JSON (`profile`, left out when there is none),
`get_card` and `list_cards`, and the card's line on the ledger (a chip on
the *Ledger* page, `profile:fix` in `slipdock ledger`, `card.profile` in
`GET /api/boards/:id/ledger` and the `activity` tool's ledger view).

### The human tier

Each profile has a **human tier**: what an agent's acceptance does on a
board that ships by pull request. The defaults are the strict ones:

| Tier | Profiles | An agent's acceptance |
|---|---|---|
| `none` | `docs`, `fix` | merges, as without profiles |
| `ledger` | `feature` | merges; the card's line on the ledger is your look at it (it behaves as `none`, and is there so you can raise it) |
| `before_merge` | `schema`, `security`, `spike` | holds the card and asks a person first |

A card with no profile is judged by the one its paths and tags infer, so
an unprofiled migration still waits. A person's own acceptance (the card
panel's *Accept*, `slipdock verify`, completing a pending card) is a
person's look already, and merges whatever the tier. On a board that
ships by push the work is already on the default branch, so there is no
merge to hold and the tiers change nothing. With profiles off every tier
is `none`.

**Held for a person.** An agent accepting a `before_merge` card leaves it
in progress as *Accepted, held for a person* (`verify_state: held`), its
`review` flag still on and no merge job queued, and opens one wait, a
`release` question (so it goes to whoever the board routes `release` to,
else the board's owner), with two choices:

- **Merge** queues the merge, as an acceptance does without the tier.
- **Send back** returns the card rejected, your answer the reason (kept
  as the failing part, *the ask*), to the top of the ready list for
  rework. Skipping the wait sends it back too.

Only a person may answer it: an agent's answer or skip is refused. You
can also decide on the card itself: the panel's *Merge* and *Send back*,
`slipdock verify ID accept` or `reject --reason …`, `verify_card`, or
`POST /api/cards/:id/verify`, which close the wait. Withdrawing the wait
leaves the card held, and nothing merges until a person decides. While
held, the card keeps its lane and its dependents wait, as a card awaiting
verification does on a pull request board; the health monitor doesn't
count it as stuck or as missing its merge (only *Question unanswered*
reminds the person after two days); and its line on the ledger says
*waiting for* the person until it merges.

**Changing a tier.** A tree has one set of tiers, kept on its root board:
*Human tier, by profile* on the root board's Agentic Building page (shown
with profiles on; a sub-board's page shows it read-only, with a link to the
root's), `slipdock set-board slipdock --profile-tier schema=none`
(repeatable; `default` puts one back), `update_board` `profile_tiers`, or
`PATCH /api/boards/:id {"profile_tiers": {"schema": "none"}}`, merged
onto what is there. A sub-board's write is refused, naming the root. An
unknown profile or tier is refused with the lists. Setting `security` to
`none` is allowed, and said loudly: a warning in the settings, on
`set-board`'s stderr, and in `update_board`'s `warnings`. The board's
JSON shows every profile's tier as `profile_tiers` (nil with profiles
off); export and import carry the changes.

### The verifier's spend

A profile also sets how much checking a card gets. Like the rest of
profiles, this is off until profiles are on.

**`docs` goes unverified.** On a board that verifies work, an agent
completing a `docs` card (its profile, or the one its paths infer) queues
no verify job. The server accepts it itself, right after the evidence is
posted: *Accepted by the server*, with `verify_checks` saying
`not_verified: "docs"` and the evidence's suite as its `suite` part (CI's
result, on a board that ships by pull request). Then the human tier
applies as for any acceptance, so a `docs` card merges by default, and is
held for a person if you set `docs` to `before_merge`. The bar is still
required and locks as usual, because a person may have asked for
something specific. A suite the evidence reports as failing is sent back
instead (`the suite: N failed`). On the ledger the line reads *not
verified (docs)* (`not_verified` in the REST and MCP ledger), and
`slipdock card` shows `○ not verified`.

**`schema` and `security` get a defect review.** A verify job (or an
audit) on such a card has an extra step: read the diff for bugs, not
style; on a fix, find the root cause; give each finding the file and line
it is at, never a guess from a name; and tag it Important, Nit or
Pre-existing. The verifier gives each finding as a check,
`defect:important=lib/foo.ex:42:why` (or `defect:nit=…`,
`defect:pre-existing=…`), kept in `verify_checks` as `defect_review` (a
list of `severity`, `file`, `line`, `note`). An Important finding is a
failing part: it is a rejection, and an acceptance can't carry one. A Nit
or a Pre-existing finding is reported only. The card panel and `slipdock
card` list each finding.

**A model per profile.** A claimed job carries its card's profile (with
profiles on): the runner's `x-card-profile` header, `job.profile` in
`POST /api/boards/:board/jobs/claim`, `profile` in MCP `claim_job`, and a
`profile:` line from `slipdock claim-job`. Both runner scripts put it in
`SLIPDOCK_PROFILE`, and set `SLIPDOCK_MODEL` from the config's
`MODEL_<profile>` (`MODEL_docs`, `MODEL_schema`, …; `$MODEL_docs` and so on
in the PowerShell config). The installers write these knobs commented out,
so nothing changes until you set one. The `claude` and `codex` jobs they
write pass `--model` (or `-m`) only when `SLIPDOCK_MODEL` is set. The
server sends only the word: what model it means is your runner's config.

---

← [Lanes](lanes.md) · [Contents](../manual.md) · [Waiting on a person (waits)](waiting-on-a-person-waits.md) →
