[Slipdock — the manual](../manual.md)

## Lanes

Agents working side by side on one repository can tread on each other's
files: one sweeps another's half-done change into its commit, or two take
the same migration number. Lanes keep them apart, in parts that are
each optional and off by default. With none of it on, nothing changes.

**Paths on a card.** A card can say which files its work will touch, as
globs relative to the repository, one per line in the card's *Paths* field
(`slipdock edit 12 --paths "lib/slipdock/runners/**,docs/manual.md"`,
`update_card` `paths`, `PATCH /api/cards/:id {"paths": [...]}`; `""` or
`[]` clears them). `*` and `?` stay within one folder, `**` is any number
of folders, `{a,b}` is either, and a path covers everything under it
(`lib/foo` covers `lib/foo/bar.ex`). Paths are at most 50, each at most 200
characters, relative, and without `..`. They are shown on the card and in
`slipdock card`, and a claimed runner job's prompt lists them.

**The board switch.** With *Lanes* on, on the board's [Agentic Building](the-header-and-the-avatar-menu.md#agentic-building) page (`slipdock
set-board slipdock --lanes`, `update_board` `lanes`, `PATCH /api/boards/:id
{"lanes": true}`; sub-boards made afterwards inherit it, and the root
board's switch holds for its whole tree), an agent can't start a card whose
paths overlap those of an open card in progress anywhere on the tree that
a runner job is working on: moving it into an in-progress list is refused
with the other card named, and so are creating one straight into an in-progress list and
widening an in-progress card's paths onto another's. The
card's own subcards and parents don't count against it, and a card with no
paths overlaps nothing. **An epic's lane is its subcards'**: an epic (a card
whose sub-board has cards) in progress holds no lane of its own, since the
subcards being built in it hold theirs, and an epic waits only when none of
the subcards its pass could take (open, not submitted, not blocked or
flagged) could start, each checked on its own paths. An epic with none left
to take is checked on its own paths. **Only a card being worked holds a
lane** (#1922): one with a runner job open on it (queued, claimed or
running, a verify or merge job still to finish included), or a subcard of
an epic whose job is open. A card in progress with nothing working on it,
dragged there by hand or left behind by a job that ended, holds no lane;
the health monitor's *orphan in progress* and the gardener's *stale in
progress* checks report it instead. **A spike holds no lane** (a card
profiled or tagged `spike`): its code is never merged, so an overlapping
card starts beside it and no job waits for it. A person working a card by hand
doesn't hold runners off its files either: give the card a job of its own,
or pause the board's runners. A runner job for such a card waits, held as
*Lane: overlaps #N, in progress*, and the next job is taken instead. A
*Work a list with a runner* rule (`list_top`) passes over a card its lane
would hold and sends the next one that could start; if the job it already
sent is still queued and held, it withdraws that job (the card is told
why) and sends the next card instead, so one card with broad paths doesn't
leave every pool idle. The held card keeps its place in the list and goes
once its lane frees. Only
work waits: a job that verifies or merges a card edits nobody's files, so
neither lanes nor the board's WIP limit hold one. People
are never refused: moving the card yourself is the override, and the card's
*Paths* field says what it overlaps. The server only compares globs: it
never sees a working tree.

**Shared paths.** Some files nearly every card edits: the manual, the API
guide, the README. Declared honestly, they make every card overlap every
other, and lanes would let one agent work at a time. A board's *Shared
paths* (in its settings under *Lanes*, one glob per line; `slipdock
set-board slipdock --shared-paths "docs/manual.md,README.md"`, `""` clears
them; `update_board` `shared_paths`; `PATCH /api/boards/:id
{"shared_paths": [...]}`) are globs that never count toward a lane. A
card's path wholly inside one is left out on both sides before the overlap
is checked, so two cards whose only overlap is the manual don't hold each
other, while an overlap anywhere else still does. A card's path only partly
inside one counts in full: `docs/**` still counts when only
`docs/manual.md` is shared. The root board's list holds for its whole
tree, and sub-boards made afterwards inherit it. Empty by default, which
changes nothing. The card's *Paths* field and `slipdock card` mark a path
that is shared, `slipdock board` and `get_board` list them, a runner job's
prompt names the card's shared paths and asks the agent to keep to its own
sections and rebase before pushing, and the lane-check hook lets a staged
file under one through. Edits to them are expected to merge cleanly; keep
the expensive collisions (migrations, a schema, a module being refactored)
out of the list.

**Advisory lanes.** A board's *Lanes* setting is one of three modes: *Off*,
*Hold* (all of the above: an agent's overlapping start is refused and its
job held) and *Advise*. Under *Advise* nothing is refused or held: an agent
starts the card, and a claimed job's prompt carries a *Lanes* block naming
each open card in progress whose paths overlap this card's (shared paths
left out), the globs that meet, the job and runner working it, and what to
do: read that card and its branch before editing those files, stay out of
them where you can, and rebase on the default branch before pushing. No
overlap, no block. The card's *Paths* field and `slipdock card` say
*overlaps #N in progress, advisory*; no job waits on a lane, so `slipdock
jobs` shows none held and the health monitor's *lane held* check has
nothing to find. Set it on the board's [Agentic Building](the-header-and-the-avatar-menu.md#agentic-building) page, with `slipdock set-board
slipdock --lane-mode advise` (`off`, `hold`, `advise`), `update_board`
`lane_mode` or `PATCH /api/boards/:id {"lane_mode": "advise"}`; sub-boards
made afterwards inherit it, and the root's mode holds for its tree. The
`lanes` switch still works everywhere: `true` is *Hold* and `false` is
*Off*, and the board's JSON says both. *Hold* stays the safer choice for
work whose collisions are costly to find at merge time (migrations, a
schema, a module being refactored); *Advise* suits a board whose cards
mostly meet in files a merge resolves.

**Broad paths.** A glob that claims a whole top-level directory, or one
just below it, overlaps nearly every other card: under *Hold* one such
card idles every runner, and under *Advise* it is noise in every job's
prompt. So a path whose last segment is `**` and that sits at most one
directory below the repository root (`lib/**`, `lib/slipdock/**`,
`cli/lib/**`, `docs/**`, `test/**`) is marked *broad*, unless it is wholly
inside one of the board's shared paths. It is advice, not a refusal:
nothing is refused or held for it. The card's *Paths* field and `slipdock
card` mark the glob *broad* with the reason (it overlaps most cards; name
the files or the deepest directory the change touches), a claimed job's
prompt says the same beside the glob, so the agent narrows it before
starting (an agent may change an in-progress card's paths), and the card's
JSON lists them as `paths_broad` (with `paths_broad_reason`). A
`lane_overlap` that a broad glob makes says whose it is: `broad` is
`this`, `other` or `both`, and `broad_paths` the globs.

**Cards awaiting verification.** On a board that verifies work and ships
by **push**, a card an agent has submitted has its work on the default
branch already, and nobody is editing its files. While it waits for
verification it frees its lane (its paths stop counting as in progress, and
a runner job its lane held goes), and it counts as finished for the cards
that depend on it: they lose the *blocked* flag, run their *card unblocked*
rules, and show as ready (a dependency in the API says `released: true`;
`slipdock card` shows it as *pending verification, shipped*). A rejection
brings both back: the card goes to the top of the ready list, and moving it
in to rework it takes its lane again, waiting for any overlapping card in
progress as lanes do. On a board that ships by **pull request**, a pending
card's changes are on an unmerged branch, so it keeps its lane and keeps
blocking its dependents until it is accepted and merged.

**A worktree per runner job.** See *A worktree per job* under
[Runners](runners.md): each job in a git worktree of its own, on a branch
named for its card.

**The lane-check hook.** `slipdock hook install lane-check`, run in the
repository, installs a git `pre-commit` hook (in the hooks folder every
worktree of the repository shares; it won't replace a hook of your own).
Before each commit it runs `slipdock lane-check`, which finds the card
being worked — `--card ID`, else `$SLIPDOCK_CARD` (a runner job sets it),
else a branch named `card-<id>` (the worktree runner's branches) — reads
its paths, and refuses a commit that stages files outside them, listing
the files; both sides of a rename count. A file under one of the board's
shared paths goes through whether or not the card declares it, and the
hook says it let it through as shared. A card with no paths, or no card,
passes. It never blocks on the network: a board it can't reach, or one
that doesn't answer in five seconds, gets a warning and the commit goes
ahead, as it does if `slipdock` isn't on the hook's PATH. `git commit
--no-verify` skips it for one commit; `slipdock hook uninstall lane-check`
removes it.

---

← [Verified work](verified-work.md) · [Contents](../manual.md) · [Profiles](profiles.md) →
