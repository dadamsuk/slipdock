
## Recipes

With `H='Authorization: Bearer '$SLIPDOCK_TOKEN` and `<%= @base %>` as the base:

```sh
# who am I, what can I see
curl -s -H "$H" B/api/me
curl -s -H "$H" B/api/boards
curl -s -H "$H" "B/api/boards?archived=all"   # archived boards too (see below)

# a whole board: lists, categories, cards in order
curl -s -H "$H" B/api/boards/1

# one card in full (checklist item ids, comments, deps, rollup)
curl -s -H "$H" B/api/cards/57

# filtered cards: open work in one list, by priority, by flag, by text
curl -s -H "$H" "B/api/boards/1/cards?completed=false&column=To%20Do"
curl -s -H "$H" "B/api/boards/1/cards?priority=high&flag=blocked&q=search"

# by date, by dependency, by person: due=overdue|today|week|month|has|none,
# deps=blocked|ready|blocking|violated|free, assignee=EMAIL|NAME|me|none
curl -s -H "$H" "B/api/boards/1/cards?due=overdue"
curl -s -H "$H" "B/api/boards/1/cards?deps=blocked&assignee=me"

# by what it is: kind=card|document (a card that is just the file on it)
curl -s -H "$H" "B/api/boards/1/cards?kind=document"

# archived cards are left out: archived=true for them alone, archived=all for both
curl -s -H "$H" "B/api/boards/1/cards?archived=all"

# create an epic, give it subcards, add a task
curl -s -H "$H" -H 'content-type: application/json' B/api/boards/1/cards \
     -d '{"title": "Search", "column": "To Do", "priority": "high", "tags": ["api"]}'
curl -s -H "$H" -H 'content-type: application/json' B/api/cards/42/subboard \
     -d '{"template": "Simple"}'
curl -s -H "$H" -H 'content-type: application/json' B/api/boards/9/cards \
     -d '{"title": "Query parser", "column": "To Do", "due_date": "2026-10-03"}'

# record something already finished with: "archived": true (or "true") files it
# away at once. A field a new card doesn't take, a typo like "archved", is a 422
# naming it, and no card is made
curl -s -H "$H" -H 'content-type: application/json' B/api/boards/1/cards \
     -d '{"title": "Old release notes", "archived": true}'

# claim, comment, tick, finish
curl -s -H "$H" -H 'content-type: application/json' B/api/cards/57/move \
     -d '{"column": "In Progress"}'
curl -s -H "$H" -H 'content-type: application/json' B/api/cards/57/comments \
     -d '{"body": "Parser handles quoted phrases; see lib/slipdock/search.ex"}'
curl -s -X POST -H "$H" B/api/checklist/11/toggle
# reorder its checklist: item 13 before item 11 ({} or "before": null puts it
# last); answers the checklist in its new order. A before from another card
# or page is a 404 (CLI: slipdock move-check 13 --before 11)
curl -s -H "$H" -H 'content-type: application/json' B/api/checklist/13/move \
     -d '{"before": 11}'
curl -s -X PATCH -H "$H" -H 'content-type: application/json' B/api/cards/57 \
     -d '{"completed": true, "remove_flags": ["blocked"]}'

# what happened on this board lately
curl -s -H "$H" "B/api/boards/1/activity?limit=20"

# its flow numbers: in progress, waiting, done this week, time to done,
# moves forward and back, each list's in/out (MCP: get_board pulse: true)
curl -s -H "$H" B/api/boards/1/pulse

# its flow day by day over 7, 30 or 90 days, and how its runners are doing
# (MCP: get_board history: true / runners: true)
curl -s -H "$H" "B/api/boards/1/flow?days=30"
curl -s -H "$H" B/api/boards/1/runner_stats

# how well agent work goes over ?days= (30 unless given; CLI: slipdock
# quality): verified.first_time_right of verified.accepted (accepted with
# no rejection and never reopened), rejections per accepted card, areas
# (each card under the handbook page covering most of its lane paths, or
# "unmapped"), jobs (timeouts, failed, requeues, gave_up, each per_100
# finished jobs) and health (incidents fixed, flagged, cleared, open);
# previous is the window before's verified numbers. rejections counts the
# verifiers' rejections in parts: by_part (ask, bar, rules, suite,
# handbook_line, mutants), by_rule (id, count, severity and page, most broken
# first), disputed_lines and unparted (naming no part); audits counts
# audits agreed and disagreed. slipdock quality --rules lists every rule
curl -s -H "$H" "B/api/boards/1/quality?days=30"

# the ledger: what shipped on the tree since ?since= (days, a date or an
# ISO time; 07:00 yesterday in the board's timezone by default), by day:
# each card completed, accepted, merged or deployed, with accepted_by
# (person or agent), audit, the evidence's first line, should_broken
# rules, pr, deploys, lead_time phases and cost (model_seconds,
# tool_seconds, jobs, and tokens only when a log carried usage), an
# epic's subcards and the card's
# url (its panel, at the chat). CLI: slipdock ledger <board> [--since S];
# MCP: activity view: "ledger"
curl -s -H "$H" "B/api/boards/1/ledger?since=1"

# cards past their list's usual stay, and who holds them (driver=all|agent|human)
curl -s -H "$H" "B/api/boards/1/cards?stuck=true&driver=agent"

# cards a generator filed (origin=person|sweep|findings|…|agent|none)
curl -s -H "$H" "B/api/boards/1/cards?origin=sweep"

# waiting on a person: open a wait, answer it (text, a choice from 1, or both),
# withdraw it (MCP: update_card wait / answer_wait; CLI: slipdock wait, answer)
curl -s -H "$H" -H 'content-type: application/json' B/api/cards/57/wait      -d '{"needs": "Which region?", "on": "dana@example.com", "choices": ["eu", "us"]}'
curl -s -H "$H" -H 'content-type: application/json' B/api/cards/57/wait/answer      -d '{"choice": 1, "answer": "eu, for the data rules"}'
curl -s -X DELETE -H "$H" B/api/cards/57/wait

# several questions at once, numbered (CLI: slipdock wait 57 --question … --question …);
# answered one per question ("" leaves one), or skipped; then every one the card asked
curl -s -H "$H" -H 'content-type: application/json' B/api/cards/57/wait      -d '{"questions": ["Which region?", "How many seats?"]}'
curl -s -H "$H" -H 'content-type: application/json' B/api/cards/57/wait/answer      -d '{"answers": ["eu", "12"]}'
curl -s -H "$H" -H 'content-type: application/json' B/api/cards/57/wait/answer      -d '{"skip": true}'
curl -s -H "$H" B/api/cards/57/waits

# who gets asked (#1949): give a wait its question kind (product, ux,
# security, release, other; other by default) and leave "on" out: it goes
# to the first person the board routes that kind to (the rest are told),
# else the owner. The owner sets wait_routes, each a list of the board's
# users ([] takes one off). CLI: slipdock wait 57 "…" --kind product;
# slipdock set-board 1 --route product=dana@example.com --no-route ux.
# MCP: update_card wait question; update_board wait_routes
curl -s -H "$H" -H 'content-type: application/json' B/api/cards/57/wait      -d '{"needs": "Which pricing tier ships first?", "question": "product"}'
curl -s -X PATCH -H "$H" -H 'content-type: application/json' B/api/boards/1      -d '{"wait_routes": {"product": ["dana@example.com"], "release": []}}'

# what is waiting on you, oldest first, then your cards by due (?board=1, ?done=true)
curl -s -H "$H" B/api/work
# off your own Waiting on you (#2069): dismiss one item, held on its cause
# (a new cause shows again), list and undo; mute a board's tree, unmute.
# CLI: slipdock work --dismiss 57 / --dismissed / --undismiss 57 / --mute ops / --unmute ops
# MCP: update_card waiting_list dismiss|undismiss; update_board waiting_list mute|unmute
curl -s -H "$H" -H 'content-type: application/json' B/api/work/dismissed -d '{"card": 57}'
curl -s -H "$H" B/api/work/dismissed
curl -s -X DELETE -H "$H" B/api/work/dismissed/57
curl -s -H "$H" -H 'content-type: application/json' B/api/work/muted -d '{"board": "ops"}'
curl -s -X DELETE -H "$H" B/api/work/muted/ops

# the top 5 cards of lists from several boards, by board, list or grid
# (lists: ids or board/list; none: the view saved on the Multiboard page)
curl -s -G -H "$H" B/api/multiboard --data-urlencode 'lists=12,ops/To Do' -d top=5 -d by=grid
# saved multiboards: named views on your home page (GET one = its cards)
curl -s -H "$H" B/api/multiboards
curl -s -X POST -H "$H" -H 'content-type: application/json' B/api/multiboards   -d '{"name":"Ops queue","color":"rose","lists":"ops/To Do,12","top":3}'
curl -s -X PATCH -H "$H" -H 'content-type: application/json' B/api/multiboards/4 -d '{"color":"teal"}'

# the boards themselves (owner only; ask before doing either)
curl -s -X POST -H "$H" B/api/boards/1/archive    # put a board away, keeping everything on it
curl -s -X POST -H "$H" B/api/boards/1/restore    # and bring it back
curl -s -X POST -H "$H" B/api/boards/welcome      # the Getting Started tour board, again
curl -s -X POST -H "$H" -H 'content-type: application/json' B/api/boards/order      -d '{"boards": ["roadmap", "qvm-v1-rem", 3]}'   # your own order for the index
```

Keep titles short: about 60 characters at most, a series as
`<Series> <n>: <what>`, the detail in the description. Things written in
numbers need titles that tell them apart, and nothing written for a card
needs to repeat the card's title: its folder says that already.

A long title gets a short name by itself (`short_name`, for tight spaces
and the card's folder on disk): over 40 characters one is made on save, by
the cheapest model when there is a key. `short_name` on a card write sets
your own, and `""` hands it back.

A page written for a card lives in the card's folder,
`<Board>/Cards/<card>/`, made on first use and tied to the card by id, so
renaming the card renames it: `POST /api/cards/:id/pages`, or `card` on
`POST /api/boards/:b/pages` and MCP `write_page`. Attaching an existing
page (`pin_card`) is a link, and moves nothing. A page there titled like
the card, as "write it up" makes, keeps that title and takes the card's
short name on disk: `Cards/<short>/<short>.md`. A pass log is
`Pass <n> (<YYYY-MM-DD HH.MM>)`, there too.

### Waits, pauses and a card's state

**A wait** is a card waiting on a person: what it `needs`, who it is
`on` (a person, or `null` for anyone), optional `choices`, and when and by
whom it was opened. A card has at most one open one, shown as its `wait`.
Opening one flags the card `waiting` and comments the question; removing
that flag by hand withdraws it; answering posts the answer as a comment
from whoever answered and clears the flag if the wait set it. An agent
cannot answer a wait it opened itself. Completing or archiving the card
closes it. A wait opened from a runner job parks the job, and the answer
sends the card to its rule again (see Runners). Prefer a wait to a bare
`waiting` flag: the flag has no clock, no owner and no way back.

**When to wait, and when not.** A wait is for readings that differ
materially in cost or in what the person sees, for decisions the
Playbook or the board routes to a person (product, ux, security,
release), and for anything a rule says is a person's step (merging,
changing a handbook rule, deploying). A locked bar item that a later,
cited decision or rule has made moot is not one: read it the obvious
way, say so on the card (what you read, why, the citation) and leave
the judgement to the verifier, who accepts a noted reading and rejects
one that wasn't noted. A wait offering choices and a proposed answer is
an approval and should be rare; when raised, it names the default you
would take as `default` (the choice's number, from 1; CLI `--default
N`), so the answer can be one click.

**How a question reads** (#3001). A question for a person explains its
options and recommends one: list each option and what choosing it would
mean, and say which you would take and why. Where the options are short,
give them as `choices` with yours as the `default`. The card shows the
question as Markdown; send one over several lines through stdin
(`slipdock wait <card> -` with a quoted heredoc).

**Every field you write is Markdown too** (#3001). The card shows the
description, bar, evidence, handoffs, wait questions, status updates and
a verdict's reason as Markdown, as it does comments. Write each as a
list (a bar's parts numbered), or short separate paragraphs where a list
doesn't fit. Send them through stdin with a quoted heredoc (`--desc -`,
`--bar -`, `--evidence -`, `--reason -`), since words on the command line
lose their line breaks.

**A moot wait clears itself.** Sent a card (or its epic) with an open
wait, check first that it is still live: the question answered
elsewhere, the bar or description edited since, the cited rule or
decision now in place, the card rejected or accepted since. Withdraw a
moot one with why, `DELETE /api/cards/:id/wait?reason=…` (MCP
`update_card` `wait: null` with `wait_reason`; CLI `slipdock wait <id>
--withdraw --reason "…"`), and carry on to the obvious reading. Any
agent may, not only the one that opened it, but an agent withdrawing a
wait it didn't open is refused (422) without a reason; the comment
carries it. A board's `wait_default_after` (off unless set: `4h`,
`90m`, `2d`) lets an approval wait, of kind `other` with choices and a
`default`, go unanswered that long and then resolve to its default:
the card says so, the person asked is told, and the card moves on as
on an answer. Never for a product, ux, security or release question,
nor a wait with no default.

**Several questions** go in one wait as `questions` (at most 20), never
as one block in `needs`: each is shown numbered with its own answer box,
and `needs` becomes the line in front of them (a `needs` written as a
numbered list `1. … 2. …` is split the same way). Answer with `answers`,
one per question in order (or `{"2": "…"}` by number; `""` leaves one
unanswered), kept on the wait as `answers`. `{"skip": true}` skips them
all: the wait closes as `skipped` and the card moves on as it would on
an answer, a runner job's card going to its rule again told to use its
own judgement. `GET /api/cards/:id/waits` (MCP `get_card` `waits: true`,
CLI `slipdock waits <id>`) lists every wait the card has had, newest
first, with the answers.

**Waiting on you.** `GET /api/work` (MCP: the `plan-my-day` prompt;
CLI: `slipdock work`) answers `waiting`, oldest
first, each with its reason and how long it has waited — open waits on
you or on anyone on your cards, your cards flagged `review` or
`waiting`, cards the runner gave up on or whose newest job failed on
boards you own, cards in a doing list for over an hour with nobody
on them, and cards still in a Scheduled list after the end of their due
day (`scheduled_missed`) — then `sections`, your cards by when they are due.
A card awaiting verification on a tree you own (reason `verify`) is on
you only when no runner has it in hand: not while a verify job for it
is claimed or running, nor, for 15 minutes after it was submitted, while
one is queued or a runner of its board's verify pool is online. Past
that with no verify job started it comes back; with no verifier it is
on you at once. You can accept or reject it by hand either way. A merge
job that failed on something a rebase fixes (a conflict, a head that
moved) is left out while a build job is claimed or running on the card
or a card above it; any other failure shows as before. The
overseer's open conditions (reason `overseer`, each with its
`condition`: `check`, `why`, `todo`) come first; cards on a *Getting
Started* tour board never come at all. `GET /api/me` and `whoami` carry
the count as `waiting_on_you`, and the overseer's conditions among them
as `overseer`.

**What in an epic's tree waits on you.** `GET /api/cards/:id` (MCP
`get_card`) carries `waiting_on_me` for the card's sub-board tree, and
`GET /api/boards/:board` (MCP `get_board`) for the board's whole tree,
with each epic in its lists carrying its own: `{count, cards,
on_others, line}`. `count` is the items on you; `cards` those items,
each exactly as `GET /api/work` gives it plus `short` (`a question`,
`3 rejections`, `a failed job`); `on_others` the open waits in the tree
on someone else by name, never counted; `line` the tile's glance line
(`Waiting on you: #2063 (a question) and 1 on someone else`), null when
nothing waits. A card with no subcards has `count` 0. A wait on you
(or a card past the rejection limit) also raises an alert only you see,
and its email, each on by default and off in account settings.

**Off your own list.** Each item has a `cause` (`job:812`, `wait:40`,
`flag:review:<unix time>`, …). `POST /api/work/dismissed` (`card`) takes the
card off your list for that cause only: a new cause (a second failed job,
a new wait) shows it again, and a card with another reason shows for
that one. `POST /api/work/muted` (`board`) keeps a board's whole tree off
it. The board works as before for everyone. Both are yours alone and
need only read access. `GET /api/work` says what is hidden:
`dismissed_count`, `muted_count` (cards a mute keeps off) and
`muted_boards`. `GET /api/work/dismissed` lists the dismissed items,
`DELETE /api/work/dismissed/:card` undoes one and `DELETE
/api/work/muted/:board` unmutes. Over MCP, `update_card` and
`update_board` take `waiting_list` on its own, and `whoami` carries
`waiting_hidden`. Never dismiss for a person what they haven't asked
you to.

**A pause.** While a board tree or one of its runner pools is paused,
`GET` of the board and its cards, `get_board` and `list_cards` carry
`paused`: a list of `{scope, reason, by, line, paused_at}`. If it is
set, take nothing and stop; resuming is a person's (see Runners).

**A card's state**, worked out from what is already recorded and left
out when there is nothing to say: `state` (one line: "Waiting on Dana ·
41m", "Held · paused by David: bad deploy", "Running · runner-2 · 7m"),
`held` (why its queued job waits), `loop` (`{runner, kind, job_id}`
while a runner job holds it: shown beside the assignees, never one, so
a runner's agent doesn't assign the card; a subcard an epic's build job
is working, its current step naming it, carries that job's), `driver` (`agent` while a
runner job holds it, else who last moved it — runner boards only), `in_list_since`
and `age` (seconds in its list), `usual_stay` (the list's 85th-percentile
stay), `over_usual` and `stuck` (past it). The `stuck` and `driver`
filters read the same values.

**Who made a card and who changed it last**, on a single card (`GET
/api/cards/:id`, MCP `get_card`, `slipdock card`): `created_by` and
`updated_by`, each `{kind, name, user_id}` with `kind` one of `person`,
`agent`, `runner` (with `job_id`, named for its loop: "Dev server
loop") or `automation` (the rule's name), or null when nobody was
recorded; never a guessed name. `updated_at` there is the last change
of any kind (comments, checklist, attachments and flags too): the later
of the newest activity entry and the card's own `updated_at`.

**Where a card came from** (#2778): every card made since then carries
`origin` (`person`, `sweep`, `findings`, `health`, `overseer`, `verify`,
`release`, `automation`, `import` or `agent`) and `origin_job_id`, the runner job
an agent made it in; null on older cards. The server sets it from who
made the card. Inside a runner job an agent may name the generator it
is running, `"origin": "sweep"` or `"findings"` on `POST
/api/boards/:board/cards` (MCP `create_card` `origin`, `slipdock add …
--origin sweep`); any other claim, `person` included, is a 422. Filter
on it with `?origin=` (`none` for older cards; MCP `list_cards` `origin`,
`slipdock cards --origin`), and a rule's condition can read `origin`.

**A card's timeline**: `GET /api/cards/:id/timeline` (MCP `get_card`
with `timeline: true`, CLI `slipdock timeline <id>`) gives `stays` (each
list it sat in, with `how` it got there and who), `waits` and `jobs`,
each with `from`, `to`, `seconds` and `open`; `unsure` marks a stay the
ledger can't vouch for.

**Its lead time and cost** (#1954): `GET /api/cards/:id` and MCP
`get_card` carry `lead_time` on a card a runner job was sent on, and on
an epic (any other card leaves it out). It has `seconds` and `ends` (`deployed`,
`completed` or `open`), `phases` (each phase with any time, in seconds)
and `cost`, which is what its jobs spent, from their logs. `cost` has a
`total` and the `phases` the jobs ran in (build, rework, verify, merge).
Each gives `model_seconds`, `tool_seconds`, `jobs`, and `tokens`
(`input`, `output`, `cache_read`, `cache_write`, `total`) only when a
log carried `usage`. `cost` is null when no job sent a log. On an epic,
`rollup` adds its subcards: `subcards`, their `seconds` added up, and
the `cost` of theirs and the epic's own jobs together. No prices: what
tokens cost is yours to work out. CLI: `slipdock card` (`Lead time:`).

### What comes back

The samples below are real responses, trimmed: every field shown is
there, and the real thing carries more. URLs inside them are relative to
the server (`/boards/3/cards/57`), not absolute.

**A whole board.** Each list carries its own `cards` (and the wiki
`pages` placed in it), in order, so one call draws the board; a card
inside a list has `column: null`, since the list it sits in says that.
Reach for `/boards/1/cards` when you want a filter, not to fill the lists.

```sh
curl -s -H "$H" B/api/boards/1
```

```json
{"board": {"id": 1, "name": "Delivery", "code": "delivery", "simple": false,
  "columns": [{"id": 9, "name": "To Do", "category": "todo", "position": 0,
               "cards": [{"id": 57, "title": "Refund rounding", "column": null,
                          "column_id": 9, "position": 0, "completed": false}],
               "pages": []}],
  "tags": [{"id": 4, "name": "api", "color": "sky"}]}}
```

**One card.** A comment is `id`, `body`, `author` and `inserted_at`. The
`author` is who wrote it, `{id, name, email}` as an assignee is; it is
`null` on comments written before authors were kept and on the ones the
server writes itself (automations, runner notes). A status update names
its writer by `user_id`. A checklist item is `id`, `position`, `done` and
`text`.

```sh
curl -s -H "$H" B/api/cards/57
```

```json
{"card": {"id": 57, "title": "Refund rounding", "column": "To Do", "column_id": 9,
  "completed": false, "stated_health": "at_risk",
  "checklist": {"done": 0, "total": 1,
                "items": [{"id": 11, "position": 0, "done": false, "text": "Write the test"}]},
  "comments": [{"id": 1411, "body": "Rollback was blocked on approvals",
                "author": {"id": 2, "name": "Ada", "email": "ada@example.com"},
                "inserted_at": "2026-10-13T00:41:41Z"}],
  "status_updates": [{"id": 7, "health": "at_risk", "body": "Waiting on finance",
                      "user_id": 2, "inserted_at": "2026-10-13T00:50:00Z"}]}}
```

**A stated health.** `POST /api/cards/:id/status` takes `health` —
`on_track`, `at_risk` or `off_track` — and an optional `body` of up to
4000 characters. It answers `201` with the whole card, the new update
first in `status_updates` and `stated_health` set from it; any other
`health` is a `422`. Over MCP it is the `status_update` tool.

**Step statuses.** The server posts the routine ones itself, as an
`on_track` update with no user (`user_id: null`, shown as *Slipdock*),
at each step an agent-worked card goes through: a build job claimed
(`Writing code`, or `Reworking after verify failed` after a
rejection), a wait opened (`Waiting for human`), submitted (`Verifying`
with a verify pool, else `Waiting for human to accept`), rejected
(`Verify failed; queued for rework`), over the rejection limit
(`Waiting for human (rejection limit)`), held for a person (`Waiting
for human (held before merge)`), accepted on a pull-request board
(`Accepted; merging`), merged (`Merged`), completed (`Done`), reopened
(`Reopened`) and deployed (`Shipped to production`). The same text is
never posted twice in a row, and these tell no watcher: they write no
activity line. Don't post them yourself; post one only to add what the
server can't know (a risk, a slip), and a person's update tells
watchers as it always did.

```sh
curl -s -H "$H" -H 'content-type: application/json' B/api/cards/57/status \
     -d '{"health": "at_risk", "body": "Waiting on finance"}'
```

```json
{"card": {"id": 57, "title": "Refund rounding", "stated_health": "at_risk",
  "status_updates": [{"id": 7, "health": "at_risk", "body": "Waiting on finance",
                      "user_id": 2, "inserted_at": "2026-10-13T00:50:00Z"}]}}
```

```json
{"error": "validation failed", "details": {"health": ["is invalid"]}}
```

**A handoff.** Where the card was left, for whoever picks it up next.
`POST /api/cards/:id/handoff` takes `next_step` (one line, at most 280,
required) and an optional `body` of up to 8000, or `{"clear": true}`;
anyone who may comment on the card may write one. Each write is a new
row: the newest is the card's `handoff` (`null` when there is none or it
was cleared), and `GET` gives it with every earlier one as `history`,
newest first. A runner job that ends with its card open writes its
summary as one (`via: "runner"`) unless the agent wrote one during the
job, or the card is already accepted (merging, held or accepted): a
verifier's summary isn't the next step. `DELETE /api/cards/:id/handoff` deletes the current one outright
(its author, or anyone who can edit the card): it answers `deleted` and
the `handoff` now current, the one before it or `null`. Over MCP it is
the `leave_handoff` tool (`delete: true` deletes). A board can call it
something other than "Left off" in the web app and give the web app's
Auto generate its own instructions: `PATCH /api/boards/:board
{"handoff_label": "Parked", "handoff_prompt": "…"}` (`""` for the
defaults; the board's `GET` answers both). Agent-facing text keeps
"Left off:".
A board's *Verified work* switches (`bar_required`,
`evidence_required`, `verify_work`, `verify_pool`, `ship_via`) are set the same
way; the *Verified work* section describes them when one of your boards
has one on. So is `profiles` (`true` gives each card an agent starts one
word of profile, #1951); the *Profiles* section describes it then.

```sh
curl -s -H "$H" -H 'content-type: application/json' B/api/cards/57/handoff \
     -d '{"next_step": "Write the rounding test", "body": "State: fix is in, untested"}'
```

```json
{"card": 57, "handoff": {"id": 3, "next_step": "Write the rounding test",
  "body": "State: fix is in, untested", "cleared": false, "via": "api",
  "job_id": null, "by": {"id": 2, "name": "Ada", "email": "ada@example.com"},
  "at": "2026-10-18T09:12:00Z"}}
```

**A recurring card.** `PUT /api/cards/:id/recurrence` makes the card
repeat, or changes how: `rule` is a phrase (`every mon`, `weekday`,
`2w mon thu`, `month 1`, `month last fri`, `year`, `3d after` — three
days after the last one is done) or an RRULE subset
(`FREQ=WEEKLY;BYDAY=MO`); with it `at` (`"07:00"`, the time each one is
made), `timezone` (the token holder's by default), `lead_days` (make it
that many days before it is due), `on_missed` (`bump`, the default: an
instance still open has its due date moved on; `skip`; or `stack`),
`ends` (`never`, `on` with `ends_on`, `after` with `count`), `column`
(the list each one is made in: without it, the board's Scheduled list
when it has one, else its ready list) and `paused`. Only `rule` is
needed to start one; a card with no due
date becomes the first occurrence. `GET` reads it (from an older
instance too, with `current: false`), `DELETE` stops it, and
`POST …/recurrence/skip` lets the next one go. Every occurrence keeps the
title and gets the short name `<title or short name> <YYYY-MM-DD>`, its
due date, so their folders tell themselves apart.
`GET /api/boards/:board/recurring` lists a board's. Over MCP it is
`update_card`'s `recurrence` (`null` stops it, `skip: true` skips one).

```sh
curl -s -X PUT -H "$H" -H 'content-type: application/json' B/api/cards/57/recurrence \
     -d '{"rule": "every mon", "at": "08:00"}'
```

```json
{"card": 57, "recurrence": {"id": 4, "card_id": 57, "kind": "fixed",
  "rule": "FREQ=WEEKLY;BYDAY=MO", "summary": "Every week on Mon, 08:00 Europe/London",
  "at": "08:00", "timezone": "Europe/London", "lead_days": 0, "on_missed": "bump",
  "ends": "never", "made": 1, "next_on": "2026-10-26", "next_at": "2026-10-26T08:00:00Z",
  "upcoming": ["2026-10-26", "2026-11-02", "2026-11-09"], "paused": false}}
```

**Snoozing a card.** `POST /api/cards/:id/snooze` hides it until
`until`: a date (`2026-11-02`, midnight in the token holder's timezone),
a datetime, or a phrase (`tomorrow`, `mon`, `next week`, `in 3 days`).
With it `note` (why, at most 280 characters), `notify` (alert the board
when it wakes) and `wake_on_activity` (default `true`: someone else's
comment or assignment wakes it). The past, a completed card and unknown
fields are refused. `DELETE` wakes it now. Both answer the card, with
`snoozed_until` and `snooze`. `GET /api/boards/:board/cards?snoozed=only`
lists what is asleep. Over MCP it is `update_card`'s `snoozed_until`
(`null` wakes it) and `snooze_note`, and `list_cards`' `snoozed`.
Snooze when the person says a card can wait until a day, or when what
it waits for has a date; flag it `waiting` when it doesn't.

```sh
curl -s -X POST -H "$H" -H 'content-type: application/json' B/api/cards/57/snooze \
     -d '{"until": "next week", "note": "waiting for the quote"}'
```

**Tidying up a board.** The gardener (W-1807) looks a board and every
board beneath it over for rot — epics done but open, Done cards never
completed, completed cards outside Done, cards stuck in progress, epics
with no next step, long-overdue and abandoned cards, likely duplicates,
pages nothing links to, `[[links]]` that nearly match a page, cards
closed on a handbook board without a `Handbook:` line, and on a
handbook board long handbook sections (`long_section`), `covers:` that
match everything (`broad_covers`), `must` rules left to `judgement`
and rule ids used twice (`rule_without_check`), and decisions that
supersede one without linking back or aren't titled `Decision:`
(`stale_decision`), and rules an agent added, reworded or removed since
a person approved them (`rule_changed`: apply reverts them, dismiss
keeps them) — and keeps a suggestion for each. `POST /api/boards/:board/garden` (optionally
`check`) looks it over now; `GET` lists the open suggestions, the last
run and every check's settings. A suggestion has `check`, `explanation`,
`cards`, `pages`, `proposal` (its steps), `alternatives` and
`needs_keep`. `POST /api/garden/suggestions/:id/apply` (`choice`: an
alternative by name; `keep`: the card that stays, for a duplicate),
`…/dismiss` and `…/undo` decide one (a proposal excepted: see below); `PATCH
/api/boards/:board/garden/settings` sets a check's `enabled` and
thresholds. Over MCP it is `garden` and `garden_decide` (`confirm: true`).
Show the person the suggestions and apply only what they approve; never
dismiss one on your own, since a dismissal is remembered until its
subject changes. A suggestion applied can be undone, unless something has
moved on since.

```sh
curl -s -X POST -H "$H" B/api/boards/ops/garden
curl -s -X POST -H "$H" -H 'content-type: application/json' \
     B/api/garden/suggestions/41/apply -d '{"choice": "snooze"}'
```

**Proposing a handbook edit.** Describe freely, but don't rewrite a
rule or a decision on your own say: propose it, and a person applies,
dismisses or undoes it. `POST /api/boards/:board/garden/proposals`
(`slipdock garden propose <board> <file.json | ->`) takes
`explanation`, `steps` and the evidence as ids, `findings` and `cards`.
A step is `edit_section` (`page`, as an id or a code; `section`, its
heading path; `body`, the new text, as `slipdock page section` writes
it; `base`, filled in from the section as it is now when left out),
`comment` (`card`, `body`) or `file_page` (`page`, `folder`); any
other op is refused. It answers `201` with the suggestion (check
`proposal`, `person_only: true`, its `findings`), or `200` and
`created: false` with the one already filed: the same proposal again,
even one a person dismissed, makes nothing new. Applying it refuses a
section changed since `base`, and undoing it refuses a page edited
since. An agent can't apply, dismiss or undo a proposal, or any
suggestion with an `edit_section` step, over REST or the CLI: only a
person can, and a proposal is decided on the board's Tidy-up page
(`/boards/<id>/tidy`, which shows the section's diff), signed in, and
nowhere else (W-1945 §Permissions, #2668). REST, the CLI and MCP's
`garden_decide` are refused with the page's link, whatever token,
headers or `confirm` they send: an agent holding the person's token
can't present their browser session. Point the person at the page.

```sh
curl -s -X POST -H "$H" -H 'content-type: application/json' \
     B/api/boards/ops/garden/proposals -d '{
       "explanation": "UX-4 keeps breaking: name the tokens",
       "steps": [{"op": "edit_section", "page": "W-12", "section": "UX & UI/Rules",
                  "body": "- **UX-4** must · judgement · Design tokens only."}],
       "findings": [31, 34]}'
```

**Search.** `GET /api/search` takes `q`, and optionally `board` (id,
code or name), `kind` (`cards`, `pages` or `all`), `limit` (default 20,
at most 50) and `archived=true`. A result is either a card or a page:
`kind` says which, `subject` has the title and URL whichever it is, and
the other of `card`/`page` is `null`. Read the title from `subject`.

```sh
curl -sH "$H" --get --data-urlencode 'q=staging rollback' -d board=delivery -d limit=5 \
  B/api/search
```

```json
{"query": "staging rollback", "count": 1,
 "results": [{"kind": "card", "score": 0.5422,
   "subject": {"title": "Refund rounding", "url": "/boards/1/cards/57"},
   "card": {"id": 57, "title": "Refund rounding", "completed": false, "priority": "none",
            "due_date": null, "archived": false, "tags": [],
            "board": {"id": 1, "name": "Delivery", "code": "delivery"},
            "column": {"id": 9, "name": "To Do"}, "url": "/boards/1/cards/57"},
   "page": null,
   "matches": [{"kind": "comment", "source_id": 1411, "section": null, "score": 0.5422,
                "text": "Comment on card “Refund rounding” (Delivery), 2026-10-13:\nRollback was blocked on approvals",
                "url": "/boards/1/cards/57?at=comment-1411"}]}]}
```

**Ask.** `POST /api/ask` takes the question as `q` or `question`, an
optional `board` (id, code or name) to keep the assistant to one board,
and an optional `history` (`[{"role": "user"|"assistant", "content":
"…"}]`) to carry a conversation on. It answers **synchronously**, in the
same response, after the model has finished — allow it a minute.
`GET /api/ask?q=…` is the same call, not a poll. The prose is in
`answer` (Markdown), the cards and pages it read in `sources`, and the
searches it ran in `searches`. A token confined to some boards is a
`403`; a model failure is a `400` with the reason.

```sh
curl -s -H "$H" -H 'content-type: application/json' B/api/ask \
     -d '{"q": "What is happening with refunds?", "board": "delivery"}'
```

```json
{"question": "What is happening with refunds?",
 "answer": "Finance are waiting on the refund rounding card (#57).",
 "searches": ["refund rounding"],
 "sources": [{"kind": "card", "id": 57, "title": "Refund rounding", "board": "Delivery",
              "found_by": "refund rounding", "url": "/boards/1/cards/57"}]}
```

An **archived board** is put away, not deleted: it comes off the board
index, the board switcher and quick add, but every card, tag, comment and
automation on it stays, and its link and its API endpoints go on working.
`GET /api/boards` leaves archived boards out; `?archived=true` lists those
alone and `?archived=all` lists both, and every board carries
`archived_at`. Treat an archived board as work the person has deliberately
set aside.

The **order** is per person, not per board: `POST /api/boards/order` sets
the order *you* list boards in and moves nobody else's index. Boards you
leave out of the list fall to the end, oldest first. `GET /api/boards`
comes back in your order unless you ask for another with `?sort=` —
`manual` (yours), `name`, `active`, `newest`, `oldest` or `cards`.

Errors come back as `{"error": "…"}`, and a failed validation as
`{"error": "validation failed", "details": {"field": ["…"]}}`. Read the
message: "column not found" and "tag not found" mean you passed a name that
does not exist on that board, not that the API is broken.
