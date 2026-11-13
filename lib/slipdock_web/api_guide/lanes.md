
## Lanes

Some of your boards keep agents working side by side out of each
other's files (`lanes: on` on the board's line). Before moving a card
into an in-progress list, write the paths its work will touch on the
card's `paths`: globs relative to the repository, like
`lib/slipdock/runners/**` or `docs/{manual,agents}.md`
(`PATCH /api/cards/:id {"paths": ["…"]}`, `update_card` `paths`,
`slipdock edit ID --paths "a/**,b.md"`; or `paths` when making it:
`create_card`, `slipdock add --paths`). Moving it in is refused
(`422`, naming the card in the way) while its paths overlap an open
card in progress on the board's tree that a runner job is working on
(a job queued, claimed or running on it or its epic; a card in
progress with no open job holds no lane), the card's own subcards and
parents aside, and so are creating one straight into an
in-progress list and widening an in-progress card's paths onto
another's. An epic's lane is its subcards': in progress it holds none
of its own, and it waits only when none of the subcards it could take
could start. Narrow the paths, take other work, or ask a person: a
person moving the card overrides it. A runner job for such a card is
held (`Lane: overlaps #N, in progress`) until the other card is done,
and a claimed job's prompt lists the card's paths. Verify and merge
jobs are never held, by lanes or the WIP limit: they finish work. On a board that
verifies work and ships by push, a card awaiting verification has
shipped: it frees its lane and no longer blocks the cards that depend
on it (a dependency stub says `released: true`), until a rejection
sends it back for rework. On a board that ships by pull request it
keeps both until the merge. Stage only files
under them; with several sessions in one repository, work in a git
worktree of your own.

**Shared paths.** A board's `shared_paths` (`shared paths` on its
line; `PATCH /api/boards/:id {"shared_paths": ["docs/manual.md"]}`,
`update_board` `shared_paths`, `slipdock set-board B --shared-paths
"docs/manual.md,README.md"`; `[]` or `""` clears) are globs that never
count toward a lane: a card's path wholly inside one is left out on
both sides, so an overlap only there holds nobody, while one anywhere
else still does. A path only partly inside one (`docs/**` when
`docs/manual.md` is shared) counts in full. Declare the shared files
you edit honestly: a card's JSON names the board's `shared_paths` and
its own `paths_shared`, the job's prompt lists them, and the
lane-check hook lets a staged file under one through. Others may be
editing them too: keep to your own sections, and rebase on the
default branch before pushing.

**Advisory lanes.** A board's `lane_mode` is `off`, `hold` (all of
the above; `lanes: true` means it) or `advise` (`lanes: advise` on its
line; `PATCH /api/boards/:id {"lane_mode": "advise"}`, `update_board`
`lane_mode`, `slipdock set-board B --lane-mode advise`). Under
`advise` nothing is refused or held: you start the card, and a
claimed job's prompt carries a *Lanes* block naming each card in
progress whose paths overlap yours, the globs, and the job and
runner on it. Before editing those files read that card (`slipdock
card <id>`) and its branch (`card-<id>`, if pushed), stay out of
them where you can, and rebase on the default branch before pushing.
A card's JSON says the overlap as `lane_overlap` (`{card, title,
mode}`). `lanes: true/false` keeps working and means `hold`/`off`.

**Broad paths.** Keep `paths` as narrow as the change: a `**` glob at
most one directory below the repository root (`lib/**`,
`lib/slipdock/**`, `cli/lib/**`, `docs/**`, `test/**`), unless it is
wholly inside a shared path, is *broad*: it overlaps most cards. It
is advice, not a refusal: nothing is refused or held for it. A
card's JSON lists them as `paths_broad` (with `paths_broad_reason`),
`slipdock card` and the card's *Paths* field mark them, a claimed
job's prompt says so beside the glob, and a `lane_overlap` a broad
glob makes says whose it is (`broad`: `this`, `other` or `both`;
`broad_paths`, the globs). Narrow it to the files or the deepest
directory the change touches before you start: you may change an
in-progress card's paths.
