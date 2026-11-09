[Slipdock — the manual](../manual.md)

## The ledger

"One human in the loop" needn't mean a person approves every card. Ten to
thirty merges a day is a list a person can read in ten minutes, if each line
carries its evidence. The ledger is that list: everything that shipped on a
board and the boards beneath it since a time, one line per card.

A card is on it when, in the window, it was **completed**, **accepted** (by a
verifier or a person), **merged** (a merge job finished, or a person said
*Merged it myself*) or **deployed** (a succeeded deploy named it, on a board
with [delivery metrics](delivery-metrics-deploys-and-dora.md)). It sits at its
latest such moment, under that day, newest day first. Each line says:

- what happened to it (`completed`, `accepted`, `merged`, `deployed`);
- who accepted it: a person, or an agent by its token's label or runner, or
  *not verified* on a board that doesn't verify work; and the last audit's
  verdict when it was audited (*audit agrees* or *disagrees*);
- the first line of its evidence, and the `should` rules its verifier marked
  broken (a broken `must` would have been a rejection);
- its pull request and the deploys that shipped it;
- where its time went: its lead time and the three biggest phases (build, CI,
  waiting for a person, verification…), and what its jobs spent (see
  [Its lead time and cost](flow-the-pulse-a-cards-state-and-its-age.md#its-lead-time-and-cost));
- on an epic, its subcards: how many are done of how many, and how many are
  on this ledger (they have lines of their own);
- **Look closer**, which opens the card's panel at its *Ask AI about this
  card* chat.

The window starts at 07:00 yesterday, in the board's timezone (its owner's),
unless you give one: a number of days back, a date (`2026-11-01`, from its
midnight) or an ISO 8601 time. The ledger reads only what the server already
keeps (completions, verification decisions, merge jobs, deploys) and writes
nothing: there is nothing to set up.

**The Ledger page.** Each board has one at `/boards/:id/ledger`, a tile
on the board's [Agentic Building](the-header-and-the-avatar-menu.md#agentic-building) page. Its **Since** box takes the same window, kept in the URL
(`?since=7`). Anyone who can read the board can look.

Each day opens with a heading that says how many cards shipped that day,
their median lead time, and one bar of where the day's time went. Each
card's line reads top to bottom: its title, then its number, time and what
happened to it (completed, accepted, merged, deployed), then the first line
of its evidence as a sentence, then a bar of its lead time with the total
beside it, then the details in two aligned columns: who verified it (and an
audit's verdict, or who a held card waits for), its profile and human tier,
the pull request, the merge and each deploy with its environment and short
SHA (linked to the commit when the pull request names the repository), an
epic's subcards, and any *should* rules it missed.

The bar splits the card's lead time into the phases
card chat's `card_lead_time` names. Work (build, CI, verify,
rework, merge, deploy) is solid; waiting (backlog, waiting for a runner, on
a person, for verification) is hatched, in the colour of what it waits for,
so time lost to waiting stands out. Hover over a piece, or tap it, for its
exact time and share. A bar's length is the lead time on a log scale from a
minute to 30 days, with faint marks at an hour, a day and a week, so a
ten-minute fix and a three-day feature both read on one page. The key above
the first day says which colour is which.

```sh
slipdock ledger slipdock                      # since 07:00 yesterday
slipdock ledger slipdock --since 7            # the last week; also a date or an ISO time
```

```
GET /api/boards/:board/ledger?since=   (since: days, a date or an ISO time; 07:00 yesterday by default)
```

Over MCP it is a view of `activity`: `activity` with `view: "ledger"` and an
optional `since`.

---

← [Findings](findings.md) · [Contents](../manual.md) · [The health monitor](the-health-monitor.md) →
