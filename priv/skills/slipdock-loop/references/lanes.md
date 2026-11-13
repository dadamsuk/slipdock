# Lanes

Part of the `slipdock-loop` skill: read when the board has lanes on or
advising and you write a card's paths yourself, a move or a paths edit is
refused over an overlap, or the prompt names a card whose paths overlap this
one's. `SKILL.md` has the short of it, which is enough for a job whose prompt
lists the card's paths.

## Lanes

Agents side by side in one repository can tread on each other's files: one
commit sweeps up another session's half-done change, or two take the same
migration number. Every part of this is optional and off unless the board
or the runner has it on; with none of it on, skip this section.

- **The board has lanes on** (its line in the guide says `lanes: on`, or
  `lanes: advise`).
  Before the claim's move into the doing list (step 4), write the paths the
  card's work will touch, as globs relative to the repository: `slipdock
  edit <id> --paths "lib/foo/**,test/foo/**,docs/manual.md"`. In a
  runner's `list_top` job the claim has moved the card in already (step 4),
  so paths you write now are checked as an in-progress card's paths edit:
  one that overlaps another card in progress is refused. Keep them as
  narrow as the brief allows. A glob is *broad* when it ends in `**` and
  sits at most one directory below the repository root (`lib/**`,
  `lib/slipdock/**`, `docs/**`, `test/**`), unless wholly inside a shared
  path: it overlaps most cards. Broad is advice, not a refusal:
  nothing is refused or held for it. But a glob marked broad in the job
  prompt's Paths block (or listed in `paths_broad` in `get_card` and
  `slipdock card`) is narrowed before starting, to the files or the
  deepest directory the change touches (you may change an in-progress
  card's paths). Declare the files the board shares too
  (`shared paths` on its line, such as the manual): they hold no lane, and
  the job's prompt names them. Others may edit them at the same time, so
  keep to your own sections and rebase before pushing. If the move is refused because they overlap a
  card in progress, the refusal names that card: don't widen around it.
  Narrow the paths if the work really is apart, or hand the card back as
  **Blocked** by that card (`slipdock blocked-by <id> <other>`), since the
  board unblocks it when the other card is done. Never move it in by some
  other route: only a person overrides a lane. A claimed job's prompt lists
  the card's paths. On a board that ships by push, a card awaiting
  verification frees its lane and stops blocking its dependents (its work
  is on the default branch), so the next card can start; a rejection takes
  both back, and the rework waits for an overlapping card in progress. On a
  pull request board a pending card keeps both until the merge: wait,
  don't build on its unmerged branch.
- **The board's lanes advise** (`lanes: advise` on its line). Nothing is
  refused or held: the claim's move goes ahead even when the paths overlap.
  The job's prompt then carries a *Lanes* block naming each card in
  progress whose paths overlap this card's, with the globs and the job on
  it. Before editing those files, read that card (`slipdock card <id>`) and
  its branch (`card-<id>`, if pushed); stay out of them where you can; and
  rebase on the default branch before pushing, expecting to merge.
- **Stage only the card's paths.** On a card with paths, `git add` the
  files under them by name, never `git add -A` or `.`, and check `git
  status` before committing. Anything else in the working tree is somebody
  else's. If the card truly needs a file outside them, widen the paths on
  the card first (`slipdock edit <id> --paths …`, and say why in a comment).
  The lane-check hook, if it is installed, refuses a commit that strays.
- **Another session in the same repository** (another pass, a runner, a
  person: `git status` shows changes you didn't make, or `git worktree
  list` shows others): work in a git worktree of your own unless the runner
  already put you in one (`$SLIPDOCK_WORKTREE` is set). `git worktree add
  ../<repo>-lanes/card-<id> -b card-<id>`, do the work and commit there,
  then rebase on the default branch and push (`git push origin
  HEAD:<default-branch>`). Remove the worktree when the card closes clean.
  Check the latest migration number in the default branch right before
  committing one.
