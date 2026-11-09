[Slipdock — the manual](../manual.md)

## Findings

Passes learn things the code and tests don't show: a formatter that needs two
runs, a fixture that is always the same user, a size cap a few bytes from
breaking. A **finding** keeps one on the board, where every later pass, the
verifier and other machines can read it, rather than in one agent's memory.
Settled knowledge goes straight into the [handbook](../agents.md#the-handbooks-rules); findings
are for what is uncertain, cuts across cards, or shows the handbook was wrong,
and they get a second look before they become rules.

**Written by the pass.** A closing comment carries a `Findings:` block beside
its `Handbook:` line, one item per line, each with its kind:

```
- Handbook: no change (a test-only fix)
- Findings:
  - gotcha: `mix format` can need two passes
  - rule: every new MCP tool gets a docs test        (a rule candidate)
  - handbook-wrong: W-1950 §Tests says async is safe, but the fixture is one user
  - tooling (runner): the installed CLI ignores --paths
  - process: merges wait for an idle runner
```

The test for one: would a card on a different subject want to know this?
Never a pointer (`in the evidence`, `recorded on #1819`), an event the board
records itself, something the card fixed, or a fact about the card's own code
(`Boards.move_card/4 returns :ok`); `Findings: none` is the usual answer. A block that only points elsewhere
records nothing: the evidence is a comment of its own, and its block is read there. A line with no known kind is kept whole
as a `gotcha`, so nothing written is lost to a typo.

An item that is already dealt with says where, and is kept *promoted*, with
that place as its note, rather than open for triage: `[done: <where>]` after
its kind when it is settled in the handbook (`- gotcha [done: W-1950 §Local
setup]: the test partition needs its own database`), or `→ #<card>` (`->`
works too) at its end when a card was filed for it (`- tooling: no test pins
the CLI's exit codes → #2087`). Words like "(corrected)" or "fixed" are not
read as done, since lessons say them too.

A fix is a card, not a finding. A concrete change you could hand to someone
waits a day for triage as a finding, and triage only turns it into a card, so
a pass files the card at once, in the backlog (`slipdock add <board> "…" --desc
"…" --column Backlog`), and names it in the block with the arrow. A finding is
only for what is uncertain, cuts across cards, or shows the handbook wrong:

| A card (`→ #id`) | A finding |
|---|---|
| no test pins `slipdock done`'s exit codes | `mix format` can need two passes; run the check after it |
| a stale moduledoc or doc entry | the shared `_pre_push` database can hold another branch's migration |
| `page section --append -` writes a literal `-` | W-1950 §Tests says async is safe, but the fixture is one user |

Write the block once, in the closing comment (on a board that verifies work, the completion's
evidence): not again in a wrap-up, a restatement or on the epic. The block is
read when the comment is posted (the evidence of a completion too), and
deleting the comment takes back what it added that nobody has triaged yet.

**One record per lesson.** A lesson said again is counted, not kept twice:

- **On the same card**, an item with the same kind as an open finding there
  and the same text after normalising (case, whitespace, backticks, trailing
  punctuation, and every `#id` and commit sha read alike) adds to that
  finding's count. So does a restatement in other words, when at least 60% of
  its normalised words are the same.
- **On another card of the tree**, an item that restates an open finding, or
  a repeat already merged into it, is recorded *merged* into it, which counts
  it, with a note saying why: *same lesson as #N, in the same words*, or
  *reworded (62% alike)*. Reworded means the telling words are mostly the
  same: the common words (`the`, `run`, `when`) count for nothing, and a name,
  path or flag (in backticks, or with `_`, `.` or a digit in it) counts three
  times a plain word; at 55% alike or more it is the same lesson. The kind
  doesn't have to match, since one writer's `gotcha` is another's `tooling`.
  The list shows that one finding, with every card it was said on, and a
  person can reopen a merge they disagree with. `rule` and `handbook-wrong`
  items are never merged across cards: a rule candidate is judged on its own
  card.
- **What the words don't catch**, a model does: a new finding that matched
  nothing goes to one AI call with the tree's open findings it could repeat
  (other cards', the same scope, the newest 40). If the model says it repeats
  one, it is merged into it, the note giving the model's reason (*same lesson
  as #N, by the model: …*), and a person can reopen it. With AI off, or a call
  that fails, it stays as it is. It is one call per finding, never one per
  pair, and none when there is nothing to compare it with.
- **A tooling item about the machine, not the project** is written
  `- tooling (runner): …` (the installed CLI or skills lag the repo, say). It
  is kept with the runner whose job the pass ran in (its card's job, or its
  epic's), shown with `--scope runner` (`scope=runner`, the Findings page's
  Scope filter) and left out of the board's list by default. `(runner)` on any
  other kind is ignored.

**Promotion by recurrence.** A lesson nobody triages is still settled once
it keeps coming back. When an open finding's count reaches the board's
threshold (*Propose a rule when a finding is seen this many times* on
the board's [Agentic Building](the-header-and-the-avatar-menu.md#agentic-building) page, `slipdock set-board B --findings-propose-at N`, `update_board`
`findings_propose_at`, `PATCH /api/boards/:board`; 3 by default, 0 never),
the server drafts a rule and files it on the [Tidy-up page](tidying-up.md) as
a proposal for a person to apply or dismiss:

- **Where.** On the `## Rules` of the handbook page holding a rule the
  finding names (`DATA-14`), else the page whose prefix that id carries,
  else the page whose `covers:` take in the paths of the finding's cards
  (most first), else the Specification page. The rule's id is that page's
  prefix and its next number (`DATA-15`), so a finding about a data rule
  never takes a number from UX & UI.
- **Up the ladder.** A finding that names a check (a `*_test.exs`, a `mix`
  command, the repo checks) becomes a `must` rule citing it; any other, a
  `should` rule left to judgement. A model words it, given the finding, its
  cards and the page's rules. With no model, or one that fails, it is a
  `should` rule carrying the finding's own words.
- **One at a time.** A finding never has two open proposals. **Apply**
  writes the rule and marks the finding *promoted* with the rule id;
  **Dismiss** leaves it open with a note, and nothing is proposed again until
  its count has risen by the threshold once more. Undoing an applied one opens
  the finding again. Count changes that land together (a triage merging
  several findings into one) still file one proposal between them.
- **Triage closes it.** Promoting, dismissing or merging the finding (by a
  person, a triage pass or a dedupe) closes its open proposal by itself, with
  a note naming why (`finding #14 promoted: W-1950 §Tests`), so the Tidy-up
  page keeps only what still needs a person. Reopening the finding reopens
  its proposal. A proposal filed by hand that names the finding stays open.
- **What is proposed.** Only the project's findings, not a runner's tooling,
  and only lessons: what an agent wrote, a verifier's rejection or rule hit,
  or an audit. Events the system records (health incidents, failed merges,
  lane holds, requeues, timeouts, failed jobs, incidents) are never drafted
  into rules. Only on a board with a handbook: elsewhere findings are kept as they are.
  `slipdock findings` and the Findings page show `proposal #id` on a finding
  that has one.

A board with findings from before this (#1941) collapses them with
`mix slipdock.findings.dedupe <board> [--dry-run]`, which applies the same
two rules to the open ones as merges a person can reopen (run it again after
an upgrade that widens them, as #2117 did)
(the handbook's Operations page, W-1951 §Runbooks, has the release form).

**Recorded by the server.** The system notes its own signals without asking:
a verifier's rejection, a job that times out or fails, a card requeued or
given up on, a merge that fails, an audit that disagrees, a health-monitor
incident, a verifier reporting a rule broken in code the change didn't touch
(sources `rejection`, `verification`, `timeout`, `failed`, `requeue`,
`merge`, `audit`, `health`). A lane refusing a move is not one: it is the
lanes working, and the refusal, the job's log and its held reason already
say so (findings with source `lane` from before this are kept as they
were). A card's rejections are dismissed by themselves once it is accepted
(or merging, on a board that ships by pull request), each with a note saying
the rework was accepted and when, since the rejection has been dealt with. The
per-rule tally stays in `slipdock quality --rules`, which reads the verdicts.
A verifier's note about code the change didn't touch (`verification`) stays
open. Each has its source,
card and job, and a repeat on the same card for the same cause adds to its
count rather than making another: a card that times out three times is one
finding counted three times. A rejection's kind comes from the part that
failed: a broken rule is a `rule`, a disputed Handbook line `handbook-wrong`,
anything else `process`. Boards without a handbook keep them too, on the
root board: they are about the work, and a handbook installed later starts
from them.

**Triage.** Findings are kept on the tree's root board, `open` until someone
with write access decides: **promote** it (it became a handbook rule or
section; say which in the note), **dismiss** it, or **merge** it into another
finding of the same tree, which takes its count. *Reopen* undoes any of them.
Anyone who can read the board can list them, and a card shows how many open
ones it has.

**The Findings page.** Each board has one at `/boards/:id/findings`, a tile
on the board's [Agentic Building](the-header-and-the-avatar-menu.md#agentic-building) page (the card panel's
Findings link opens it too);
on a sub-board it lists the whole tree's, as the API does. It leads with
**Waiting on you**: the garden proposals drafted from findings that are still
open, each with the findings it came from and a link to the Tidy-up page to
apply or dismiss it. That is all a person needs to do. Triage and the server
handle the findings themselves, so the tile counts these proposals ("1
proposal", with "N findings being handled" under it), not the open findings,
and `slipdock findings` prints "N proposals await you" first. Below them, as
reference, it shows the open
findings, newest first, each with its kind, source, count, card, who recorded
it, when it was found ("2 h ago", the exact time on hover) and its text, and filters them as the API does: status (open, promoted,
dismissed, merged, any), kind, source, card and since (days back or a date),
kept in the URL so a filtered list can be shared. With write access each open
finding has **Promote or merge…** (a panel: promote with a note saying what it
became, or merge it into another open finding picked from a list) and
**Dismiss**; a triaged one has **Reopen**. A card with open findings says
"N open findings" in its panel, linking to the page filtered to that card.

```sh
slipdock findings slipdock                       # proposals awaiting you, then the open ones, newest first; each line dated
                                                 # (#438 today 17:30 gotcha …, or #437 2026-11-07 …, UTC)
slipdock findings slipdock --kind rule --days 7  # also --status all, --source timeout, --card 12
slipdock findings slipdock --source incident     # what each incident's check missed
slipdock findings slipdock --scope runner        # tooling kept with a runner; --scope all for both
slipdock finding 41 promote --note "W-1950 §Tests TEST-9"
slipdock finding 42 merge --into 41
slipdock finding 43 dismiss
```

```
GET   /api/boards/:board/findings?status=&kind=&source=&card=&since=&scope=   (since: a date, a time or days; scope: board, runner or all)
PATCH /api/findings/:id {action: dismiss|promote|merge|reopen, note?, into?}
```

---

← [Tidying up](tidying-up.md) · [Contents](../manual.md) · [The ledger](the-ledger.md) →
