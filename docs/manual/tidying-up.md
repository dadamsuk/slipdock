[Slipdock — the manual](../manual.md)

## Tidying up

Boards rot slowly. Epics whose work is all done are never closed, cards sit in
Done without being ticked off, an in-progress card nobody has touched for a
month still says somebody is on it, two people file the same bug, a wiki page
nothing links to is never found again, and a `[[link]]` with a typo leads
nowhere. Finding these is the chore, so nobody tidies. **Tidy up…** in the
board's menu does the finding: it opens the board's Tidy-up page, where the
gardener proposes a fix for each thing it found. You apply or dismiss each
one, and a dismissal is remembered.

**Looking the board over.** Press **Look the board over**. It covers the board
and every board beneath it (its cards' subcards, all the way down) with these
checks:

| Check | Finds | Proposes |
|---|---|---|
| Epics whose work is all done | an open card whose subcards are all done | complete it and move it to Done |
| In Done but not complete | a card in a done list that was never ticked off (an epic with work still open beneath is left alone) | complete it |
| Complete but not in Done | a completed card outside a done list | move it to Done |
| In progress, untouched | a card in an in-progress list with no activity — no edit, no comment, nothing in its log — for 14 days (a card an agent put there is the [health monitor](the-health-monitor.md)'s) | move it back to the ready list; or snooze it a week, or ask on it |
| Epics with no next step | an open epic with subcards, none of them open, its work not all done | flag it for review, with a comment saying so |
| Long overdue | an open card due more than 30 days ago | give it a new date a week out; or snooze it, or archive it |
| Abandoned in the backlog | a card in a to-do list untouched for 180 days (off unless you turn it on) | archive it (it can be restored) |
| Possible duplicates | two open cards whose title and description read alike (similarity 0.92 or more, from the vectors search already keeps), not already linked | link them as duplicates and archive the one you don't keep |
| Pages nothing links to | a wiki page more than 30 days old with no backlink, no pin and no folder (templates, drafts, pages on a list, pages with pages beneath and folder indexes are never orphans; nor is a page that links to a card — it shows in that card's Docs) | archive it, or file it into a folder |
| Links that nearly match a page | a `[[link]]` to a page that doesn't exist whose title matches one page's title or alias ignoring case, or is within two edits of exactly one (two candidates suggests nothing) | rewrite the link to that page, on every page that has it |
| Closed without a Handbook line | on a board whose tree keeps a [handbook](tools.md), a card completed since it was installed with no `Handbook:` line in any comment (`Handbook: no change (…)` counts; off on boards without a handbook) | comment on the card asking for the docs gate and the line, or reopen it |
| Long handbook sections | a `##` section of a handbook page or decision over 1,500 characters, beyond which search splits it in parts (`## Rules` and the Index's `## Log` are left alone) | split it at its first `###` heading into two `##` sections, losing nothing; with no `###` to split at, a comment on the handbook's Index |
| Handbook pages that cover everything | a handbook page whose `covers:` has a glob that matches nearly any path (`**`, `lib/**`: `**` with fewer than two folders before it), so it is suggested for every card | a comment on the Index saying which page to narrow |
| Rules without a test | a `must` rule whose check has been `judgement` for more than 30 days (by the page's history), or a rule id used twice | a comment on the Index naming the rule, the page and the line; rules are never edited by a suggestion |
| Decisions out of order | a decision that supersedes another without linking back to it, or a page in `Handbook/Decisions` without `Decision:` in its title | a comment on the Index saying what to change |
| Rules changed by an agent | a rule an agent added, reworded or removed since a person last approved the page's rules (their own edit, an applied suggestion, or keeping an earlier one) | Apply reverts the page's `## Rules` to the approved text, leaving the rest of the page alone; Dismiss keeps the change and records the approval |

The last five keep a [handbook](tools.md) in order, and are off on a board
without one. *Rules changed by an agent* is how rules stay a person's call:
agents may edit any page, but a change to a rule waits for a person to keep
it or put it back, and agents are expected to propose a rule rather than
write one (`slipdock garden propose`). They are deterministic, read only the handbook's pages and their
history, and leave contradictions between pages to the triage pass. Where the
fix isn't mechanical they comment on the handbook's Index page, saying what to
change and where; a split edits a page's section, so only a person can apply
it, as with a proposed handbook edit.

Snoozed, archived and stand-in cards are left out: a snoozed card is somebody
having already decided when to look again. No model is called — duplicates use
the stored search vectors, and above 5,000 open cards only the most recently
updated are compared.

**Reviewing.** Suggestions are grouped by check. Each says what it found and
why ("“Fix login” is in “In Progress” with no activity since 2 Aug 2026; last
comment by Sam"), links to the cards and pages, and spells out the steps
applying it would take. **Apply** takes them; a button per alternative takes
that instead (**Snooze**, **Ask**, **Archive**, **File into Notes**);
**Dismiss** says no. **Apply all in this group** applies each in turn and says
which couldn't be. A possible duplicate shows the two cards side by side, with
**Keep this one** under each. **Recently applied** lists what was applied, by
whom, with **Undo**.

**Rules drafted from findings.** A finding seen as often as the board's
threshold is proposed here as a handbook rule by the server itself (see
[Findings](findings.md), *Promotion by recurrence*): **Apply** writes the rule
and marks the finding promoted, **Dismiss** leaves it open.

Applying goes through the ordinary edits, so the activity log has the change
and a line "via gardener: …", automations fire (completing a card is a
`card_completed`), and permissions are what they always are: it needs write
access to the board and to everything the steps touch. Undo reverses each step,
and refuses, changing nothing, when something it would undo has moved on since
— "card #12 “Fix login” has been moved to another list since".

**A dismissal stays dismissed** for as long as what it was about stays as it
was. Each suggestion carries a fingerprint: the check, the cards or pages, and
the state that made it a finding (when the card last changed, its due date).
New activity changes the fingerprint, and the check may then suggest again. An
applied suggestion isn't suggested again either, and an open one a later look
no longer finds is dropped. A dismissed duplicate pair stays dismissed however
either card is edited later.

**Choosing the checks.** Board settings → the **Gardening** tab has each check on or
off, and its thresholds: days for the stale, overdue, backlog and orphan
checks, the similarity and card cap for duplicates, the number of edits for
links, the characters a handbook section may run to, and the days a `must`
rule may stay `judgement`. Everything but *Abandoned in the backlog* is on to begin with.

**Every week, by itself.** The automation preset **Weekly tidy-up** (Tidy
group) looks the board over on a weekday at a time (Monday 09:00 by default)
and raises one header alert — "Slipdock: 7 tidy-up suggestions on Ops" — with
the count per check and a link to the Tidy-up page. It applies nothing. Any
rule can do the same with the `garden` action.

From a terminal, over the API and over MCP:

```sh
slipdock garden ops                      # the open suggestions, grouped, with their fixes
slipdock garden ops --run                # look the board over first (--check K for one check)
slipdock garden apply 41 42              # apply; --choice snooze for an alternative
slipdock garden apply 43 --keep 12       # a duplicate: card 12 stays
slipdock garden dismiss 44
slipdock garden undo 41
slipdock garden settings ops                         # the checks and their settings
slipdock garden settings ops stale_in_progress days=21
```

```
GET   /api/boards/:board/garden[?check=K]       open suggestions, last run, checks
POST  /api/boards/:board/garden {check?}        look the board over now
PATCH /api/boards/:board/garden/settings {check, enabled?, days?, …}
POST  /api/garden/suggestions/:id/apply {keep?, choice?}
POST  /api/garden/suggestions/:id/dismiss
POST  /api/garden/suggestions/:id/undo
```

**A proposal is decided on the Tidy-up page.** A proposed handbook edit
(and any suggestion that edits a handbook section) is yours to decide, never
an agent's, so it is decided on the board's Tidy-up page (`/boards/<id>/tidy`),
signed in, and nowhere else. The CLI, REST and MCP are refused with the
page's link, whatever token, headers or `confirm` they send: an agent holding
your token can't present your browser session. `slipdock garden <board>` and
`slipdock findings <board>` give the page's link beside each proposal.

A suggestion carries `check`, `label`, `explanation`, `cards` and `pages`
(ids and titles), `proposal` (the steps: `complete`, `move`, `archive`,
`link_duplicate`, `flag`, `comment`, `snooze`, `redate`, `rewrite_link`,
`file_page`), `alternatives` (by name) and `needs_keep`. Over MCP, `garden`
lists them (`run: true` looks the board over first) and `garden_decide`
applies, dismisses or undoes one with `confirm: true` — an agent shows you the
suggestions and applies only what you approve.

---

← [Snoozing cards](snoozing-cards.md) · [Contents](../manual.md) · [Findings](findings.md) →
