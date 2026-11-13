
## Findings

What a pass learned that the code and tests don't show, kept on the board
for every later pass (W-2310). Settled knowledge goes straight into the
handbook; a **finding** is for the rest: what is uncertain, cuts across
cards, or shows the handbook was wrong. Write them as a block in the
closing comment, once, beside the `Handbook:` line (on a board that
verifies work, the completion's evidence is that comment): never again
in a wrap-up, a restatement or on the epic.

```
- Handbook: no change (a test-only fix)
- Findings:
  - gotcha: `mix format` can need two passes
  - rule: every new tool gets a docs test
  - handbook-wrong: W-1950 §Tests says …, but …
  - tooling: …
  - tooling (runner): the installed CLI lacks --paths-from
  - process: …
```

`tooling (runner)` marks an item about the machine the pass ran on (its
installed CLI or skills), not the project: it is kept with the runner,
out of the board's default list (`scope=runner` shows them).

An item already dealt with says where, and is recorded `promoted` with
that place as its `note`, not left open for triage: `[done: <where>]`
after its kind when it is settled in the handbook (`- gotcha [done:
W-1950 §Local setup]: …`), or `→ #<card>` (or `-> #<card>`) at its end
when a card was filed for it (`- tooling: no test pins it → #2087`).

A fix is a card, not a finding: a concrete change you could hand to
someone (a missing test such as "no test pins `slipdock done`'s exit
codes", a stale moduledoc or doc entry, a tooling bug such as "`page
section --append -` writes a literal `-`") goes on the board as a card
now (`POST /api/boards/:board/cards`, `create_card`, `slipdock add`: in
the Housekeeping list when the board has one, else the backlog; a
design question, whose answer changes how the product or a process
behaves, in Triage) and into the block as `→ #<card>`. A finding is only for
what is uncertain, cuts across cards, or shows the handbook wrong
("`mix format` can need two passes", "W-1950 §Tests says async is safe,
but the fixture is one user").

One record per lesson: an item repeating an open finding on the same
card (after normalising case, whitespace, backticks, trailing
punctuation, `#id`s and shas, or most of its words in common) adds to
its `count`; one that restates an open finding on another card of the
tree (the same normalised text, or mostly the same telling words, any of
`gotcha`, `tooling` and `process`) is recorded `merged` into it with a
`note` saying why, and the listing shows that one with every card it
was said on (`cards`). One that matched nothing is put to the model
once, with the open findings it could repeat; a match merges it with
`cause: "same-lesson-ai"` and the model's reason in its `note` (reopen
it if the model was wrong). `rule` and `handbook-wrong` items are never
merged across cards.

The test for one: would a card on a different subject want to know
this? Never a pointer (`in the evidence`, `recorded on #1819`), an event
the board records itself (below), something the card fixed, or a fact
about the card's own code (`Boards.move_card/4 returns :ok`).
`Findings: none` is the usual answer; filler isn't. A block that only
points elsewhere records nothing: the evidence is a comment of its own,
and its block is read there.
A line with no known kind is kept whole as a `gotcha`. The server also
records its own (source `rejection`, `verification`, `requeue`, `timeout`, `failed`,
`merge`, `audit`, `health`, `incident`), counting repeats on a card, on any
board, handbook or not. A lane refusal is not one (#1968): the refusal, the
job's log and its held reason already say so. Findings with source `lane`
from before then are kept. A card's `rejection` findings are dismissed
when the card is accepted (or merging, on a board that ships by pull
request), each with a `note` saying the rework was accepted and when: the
rejection has been dealt with, and the per-rule tally is in `slipdock
quality --rules`, read from the verdicts. A `verification` finding stays
open.

**Incidents** (#1946): a card that broke after something shipped says so
with `caused_by` (the card whose shipping caused it, any card you can
read) and `missed_by` (the check that should have caught it: `bar`,
`rules`, `ci`, `verify`, `audit` or `none`). Set them only when a person
says so: `PATCH /api/cards/:id {"caused_by": 123, "missed_by": "ci"}`
(null clears; create takes them too), `update_card`/`create_card`
`caused_by` and `missed_by`, `slipdock edit ID --caused-by 123
--missed-by ci` (`--no-caused-by`, `--no-missed-by`; `add` takes both).
An unknown layer, or a card you can't read, is a `422` naming the field
in a sentence. `GET /api/cards/:id` and `get_card` show both ends:
`caused_by_card` (`{id, hidden: true}` when you can't read it) and
`incidents`, the incidents a card caused, each with its `missed_by`.
While an incident names both, its cause carries one `process` finding
with source `incident` ("#456 (incident) was missed by ci"), changed in
place as the fields change and gone when either clears
(`slipdock findings <board> --source incident`).

Findings are kept on the tree's root board, `open` until a person
triages them: `promoted` (into the handbook, said in `note`),
`dismissed`, or `merged` into another finding (which takes its count).
`slipdock findings <board> [--status S] [--kind K] [--days N] [--scope S]` (REST
`GET /api/boards/:board/findings?status=&kind=&source=&card=&since=&scope=`)
lists them; `slipdock finding <id> dismiss|promote|reopen [--note …]`
or `merge --into <id>` (`PATCH /api/findings/:id {action, note, into}`,
write access) triages one. A card's `findings` (in `get_card` and
`GET /api/cards/:id`) counts its open ones.

An open finding that an open proposal names is *waiting* on the person
deciding that proposal (#2767): triaging it would close the proposal, so
`status=open` (the default) leaves it out and `status=waiting` lists just
those. Each finding listed carries `waiting`, the proposal's id, or `null`;
`slipdock findings` marks it `[waiting on proposal #id]`.

What the findings leave for a person is the proposals drafted from them,
not the open list, which triage and the server handle: the listing
leads with `awaiting`, the open garden proposals whose subject names
findings (as the garden lists them, each with its `findings`), and
`slipdock findings` prints "N proposals await you" before the list, each
by id. MCP `garden` with `findings: true` lists the same, from the
tree's root (`check: proposal` alone is every open proposal on the board
given); a person decides each on the board's Tidy-up page, which
`slipdock findings` links, as no API token can.

A finding counted to the board's `findings_propose_at` (3 by default, 0
off; `update_board`, `PATCH /api/boards/:board`, `slipdock set-board
--findings-propose-at N`) is drafted by the server as a garden proposal
for a person: a rule on the `## Rules` of the handbook page holding a
rule the finding names (`DATA-14`), else the page whose prefix that id
carries, else the page covering its cards' paths (else Specification),
with that page's next id; `must` citing a check the finding names, else
`should`. A finding shows it as `proposal_id` and
`proposed_rule`, never has two open, and is `promoted` when a person
applies it. Don't file one by hand for a finding that has one.
