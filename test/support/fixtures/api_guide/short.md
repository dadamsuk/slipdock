# Slipdock for agents

This is how to drive `https://slipdock.example.com` as your work tracker: the model, the
conventions these boards expect, how to decide what to do next, and what to
write back while you do it. Read it at the start of a session. The board is
what the person who owns it reads afterwards to find out what happened, so
treat keeping it true as part of the work, not as reporting overhead.

Three things, if you remember nothing else:

1. **Top-level cards are epics; the work is in their subcards.** Finish an
   epic's subcards before starting the next epic.
2. **Take work from the top.** The *To Do* list first, the *Backlog* only
   when To Do has nothing eligible; highest priority first, position in the
   list breaking ties; skip anything blocked.
3. **Write as you go.** Move a card to *In Progress* when you start it,
   comment at every decision or surprise, flag it when you are stuck, and on
   finishing set `completed: true` *and* move it to *Done*. A board that
   lags behind the work is worse than no board.



## Over MCP

A client that speaks the Model Context Protocol can use this server as an
MCP server at `https://slipdock.example.com/mcp`: stateless Streamable HTTP, authenticated with
the same bearer token as the API, or by signing in through the browser
(OAuth 2.1 with dynamic client registration and PKCE — the way claude.ai
and the Claude apps connect; discovery starts from the `401` that `/mcp`
answers without a token). It offers a small set of tools rather
than the whole API: `whoami`, `get_guide` (this text, short; `section` for the
rest), `list_boards`,
`get_board`, `list_cards` (`full: true`: every card as `get_card`
gives it, so a whole board reads in one call), `get_card`, `search`, `ask` (a
model call, so slower), `read_page`, `list_pages`, `page_info`, `page_history`, `activity` (a
board's log, or one card's), `download_file` (a file, by
attachment id; `link: true`, a URL to curl), `list_automations`, and for
writing `create_card`, `update_card` (fields, flags, tags, assignees,
dependencies, the checklist, recurrence, snooze), `move_card` (to another board too),
`comment`, `leave_handoff`, `upload_file` (onto a card or page;
a shell: `link: true`), `complete_card`, `status_update` (a card's stated health, with
a note: the progress report on an epic),
`archive_card` (and restore), `delete_card`,
`create_list`, `create_tag`, `delete_list`, `create_board`, `archive_board` (and
restore), `delete_board`, `write_page`, `update_page` (a page's
title, summary, parent, position and folder, archiving and restoring it,
and pinning it to a card) and `revert_page` (a page
back to a revision, as a new one, against `base_hash`),
`manage_automation` (owner only), `list_tools`, `install_tool`, `garden` and
`garden_decide` (tidy-up suggestions), and `claim_job`,
`job_progress` and `finish_job` to take runner jobs from a board's
queue (see "Runners" below), and `release_now` (Release now on a board
with batched releases; `check: true` only reads). Archiving can be undone; the
deletes can't, so `delete_card`
needs `confirm: true`, `delete_board` needs `confirm` set to the board's
code, and `delete_list` refuses a list holding cards unless
`with_cards: true`. A read-only
token, or a connection the person approved read-only, can call the read
tools, and a write tool answers it with an error saying so. The conventions in this guide apply the same way through
either door. Prompts: `plan-my-day`, `weekly-review`, `triage`, `resume`,
`leave-handoff`, `tidy-board`. Resources, which the
person attaches: `slipdock://card/42`, `board/`, `page/`, `view/`, `work`.


## Epics and subcards

The shape these boards want:

```
Board "Slipdock app"                        a project, or a stream of work
└── Card "Search"                         EPIC: an outcome, top level
    └── sub-board "Search"                the epic's own lists
        ├── Card "Index cards on write"   TASK: one sitting, one agent
        ├── Card "Query parser"
        └── Card "Search box in the header"
            └── checklist: empty state, keyboard shortcut   trivia
```

- An **epic** is a top-level card on a root board. It names an outcome, not
  an action — "Search", not "add an index". It holds the priority, the due
  date, the tags and the discussion for everything under it, and it is never
  worked directly: its job is to hold subcards.
- A **task** is a subcard: something one agent can finish in one go and
  describe in a sentence. Tasks carry their own position, priority, flags,
  comments and completion. This is what you actually do.
- A **checklist item** is a step inside a task that is not worth a card of
  its own. If it needs a date, a comment or a status, promote it to a
  subcard instead.
- Two levels (epic → task) is the norm. Three means the epic is really a
  programme, which is fine — sub-boards nest as deep as you like. Four
  usually means the tree is being used as a to-do list and wants flattening.

**Card shape.** How a one-sentence ask becomes a card, the same way
whichever agent writes it:

- **One card** when the ask fits one sitting, one agent and one PR and
  was said in a sentence; an epic with subcards only when it doesn't.
  Never an epic with one subcard, nor subcards the person didn't imply.
- **Where:** under the epic it serves if there is one (search first);
  otherwise top level, without making an epic to hold it.
- **Three things in the description**, each in proportion: what, in the
  person's words; where, if known; and a **done-when** line, the stop
  condition the evidence answers. One or two lines; no Given/When/Then
  unless the board's Playbook asks for it.
- **Don't add** an estimate, priority, tags, a due date or an assignee
  unless the person said so or the board's convention does.
- **Don't repeat the repo's rules** (tests, every door, the handbook
  line): whoever builds it reads those from the handbook and the repo.
- **Two readings:** write the obvious one and note the other in the
  description; ask only when they differ materially, once, before filing.
- **A bar item made moot** by a later, cited decision or rule: read it
  the obvious way and say so. Not a wait.
- **Dependencies:** `blocked_by` means *can't start until*, not *should
  come after*: set it where a card builds on another's code, schema or
  decision, and use list position for mere preference. A one-card ask
  gets none unless the person said "after X". None on a simple board.

A board's handbook can override these: the `## Card shape` section of
its Playbook page wins wherever it says otherwise.

Give an epic its subcards, then fill them:

    POST /api/cards/42/subboard        {"template": "Simple"}
    POST /api/boards/9/cards           {"title": "Query parser", "column": "To Do"}

A new board takes its lists from `template`, or sets its own out with
`POST /api/boards {"name": "Hiring", "columns": ["Applied", "Interview",
"Done"], "save_template": "Hiring"}` — names like To Do, In Progress and
Done get those roles, and `save_template` (a name, or `true` for the
board's) keeps the lists as a new template in the same request.

`GET /api/templates` lists the named sets of lists a new sub-board can be
built from: the built-ins (`"system": true`, read-only to all: 403) and
your own. The response to `POST …/subboard` includes the new board, whose
`id` is what you add cards to. `DELETE /api/cards/42/subboard` removes the
sub-board **and every card on it**, so treat it as a delete.

**Stand-ins.** A card whose `stand_in_for` is set marks where a card
went into a sprint. It is not work: do not pick it up, edit it or count
it, act on the card it names. Sprints are their own section
(`sprints`).

**Simple boards.** A board with `"simple": true` is a plain to-do list
(`PATCH /api/boards/:board {"simple": true}`, `slipdock set-board B
--simple`; a new sub-board takes it from its parent). The web app hides
% complete, start dates, health, time tracking, votes and dependencies
on its cards, and leaves Timeline and Prioritise out of its views; a
board's JSON lists the hidden card fields as `hidden_facets`, which no
person's card views bring back. The API
still reads and writes all of them — nothing is deleted — but on a
simple board, keep to what the person can see: do not set `--percent`,
start dates, estimates or dependencies there unless asked to.


Tags live on the root board, shared by the whole tree. A tag must exist
before a card can wear it (`POST /api/boards/:board/tags`, `slipdock new-tag`,
or the MCP tool `create_tag`), and only a writer of the root makes one. Renaming an epic renames
its sub-board (a board name is at most 80 characters, so a longer title is
cut short with an ellipsis).

**Where new work goes.** Work you discover mid-task belongs under the epic
it serves, as a subcard — not as a new top-level card, and not silently
folded into the card you are on. Open a new epic only for a genuinely new
outcome, and give it a sub-board immediately so it cannot become a task in
disguise. If the new work blocks what you are doing, add the dependency
(`POST /api/cards/:id/dependencies {"blocked_by": <new id>}`) rather than
just leaving a comment about it.



## Choosing what to do next

Depth first, from the top. Unless the person told you which card to work
on, this is how to pick one.

**1. Pick the board.** `GET /api/boards`. If more than one could plausibly
be meant, ask instead of guessing.

**2. Read it whole.** `GET /api/boards/<id>` returns every list, in order,
with its `category` and its cards in list order — one call, everything you
need to choose. Snoozed cards are not in it: they are not ready until the
day they wake. If `paused` is set, take nothing and stop.

**3. Pick the list to draw from,** in this order:

a. a `doing` list that already holds an unfinished card — work in progress
   is finished before new work is started;
b. the **ready** list: the `todo` list that means "ready now" (*To Do*,
   *Now*, *Ready*, *Selected*, *Next*);
c. the **backlog**: any other `todo` list (*Backlog*, *Later*, *Icebox*),
   and only when (b) has nothing eligible.

Ignore `done` and `dropped` lists. A board with one `todo` list makes this
trivial. Older boards often carry no categories at all — then go by name and
position, left to right; the last section of this guide has already worked
that out for each of your boards. Ask if it is genuinely unclear.

**4. Drop the ineligible.** From that list's cards, discard any where:

- `completed` is true, or `archived_at` is set;
- `blocked` is true, or any `blocked_by` entry is neither `completed` nor
  `archived` — the thing it waits for is still open;
- `flags` contain `blocked` or `waiting` — somebody has said by hand that
  this is not ready;
- `assignees` has someone else on it, unless you were asked to pick their
  work up — or to pair on it.

**5. Order what is left.** Highest priority first
(`critical > high > medium > low > none`), then `position`
ascending — the top of the list wins a tie, because that is where the person
who owns the board put the next thing. Two exceptions worth respecting: a
card already overdue (`due_date` today or past) outranks priority, and a
card that `blocks` several others is worth doing before its peers.

**6. Descend before you move on.** If the card you picked has a `sub_board`,
it is an epic: `GET /api/boards/<sub_board.id>` and run steps 3–6 again
inside it. Keep descending until you reach a card with `sub_board: null` —
that leaf is the task you actually do. Then work *that epic's* remaining
subcards to done before going back up for the next top-level card. An epic
with no sub-board and no obvious single action is a sign it needs breaking
up (see above), not a sign to improvise.

**7. Nothing eligible?** Say so, and say why — everything done, everything
blocked on X, the backlog is empty — and stop. Do not invent work, and do
not take a card you ruled out in step 4 because it was the only one left.

A first pass in one call, with the obvious exclusions applied:

```sh
curl -s -H "Authorization: Bearer $SLIPDOCK_TOKEN" https://slipdock.example.com/api/boards/1 | jq '
  [ .board.columns[]
    | select(.category == "doing" or .category == "todo")
    | {list: .name, category, position,
       cards: [ .cards[]
         | select(.completed == false and .blocked == false
                  and (.flags | index("blocked")) == null
                  and (.flags | index("waiting")) == null)
         | {id, title, priority, position, due: .due_date,
            epic: (.sub_board.id // null)} ] } ]'
```

Order the handful that come back yourself — it is a short list and the
tie-breaks above need judgement.



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

- **Every decision, surprise or dead end → a comment.** In Markdown, like
  every field you write (bar, evidence, a question):
  a bold first line, then short bullets — what you chose, what you
  rejected, the commit or file — never one dense
  paragraph. A question lists its options and recommends one (see
  *Recipes*).
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



## Your boards

Not shown: this request carried no token. Re-read the guide with one and
this section lists the boards you can see, every list on them, and which
list is the ready list, the backlog, the one in progress and the one for
done work.

## The rest of the guide

Each section below is one call away: `get_guide` with `section` set to
its name, or `GET /api/guide?section=<name>` (`all`, or the plain URL,
is the whole guide):

- `getting-in` — Getting in
- `model` — The model
- `sprints` — Sprints
- `finding` — Finding something nobody can name
- `recipes` — Recipes
- `automations` — Automations and alerts
- `runners` — Runners
- `health` — Health monitor
- `deployments` — Deployments
- `wiki` — The wiki: writing things down
- `skills` — Skills
- `handbook` — The handbook
- `findings` — Findings
- `moving` — Moving boards between servers
- `vocabulary` — Vocabulary
- `endpoints` — Every endpoint
