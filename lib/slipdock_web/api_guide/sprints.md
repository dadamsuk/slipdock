
## Sprints

A board whose `kind` is `"sprints"` (made from the "Sprint
planning" template, or `PATCH /api/boards/:board {"kind": "sprints"}`) has
a sprint on every card, and the sprint's work as its subcards. `POST
/api/boards/:board/sprints` makes the next one — `name`, `start`, `days`
and `goal` all optional; it counts on from the last "Sprint N" and starts
the day after it ends — with its sub-board already there.
`POST /api/cards/:sprint/sprint {"cards": [41, 42]}` moves cards from any
board you can write to into it, subcards and all, and answers what it
`added` and what it `skipped` and why. Only plan a sprint when asked to:
moving cards out of their epics is the person's call.
Each card added leaves a **stand-in** where it was: a card whose
`stand_in_for` is `{"id", "title", "board_id", "status"}` — the real card,
and `status` from its list's category (`todo`, `doing`, `done`,
`dropped`, or `archived` / `deleted`). It is not work: do not pick it up,
edit it (a `PATCH` is refused) or count it — act on the card it names.
It goes by itself when that card is moved back to its board.
A sprint board keeps the boards and lists its sprints are planned from:
`PUT /api/boards/:board/sprints/sources {"sources": [{"board": "work",
"lists": ["To Do", "Backlog"]}]}` (no `lists` means every list that is
not done or dropped; `[]` clears them), read back with `GET` on the same
path and as the board's `sprint_sources`. `GET
/api/cards/:sprint/sprint/plan` is the planning view over them: every
source list's open cards with `priority`, the board's formula `scores`
(RICE and the like), `votes`, `estimate_minutes` (the card's own, else its
open subcards' — `estimate_from_subcards`) and `subcards` done/total,
plus what the sprint holds already under `committed`; `?sort=` is
`position`, `score`, `priority` or `estimate`. Read it before proposing
what goes in a sprint, and add the estimates up from it rather than
guessing.
`GET /api/cards/:sprint/burndown` is how much of a sprint's work was open
at the end of each day against the ideal line, and `GET
/api/boards/:board/sprints/velocity` is committed and completed per sprint
with the average of the finished ones — read them when asked how a sprint
is going rather than counting cards yourself. Every card carries
`completed_at`, the moment it was last completed.
