
## Profiles

Some of your boards give each card a profile, one word for what kind
of change it is (`profiles: on` on the board's line): `security`,
`schema`, `feature`, `fix`, `docs` or `spike`. When an agent claims or
starts a card with none (moves it into an in-progress list, creates it
in one, or a runner takes its job), the board infers one from its
paths and tags, strictest first: `security` if tagged so or a path is
in an auth, access, token or egress module; `schema` for a migration
or schema file; `spike` if tagged so; `fix` if tagged `bug`; `docs` if
every path is documentation; else `feature`. Write the card's paths
before starting it so the inference has them. When you complete it,
give the change you made (`changed_lines`, added plus removed, and
`changed_files`: `complete_card`, `PATCH /api/cards/:id`, `slipdock
done --diff-base origin/main`): a migration raises the profile to
`schema`, a security path to `security`, and over 400 lines a `fix` or
`docs` card to `feature` unless a person set it; never lower. Set or clear it
yourself with `profile` (`PATCH /api/cards/:id {"profile": "fix"}`,
`update_card`/`create_card` `profile`, `slipdock edit ID --profile
fix` or `--no-profile`); an unknown name is refused (`422`) with the
list. It shows in the card's JSON, `get_card`, `list_cards`,
`slipdock card` and the ledger's lines (`card.profile`). Beside it,
`profile_source` says where it came from: `inferred`, or set by a
`person`, an `agent` or a `rule` (nil with no profile, or unrecorded).

Each profile has a human tier (the board's JSON, `profile_tiers`):
`none` (`docs`, `fix`, `spike`) and `ledger` (`feature`) let an agent's
acceptance merge; `before_merge` (`schema`, `security`) holds
it on a board that ships by pull request: the card goes
`verify_state: "held"`, no merge job, and a `release` wait asks a
person to Merge or Send back. An agent can't answer that wait or
decide a held card (`403`); a person's answer queues the merge or
returns the card rejected with their reason. A card sent back is
rework like any rejection. Change a tier on the root board with
`PATCH /api/boards/:id {"profile_tiers": {"schema": "none"}}`
(`default` puts one back), `update_board` `profile_tiers` or
`slipdock set-board B --profile-tier schema=none`.

A `spike` card (profile `spike`, or no profile and tagged `spike`, on
any board) answers a question by building, and its code is never
merged: complete it with `no_code` naming the answer's page and the
branch its prototype is on (`slipdock done ID --no-code "spike: answer
on W-…, prototype on card-ID"`), never a pull request. An agent naming
one is refused (`422`), and accepting it merges nothing. It holds no
lane, even with paths: nothing is refused or held because of it.
Spikes come from planning: the `slipdock-plan` skill's Spike stage,
between Grill and Spec for a feature or a system, turns an open
question that only building can answer, whose "no" changes the spec
and costs more found late than the spike does, into a spike subcard of
the epic once a person confirms it (unattended: one `product` wait),
its bar the question, and stops. Write the answer as a page pinned to
the epic: the question, the answer or *inconclusive*, the evidence and
what it changes in the plan. When the epic's last open spike is
accepted, the server opens one `product` wait on the epic, "Spikes
answered (#…): resume planning"; a person resumes, and planning
writes the Spec from the answers. Nothing resumes by itself.

A profile also sets the verifier's spend. Completing a `docs` card
on a verifying board queues no verify job: the server accepts it
(*Accepted by the server*, `verify_checks.not_verified: "docs"`, the
evidence's suite as the suite part, so give CI's result as `suite`)
and its tier decides the merge; a failing suite sends it back. The
bar is still required. A verify job on a `schema` or `security` card
adds a defect review: findings as `defect:important|nit|pre-existing=<file>:<line>[:why]`
checks (`verify_checks.defect_review`); an Important one is a
rejection, a Nit or a Pre-existing one is reported only. A verify
job on a `fix`, `feature`, `schema` or `security` card adds a
mutation review: 3 to 5 changed lines broken on purpose, and every
guard or branch the diff adds (a new condition, clause, pattern match
or early return) once each, named with its line, the card's
tests run against each, given as
`mutant:killed|survived|pre-existing=<file>:<line>:<mutation>[:note]`
checks, or `mutants=n/a:<why>` (`verify_checks.mutants`). A survivor
on a changed line is a rejection naming the test to write; a
`pre-existing` one (lines the diff didn't change) is kept as a
finding; killed ones are carried to a resubmission. A claimed
job carries its card's `profile` (MCP `claim_job` `profile`, the REST
claim's `job.profile`, the runner's `x-card-profile` header); a
runner's own config may pick a model by it (`MODEL_<profile>`), and
the server never names one.
