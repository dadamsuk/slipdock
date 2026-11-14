
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
