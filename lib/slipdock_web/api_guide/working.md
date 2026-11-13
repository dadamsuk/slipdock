
## Working a card

### Claim it, before the first edit anywhere else

Read the card's `handoff` first: where it was left, and the next step.

    POST  /api/cards/57/move        {"column": "In Progress"}
    PATCH /api/cards/57             {"assignee": "you@example.com"}
    POST  /api/cards/57/comments    {"body": "Starting. Plan: …"}

A card can have several people on it. `assignee` (or `assignees`, a list)
replaces whoever is there; to join a card somebody else already holds
without taking it off them, send `{"add_assignees": ["me"]}`, and
`remove_assignees` to step off. `"me"` is whoever the token belongs to.
Only somebody who can open the card can be put on it: share the board
with them first. Anybody else is the same `404 user …`, account or not.

Move the epic above it into its own `doing` list too, so the top of the
board reads true while you are inside the tree. `move` takes an optional
`index`: `"top"`, `"bottom"` (the default) or a number.

### While you work

- **Every decision, surprise or dead end → a comment.** In Markdown, for
  someone reading it in a month: a bold first line, then short bullets —
  what you chose, what you rejected, the commit or file — never one dense
  paragraph. The part people value, and the part agents skip.
- **A long job → say so while it is still running.** Anything that will
  take more than a short sitting — a big refactor, a migration, a build you
  are babysitting — gets interim comments at its milestones, not one
  write-up at the end: what has landed, what is left, whether the shape of
  it has changed. Move the number with it, so the board reads true without
  anyone opening the card:

      PATCH /api/cards/57             {"percent_complete": 40}
      POST  /api/cards/57/comments    {"body": "Parser done, codegen next; …"}

  A card sitting in `doing` for hours with nothing newer than the move on
  it looks abandoned.
- **A step done → tick it.** `POST /api/checklist/<item_id>/toggle`
  (item ids come from `GET /api/cards/<id>`). Add items as you discover
  them: `POST /api/cards/57/checklist {"text": "…"}`.
- **Stuck on another card:** add the dependency and the flag, and say what
  you are waiting for.

      POST  /api/cards/57/dependencies   {"blocked_by": 7}
      PATCH /api/cards/57                {"add_flags": ["blocked"]}
      POST  /api/cards/57/comments       {"body": "Waiting on #7: …"}

  Leave it in the `doing` list only if you are coming back to it this
  session; otherwise move it back to the ready list so it is not pretending
  to be in flight. When #7 is done the board takes the flag off by itself,
  with a comment, and the card is ready again.
- **Stuck on a person** — a decision, a credential, an approval: open a
  wait, `POST /api/cards/57/wait {"needs": "…"}` (MCP `update_card`
  `wait`), naming exactly what you need, and stop. The answer comes back.
  Several questions go as `{"questions": ["…", "…"]}`, one each, never
  one block: each gets its own numbered answer box.
- **Needs a human eye before it counts as done:** `{"add_flags": ["review"]}`
  and leave it in `doing`.
- **The task turns out to be several:** give it a sub-board and split it
  (`POST /api/cards/57/subboard {"template": "Simple"}`), rather than
  quietly doing three things under one title.
- **The estimate is slipping:** `POST /api/cards/57/status`
  `{"health": "at_risk", "body": "…"}`, and fix the `due_date` if you know
  the new one. Silence plus a late card is the worst outcome.
- `PATCH` takes `add_flags` / `remove_flags` and `add_tags` / `remove_tags`
  to adjust in place; plain `flags` or `tags` *replace* the whole set, which
  is how you accidentally drop someone else's flag.

### Finish it

Re-read the card before committing, and its comments once the build
starts: anything new is still this card. A done card's handoff is only
what the person must do or check; else `{"clear": true}`.

In a git repository, commit before closing: one commit (or PR) per card,
naming it (`#57`). Link the commit or PR in the closing comment (no
remote: the short hash and branch).

    POST  /api/cards/57/comments   {"body": "Done: <what changed, where, tests>\n\nCommit: <commit or PR URL>"}
    PATCH /api/cards/57            {"completed": true,
                                    "remove_flags": ["blocked", "waiting", "review"]}
    POST  /api/cards/57/move       {"column": "Done"}

Tick or remove any checklist items left over — a card marked done over an
unticked list is a lie someone has to investigate. `completed` and the
`done` list are two separate facts and you set both: the list is where
people look, the flag is what filters, rollups and reports count.

### Finish the epic

An epic spanning several sittings gets its own progress comment as each
subcard closes — one line on what that subcard delivered and what is next —
so the outcome has a readable history without anyone reading every subcard.

Only when its subcards really are all done (`rollup.done == rollup.total`,
`rollup.blocked == false`): comment what the epic delivered, mark it
`completed` and move it to `done`. Else leave it in `doing` and take the
next subcard. An agent closing it over open (not done, not archived)
subcards is refused, 422, naming them.

### Ending a session mid-card

Leave a handoff whenever you stop with the card unfinished: the one next
step and a short note (State, Gotchas, Open, Pointers).

    POST  /api/cards/57/handoff  {"next_step": "…", "body": "State: …"}

Then leave it in `doing` if you are coming straight back, else move it
back to the ready list. Never leave a card in `doing` with no comment
newer than the move — nobody can tell whether it is alive.

### What not to do

- **Do not `DELETE` cards.** `POST /api/cards/<id>/archive` is reversible
  (`/restore`); delete is not. Delete only what you created by mistake in
  the same session, or what you were explicitly asked to delete. The same
  goes for `DELETE …/subboard`, which takes every subcard with it.
- **Do not delete a list to tidy a board.** `DELETE /api/boards/:board/columns/:id`
  only removes an empty list: one that still holds cards, archived ones
  included, is refused with 409 `list_not_empty` and a count. Move the cards
  elsewhere first. `DELETE /api/boards/:board/columns/:id/recursive`
  deletes the list and every card in it, subcards too, and cannot be
  undone: use it only when the person asked for exactly that.
- **Do not complete an epic with open subcards, or reopen a done card**;
  never move a card to `done` without `completed: true` (or the reverse).
- **Do not rewrite a card's title or description to match what you actually
  did.** If the scope changed, say so in a comment and let the person
  decide; the title is their record of what they asked for.
- **Do not tidy.** Reordering lists, renaming things, re-prioritising other
  people's cards, archiving stale cards — all reasonable, none of it yours
  to do unasked. Archiving or reordering a whole *board* is further still
  from your business: do it only when you were asked to, by name.
- **Do not touch boards you were not asked about**, even when a search turns
  them up.
- **Do not work the “Getting Started” board.** It is the tour this server
  builds for a new account, and its cards are instructions for a person —
  "drag this card to Done", "open a card and look down the side". Doing
  them teaches nobody anything and finishing them is a lie about what you
  did. If you were pointed at it by mistake, say so and ask which board was
  meant. `POST /api/boards/welcome` builds a fresh one.
