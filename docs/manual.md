# Slipdock — the manual

Everything this app does, in detail. [README.md](../README.md) is the short
way in: what it is, the pictures, and how to get it running.

## Features

- Multiple boards, each with its own colour, description, tags and a short
  **code** — a unique, URL-safe handle of up to 10 characters ("QVM V1
  Remediation" becomes `qvm-v1-rem`), taken from the name and editable in
  board settings, that addresses the board in the API and the CLI
- Lists (columns) with drag-and-drop reordering, inline rename, colour and WIP limits,
  and an order of their own: sorted by date or priority, grouped by flag, tag or
  date — see [A list's order and groups](#a-lists-order-and-groups)
- Cards with drag-and-drop between and within lists (let go anywhere in a
  list's column — its header, its footer, the board below it — and the card
  goes to the bottom of that list), description, priority
  (low → critical), five flags (flagged, blocked, needs review, waiting, starred),
  due dates with overdue/soon states, completion toggle, cover colours, tags,
  checklists, comments, archive/restore and delete — one at a time, or several
  at once from the board's select mode (see [Changing several cards at once](#changing-several-cards-at-once)).
  The board's **Archived cards** panel has a search box: a piece of a title,
  or a card's id (`#123`) or link, finds the archived card to restore. An
  archived card's own link opens that panel on it rather than a dead end.
- Handoffs: one short note on a card saying where it was left — the next
  step, the state, the gotchas — read first by whoever picks it up next. See
  [Where it was left](#where-it-was-left-handoffs)
- Recurring cards: a series on the card that copies the current instance when
  the next is due, in your timezone, without stacking up missed ones —
  [Recurring cards](#recurring-cards)
- Snooze: hide a card that isn't actionable yet until a day, and have it come
  back at the top of its list — [Snoozing cards](#snoozing-cards)
- Delivery metrics: deploys recorded from CI, the DORA numbers and idea to
  production, and a *Shipped* line on the cards a deploy names —
  [Delivery metrics](#delivery-metrics-deploys-and-dora)
- Tidy up: the board looks itself over for rot — epics done but open, cards
  stuck in progress, duplicates, orphaned pages, mistyped links — and
  proposes each fix for you to apply or dismiss — [Tidying up](#tidying-up)
- Time tracking: a start/stop timer on each card, time spent and an estimate
  shown in a unit of its own, and a colour-coded bar between them — see
  [Time tracking](#time-tracking)
- Attachments: files up to 250 MB on any card, and images (up to 50 MB) pasted
  or dropped into the description or a comment are uploaded and shown inline (stored under
  `priv/uploads/`, `SLIPDOCK_UPLOADS_DIR` to move it; served with access checks).
  The API and CLI upload them too — see [Attachments over the API](#attachments-over-the-api).
  A card's first image is a thumbnail on its front — see [Images on the card front](#images-on-the-card-front).
  A recording plays in place, and can be transcribed — see [Recordings](#recordings)
- @mentions: `@someone` in a card's description or a comment — the part of
  their email before the "@", or a one-word name — names a person who can see
  the board. Typing `@` offers the board's members; a mention shows as a chip,
  and the person gets an email saying who mentioned them and where, linking to
  the card. A comment emails everyone it mentions; a description only those an
  edit newly mentions, so re-saving it does not mention everybody again. Nobody
  is told about mentioning themselves, `@` anybody without access to the board
  stays plain text, and comments on wiki pages notify nobody. The email goes
  through the configured mail transport, so without SMTP nobody hears.
- Dependencies between cards ("blocked by" / "blocks"), with cycle detection,
  a blocked badge on cards, and a swimlane axis/filter for blocked work
- Subcards: any card can become a board of its own, with lists chosen from a
  board template; sub-boards nest to any depth
- Sprints: a sprint board whose every card is a sprint, a **New sprint**
  button that dates the next one, and **Add cards…** to tick work from any
  board into it, and **Charts** for each sprint's burndown and the board's
  velocity — see [Sprints](#sprints)
- Roll-ups: every card summarises the whole tree beneath it — leaves done,
  effective start and due dates (its own or its subcards'), slip past a
  planned due date, blocked or overdue anywhere below, and a health state —
  shown on cards, in the table, in the card modal and as timeline bars
- Outline view (`/boards/:id/outline`): the board as a collapsible tree of
  cards and subcards to a chosen depth — one level is the roadmap, all levels
  the task list
- Assignees: a card can be assigned to one person or several (the first is
  the lead, which is who colour-by-assignee goes by) — anybody who can open
  the card, so share the board before assigning someone new — with an assignee
  swimlane axis that puts a shared card in each person's lane, and **My work** (`/work`) lists everything assigned to you across all
  boards and levels, each with its path in the tree
- Automations: rules written in plain English ("when a card lands in Done,
  email ops@example.com"; "move anything untouched for a week back to
  Backlog"), parsed once by the model and then run by the app — plus
  dismissable alerts in the header bar of every page (see below)
- Wiki (`/boards/:id/wiki`): Markdown pages on a board, in a tree of their own
  beside the cards — for how something works, what was decided and why, which
  a card is a bad home for. `[[links]]`, live card chips, live ```` ```slipdock ````
  query blocks answered with the reader's own permissions, backlinks, wanted
  pages, section-at-a-time writes, semantic search over the lot, templates,
  publishing to a public link, export to a folder of Markdown, and pages that
  can be put in a list and dragged about like cards. Every save
  kept as a revision with who made it and why, and the whole of it over the
  API and CLI so an agent writes documentation the same way a person does
  (see below)
- **Folders** on a board's wiki, nested to any depth, for filing documents
  rather than nesting them under a page that is about nothing — and a **Wiki
  view** (`/wiki`) over every board at once, each board a top-level folder
  with its own folders and pages inside (see [Wiki](#wiki))
- Cards move between boards, subcards and all, from the same menu that moves
  them between lists — tags travel by name, custom fields where the other
  board has them (see below)
- Favourites (`/favourites`): the handful of things you keep going back to —
  a saved view, a list on a board, a card, a whole board — kept per person and
  two taps from anywhere: the heart in the header, the phone's fifth tab
  (see below)
- Archivable boards: a whole board can be put away without deleting anything
  on it, and brought back from the Archived section of the board index
- Two layouts for the board index, and an order of your own: cards or a
  compact table, sorted your way (see [Your boards](#your-boards))
- Board templates (named sets of lists) for new boards and sub-boards, with
  an editor at `/templates`
- A phone-specific layout below 640px: a floating navigation button with
  quick add in the thumb zone, the board as a one-list pager, and the calendar, swimlanes,
  timeline, table and Prioritise rendered for a narrow screen rather than
  scrolled sideways (see [On a phone](#on-a-phone))
- Filter bar: full-text search, kind (cards / documents / wiki pages), tag,
  priority, flag, due date, hide completed
- Web links on a card: pages, shared drives and files elsewhere, datestamped
- Command palette (`Ctrl-P`) for everywhere you can go and everything you can
  set off, and a card finder (`Ctrl-O`) that opens any card by title or id
- Keyboard throughout: `?` for the sheet, `b` to switch board (each has its own
  key), `Ctrl-Shift` and a digit straight to a board you gave it, `v` to switch view, `q` to add, `/` to search; on a board `j` labels
  every card so a keystroke opens it, `J` picks one up for the arrows to move,
  and `c` steps through a list; an open card scrolls with the arrows and jumps
  to a section by the letter underlined in its heading (see below)
- Swimlane view (`/boards/:id/swimlanes`): cards as a grid with any attribute
  on each axis, date grouping, sorting, filters, display options and saved views
  (see below)
- Table view (`/boards/:id/table`): one row per card with sortable headers, a
  column chooser, optional grouping, inline editing, and the same filters and
  saved views
- Timeline view (`/boards/:id/timeline`): a Gantt-style chart of cards by
  start and due date, zoomable from days to years, draggable bars, grouping,
  and subcards nested beneath their parent's bar to a chosen depth
- Calendar view (`/boards/:id/calendar`): a month or week with cards on their
  due dates, drag between days, quick add on a day
- Roadmapping: lists can carry a **category** (to do / in progress / done /
  dropped) and a **horizon** (a date range such as Q1 2027) that schedules
  cards dropped into them; cards can be scheduled by day, week, month,
  quarter, half-year or year; **milestones** are drawn on the timeline and
  calendar; the timeline draws **dependency lines**, red where the dates
  contradict the dependency; any view can be **coloured by** list, priority,
  health, reported health, assignee or tag, with a legend
- **Status updates**: on track / at risk / off track with a note, shown
  beside the health the roll-up computes
- **Custom fields** per board tree (number, rating, choice with weights,
  date, text) and **formula fields** with RICE, ICE and value/effort
  presets, usable as table columns, sorts and swimlane axes (a rating ×
  rating grid is the effort/impact matrix); summable fields roll up the
  tree and total in table groups
- **Budget voting**: everyone gets a number of votes to spend across a
  board tree, capped per card
- **Typed links** between cards on any boards (relates to, contributes to,
  duplicates); a goal card collects its contributions and their progress
- **Narrative view** (`/boards/:id/narrative`): what happened to the cards
  a view selects over a date range, told group by group and card by card,
  subcards included
- **Published views**: a saved view can be given a public read-only link
- **Prioritise view** (`/boards/:id/prioritise`): a ranked table where
  priority, votes and scoring fields (RICE, ICE, …) are edited in place
- **Quick add** in the table and outline: type a line like
  `Write the post due: tomorrow #high #todo #docs @dan` and press Enter
- **Quick add in the header** of every page (or press `c`): one line of
  plain English — "call the printers about the banners friday, urgent" —
  read by a cheap model into a card on your default board and list, both
  set under Account › Settings
- **Deep search and Ask** — one page over every board at once, in two modes.
  *Search* matches by meaning rather than substring: cards, comments and status
  updates are embedded, so "the thing that was blocked on legal" finds the card
  whose comment said "waiting on the contract review", with the snippet that
  matched. *Ask* hands that same search to a model as one tool among several —
  count a board list by list, describe a board, list one person's work, read
  the activity log, read your alerts — so a question in prose gets an answer
  in prose, naming the searches it ran and linking the cards it read. Both
  scoped to what you may read
- **AI assistant** (OpenRouter on a cheap model, or your own local model):
  *Chat* about any board page
  or card, a narrative *Generator* that writes prose at five levels of
  detail, and an *Edit* mode that turns "set this due next Tuesday and pick
  a suitable priority" into changes you approve before they apply
- **CSV export** of any table
- Activity log per board
- Real-time: every browser looking at a board updates instantly (Phoenix PubSub)
- Light/dark/system theme
- Accounts: passwordless sign-in by emailed magic link, sessions that last
  30 days, API tokens for the CLI
- **An MCP server** at `/mcp`: claude.ai, the Claude apps, Claude Code and
  other MCP clients get the boards and the wiki as 52 tools (five of them only
  while meeting mode or chat capture is on), signing in
  through the browser or with an API token (see [MCP server](#mcp-server))
- Groups of users; boards, single cards and saved views can be shared with
  people or groups as read-only or editable
- **A Getting Started board** built on a first sign-in: a tour of all of the
  above, made of cards, subcards, a live automation and wiki pages (see below)

## Getting Started

The first time an account signs in it gets a board called **Getting Started**,
and lands on it rather than on an index with nothing on it. It is built by
`Slipdock.Onboarding`, and it is both halves of the same job: a new install
that shows a blank page teaches nobody anything, and whatever is put there to
fix that may as well be the tour.

What is on it:

- **A card per feature**, in the To Do list, in the order somebody meets them:
  opening a card, adding one, flags and tags and priorities, dates and the
  eight views, subcards, the wiki, search and Ask, automations, the AI
  assistant, sharing, and the CLI and API. Each says what to try and where it
  is.
- **An epic** — "Break a big job into subcards" — which actually has a board
  of its own, with four subcards, one of them genuinely blocked by another, so
  the roll-up, the breadcrumb and the dependency badge are real rather than
  described.
- **A card in Done**, a card in In Progress carrying a checklist, a comment, a
  flag and dates, and two in the Backlog. Every list has something in it: a
  board with an empty Done column is the one part of a new install that reads
  as broken when it is only new.
- **A working automation** — *when a card lands in Done, comment on it* — on
  the board's Automations tab. It emails nobody and waits on no clock, so the
  first automation anybody sees is one they can trigger in five seconds.
- **Three wiki pages**: *Welcome to your wiki*, pinned to the card that sends
  you there, with two pages nested under it that are the two shapes worth
  having — a decision and a runbook. The welcome page is written in the markup
  it is explaining: `[[links]]`, a wanted link, a `[[!children]]` directive and
  a live ```` ```slipdock ```` query block that answers itself when you read it.

The board is nobody's permanent furniture. The last card says so: archive it
from the board index when the tour is done, which keeps everything on it and,
on a metered server, hands the card allowance back.

**Who gets one.** Somebody who owns no boards. An owner of real boards is not
somebody who needs a tutorial, so that case is skipped.

**Switching it off.** `SLIPDOCK_WELCOME_BOARD=0`. The manual half keeps
working either way:

    mix slipdock.welcome you@example.com [--force]   # from a checkout
    docker compose run --rm slipdock welcome you@example.com [--force]
    slipdock welcome [--force]                       # as yourself, over the API
    curl -s -X POST -H "$H" B/api/boards/welcome

which is also how an account that archived the tour, or one made before the
tour existed, gets one.

## Swimlanes

The **Swimlanes** button in a board's header switches to a grid view. Every
setting lives in the URL, so a configured grid can be bookmarked or shared.

- **Rows / Columns** — the attribute on each axis: none, list, priority, tag,
  flag, status (open/completed), cover colour, due date, created, last updated.
  Cards with several tags or flags appear in each matching group.
- **Dates** — when either axis is a date, group by days, weeks, months,
  quarters or years. The bucket containing today is marked *now*; past due-date
  buckets are tinted red.
- **Sort** — board order, title, priority, due date, created or last updated,
  ascending or descending, inside each cell. Cards without a value (no due
  date) always sort last.
- **Filter** — search, kind (cards / documents / wiki pages), tags,
  priorities, flags, lists, due (overdue / today / next 7 days / next 30 days /
  has a date / no date), status (all / hide completed / only completed), cover
  colour.
- **Display** — comfortable or compact cards; show empty groups (which also
  fills gaps between date buckets); **List width** — narrow, normal, wide or
  extra wide. The board view's Display menu has the same *List width*, which
  sets how wide every list is drawn (on a phone a list still fills the
  screen). Like the rest of the Display menu it is kept in the URL and in a
  saved view.
- **Drag and drop** between cells changes the card to match the target cell:
  its list, priority, status, colour or due date (set to the start of the
  bucket), or swaps the source tag/flag for the target one. Created / updated
  axes can't be dragged into. In *board order* a drop between two cards also
  reorders them.
- **Add** inside a cell creates a card with that cell's attributes.
- Click a row header to collapse it.
- **Dependencies** — an axis with Blocked / Blocks others / No dependencies
  groups, and a filter (blocked, not blocked, blocks others, none). Cards are
  moved between these by editing the card, not by dragging.
- **Views** — save the current configuration under a name. Loading a view puts
  `?view=ID` in the URL; any further change is shown as *modified* with
  *Update* / *Revert* buttons, and only the delta is added to the URL. Views can
  be renamed and deleted from the same menu.

The grid and saved views are also available over the API and CLI (`slipdock swimlanes`, below).

## Table

The **Table** button shows one row per card. Click a header to sort by it
(again to flip the direction), choose which columns to show under
**Display** (list, priority, flags, tags, due, done, checklist, comments,
dependencies, subcards, cover, created, updated, id), and pick **Group by**
to split the rows into collapsible groups by any attribute, including date
buckets. List, priority, due date and done are edited in place; the title
opens the card. The filter menu, search, density and saved views are shared
with the swimlane view, and a saved view remembers which of the two it was
made in. `slipdock table <board>` prints the same thing in the terminal.

## Timeline

The **Timeline** button draws a bar per card from its start date to its due
date (a card with only one of the two is a one-day marker). Pick the
**zoom** — days, weeks, months, quarters or years — and page with the
arrows; *Today* jumps back. Drag a bar to move the card, or drag its edge to
change one date; the change snaps to whole days. **Group by** splits the
rows by any attribute, and cards without dates wait in an *Unscheduled* tray
below with a date picker each. Filters, search, sort, density and saved views
are shared with the other views; the page you are looking at is not part of a
saved view.

A card without dates of its own is placed by the dates rolled up from its
subcards; such bars are outlined and can't be dragged. When the board has
subcards, a **levels** control hangs the scheduled subcards beneath each bar,
indented, to the depth you choose — collapse a bar's subcards with its
chevron. A saved view keeps the depth along with the zoom, so "Roadmap by
quarter, one level" and "Delivery plan by week, three levels" can be two
views of the same board.

## Calendar

The **Calendar** button shows a month (or, from the span menu, a week) with
each card on its due date — or its start date when it has no due date. Drag a
card to another day to reschedule it (a card with both dates keeps its length);
drag it into the *No date* tray to clear its dates. The *+* on a day adds a
card due that day, and *+N more* expands a busy day. Filters, search, sort and
saved views work as in the other views.

### Moving a card between lists

Dragging is the quick way with a mouse, and was the only way — which on a
phone meant dragging a card across a board showing one list at a time. Two
other routes now do the same job at any size:

- The **→** button on a card (hover on a desktop, always there on a touch
  screen) opens a **Move to** menu of the board's lists. It is a native
  popover, drawn above the list's own scrollbox rather than clipped by it.
- The card's own **in list** line, directly under its title in the card
  modal, is a list picker. The sidebar keeps its copy of the same field.

### Moving a card to another board

Dragging cannot cross a board — the other board is not on the screen — so the
only way there used to be to retype the card and delete the original, losing
its comments, its history and its subcards. **Another board…** at the foot of
the **Move to** menu, and next to **in list** on an open card, opens a picker:
the boards you can write to, then that board's lists. Two taps on a desktop
and the same two on a phone, where the picker is full screen and stands in for
the card while it is open.

What crosses with the card:

- **Subcards, comments, history, checklists, attachments, dependencies and
  links** — all of it, however deep the subcards go. The boards beneath the
  card are re-rooted so their own tags and fields keep resolving.
- **Tags travel by name**, matched on the destination board and created there
  when they are new — for the card and everything under it, because a
  subcard's tags came from the old board too.
- **Custom field values** survive where the destination has a field with the
  same key *and* kind, and are dropped where it does not: a number cannot be
  stored in a date. A **pinned milestone** is unpinned — it is a date on the
  old board's roadmap and stays there.

The flash afterwards says what any of that cost, and both boards record the
move in their activity. Landing in a *done* list completes the card, and a
horizon list schedules it, exactly as a move within one board does. A card
cannot be moved into its own subcards, and an archived card has to be restored
first.

### Changing several cards at once

**Select** in the board view's toolbar turns on select mode. Clicking a card
then picks it out — a ring and a tick — instead of opening it; clicking it
again lets go. A bar along the bottom counts what is picked out and changes
all of it in one go:

- **Complete**, **Reopen**, **Assign me**, **Unassign**, **Archive** and
  **Delete** (which asks first: it cannot be undone).
- **Set…** — add or remove a tag, set the priority, add or remove a flag.
- **Move to…** — any list on this board, or on another board you can write
  to, with everything a single move carries (see above).

Each card is changed as it would be one at a time, so automations, history
and search see every change. One card refusing — a move into its own
subcards, a full account — does not stop the others; the flash names it and
says why. **Done** leaves select mode. From a terminal, `slipdock archive`,
`restore`, `delete`, `done` and `undone` already take several card ids.

## Time tracking

Every card has a **Time** section in its panel, under the list, priority and
dates:

- **Spent** and **Estimate** are typed in the card's **unit** — minutes, hours,
  days, weeks or months, hours unless you change it. A bare number is in that
  unit; a suffix says otherwise, so `90m`, `1.5h`, `2d`, `1w`, `1mo` and
  `1h 30m` all work wherever a time is asked for. Leave the estimate empty to
  have none.
- Both are kept in minutes, and the unit is only how they are shown: switching
  a card from hours to days changes nothing recorded. The longer units are
  working time — **a day is 8 hours, a week 5 days, a month 4 weeks** — so an
  estimate of `2d` is 16 hours of work, not 48 of the clock.
- **Start timer** runs a clock on the card, counting up on the button; **Stop**
  adds what it ran, to the nearest minute, to the time spent. Starting a timer
  that somebody else already started leaves theirs running. The time is kept
  on the server, so closing the tab does not stop it.
- **Log time** adds a stretch by hand — `45m`, `2h`. A minus sign (`-30m`)
  takes time off, never below nothing.
- The **bar** is time spent (with a running timer's time so far) against the
  estimate. It is green below 80%, amber from 80% to 100% and red past it; over
  the estimate it fills and a tick marks where the estimate fell, and the text
  says by how much it ran over.

On the board, **Time tracked** is a card facet (shown on the full card face
of a new view; tick it under display options in a view saved before): a clock
chip, `1.5h/4h` with a small bar in the same colours, pulsing while a timer
runs. The table has a **Time** column. Every change — set, logged, timer
started and stopped — goes in the board's activity, and exports carry time
spent, the estimate and the unit.

From the CLI:

```sh
slipdock edit 12 --estimate 2d --unit days      # the estimate, and how the card shows time
slipdock edit 12 --spent 3h                     # set what has been spent;  --no-estimate clears one
slipdock log 12 45m                             # add time by hand  (edit 12 --log=-15m takes some off)
slipdock timer 12 start                         # ... later:
slipdock timer 12 stop                          # adds the minutes it ran
slipdock card 12                                # Time: 1.25d spent of 2d estimated (63%)
```

## Where it was left (handoffs)

Work on a card spans sittings, people and tools: a Claude Code session, a
runner pass, you at a browser. A **handoff** is the one short note on a card
that says where it was left, so whoever picks it up next, person or agent,
reads that first instead of piecing the state together from the comments.

It is a **next step** (one line, at most 280 characters, required) and a
**note** (Markdown, at most 8000), usually in this shape:

```
State:     what is done and what is half-done
Next:      the one next step
Gotchas:   what bit me / what not to try again
Open:      questions waiting on someone
Pointers:  branch, files, commits, pages (W-…)
```

Most cards never need one, so until one is written it is just a **Leave a
handoff** link on the line under the card's title (beside its `#id`, list and
age). Once there is one it sits straight beneath the title: *Left off — next:*
and the next step, the note, who left it, when and how (the web app, the API,
MCP, the CLI or a runner), and, once there has been more than one, a
**History** of every earlier one. **Update** writes a new one; nothing is
edited in place, so the history is the whole story. **Clear** writes an empty
one, and the history keeps that too; the card goes back to the link.

**Auto generate**, in the handoff's form when you have an [AI model](#ai-assistant)
set up, drafts the next step and the note for you from what has happened on
the card lately: the last fortnight of its activity, its comments, checklist
and status updates, with the rest of the card and the handoff before this one
behind them. The draft goes into the form's fields, replacing what was there;
nothing is written until you change what needs changing and press **Save
handoff**. While the card is open its front carries a ↩ mark with the next step as
its tooltip; a completed card keeps its note but loses the mark.

Anyone who can comment on a card can leave its handoff, since it is a kind of
comment; a reader sees it but can't write one. Each one is a line in the
board's activity.

Comments stay the running log and status updates the stated health; the
handoff is the *now*. Write one whenever you stop with a card unfinished.
Agents are told the same: the guide says to read a card's handoff before
starting it and to leave one when stopping, `get_card` puts it first, and the
`slipdock-work` and `slipdock-loop` skills do both. A [runner](#runners) job
that ends with its card still open leaves its summary as the handoff (its first
line is the next step), unless the agent left one itself during the job.

```sh
slipdock handoff 12 --next "Write the rounding test" --body "State: fix is in, untested"
slipdock handoff 12 --next "Ship it" --file note.md      # or --body - to read stdin
slipdock handoff 12                                      # the handoff and its history
slipdock handoff 12 --clear
```

Over the API, `POST /api/cards/:id/handoff` with `next_step` and `body` (or
`{"clear": true}`) writes one and `GET` reads it with its history; a card's JSON
carries it as `handoff`. Over MCP it is the `leave_handoff` tool. Exports
between servers carry every handoff, signed by whoever imports them.

## Waiting on a person (waits)

A card that can't go on until somebody answers something — a decision, a
credential, an approval — gets a **wait**: what it needs, who it waits on (a
named person, or anyone), when it was opened and, optionally, a short list of
answer choices. A card has at most one open wait. It flags the card
`waiting` and comments the question, so the board and every filter that
skips waiting cards already know; unlike the bare flag, it has a clock, an
owner and a way back.

While one is open it sits beneath the card's title — *Waiting on Dana:* and
the question, who asked it and how long ago — with a button for each choice,
a box for an answer in words, **Answer** and **Withdraw**. The answer is
posted on the card as a comment from whoever answered and clears the
`waiting` flag if the wait set it. Taking the `waiting` flag off by hand
withdraws the wait, with a comment naming who did. Completing or archiving
the card closes its wait with that reason. Anyone who can change the card
can answer, from the card, [My work](#roll-ups-the-outline-and-my-work), the
CLI, the API or MCP; an agent can't answer a wait it opened itself, and a
person can always answer or withdraw their own.

```sh
slipdock wait 12 "Which region?" --on dana@example.com --choice eu --choice us
slipdock wait 12 --withdraw
slipdock answer 12 --choice 1                  # or: slipdock answer 12 "eu, for the data rules"
slipdock work                                  # what is waiting on you, oldest first
```

Over the API, `POST /api/cards/:id/wait` (`needs`, `on`, `choices`) opens
one, `POST /api/cards/:id/wait/answer` (`answer`, `choice` counted from 1)
answers it and `DELETE /api/cards/:id/wait` withdraws it; a card's JSON
carries the open one as `wait`. Over MCP it is `update_card` with `wait`
(`null` withdraws) or `answer_wait`.

Agents are told to open a wait, say what they need and stop, rather than
flag the card and hope. A wait opened from a [runner](#runners) job
**parks** the job, and answering it sends the card to the same rule again
with the question and the answer on top of the prompt.

**Waiting on you.** My work opens with everything that needs you, oldest
first, each with why and for how long: open waits on you, and on anyone on
cards you own or are assigned; your cards flagged `review` or `waiting`;
cards the runner gave up on, or whose newest job failed, on boards you own;
and, for a board's owner, cards in an in-progress list for over an hour with
nobody on them. A wait's choices and answer box are right there. The header
shows how many on every page (refreshed within a minute), `slipdock whoami`
and `GET /api/me` carry it as `waiting_on_you`, and `slipdock work`, `GET
/api/work` and the `plan-my-day` prompt list them.

## Flow: the pulse, a card's state and its age

Every card move is recorded with where it came from, where it went, when,
and who made it — a person, an agent or an automation — and the board works
its flow numbers out from that record.

**The pulse.** Cards in progress, cards waiting on a person (and the oldest
wait), cards done in the last 7 days (and today), the typical (P50) and slow
(P85) time to done, moves in the last 24 hours forward and back, and each
list's in and out over 7 days with its usual stay. `slipdock pulse <board>`,
`GET /api/boards/:id/pulse` and MCP `get_board` with `pulse: true` answer it
on every board; **Show the board's pulse** in the board's settings
(`slipdock set-board <board> --show-pulse`) puts it in plain words over the
lists. Off by default.

**A card's state.** A card with a job or a wait on it shows one line on its
front — *Running · runner-2 · 7m*, *Queued · dev · 3m*, *Held · paused by
David: bad deploy*, *Waiting on Dana · 41m*, *Failed · runner-2 · 2h ago* —
with its handoff's next step after it when there is one. A card with
neither shows nothing. On a board tree with runner rules, a small mark says
whether an agent or a person holds it.

**Its age.** A chip says how long the card has been in its list, and turns
amber, with how far over, once that is past the list's usual stay (the time
85 in 100 cards spent there). Never on a done or dropped list, a card with an
open wait (the person is the hold-up), or where there is too little history.

The board's **Filter** menu has *Time in list* (only cards past their list's
usual stay) and, on runner boards, *Driver*: All, Agent or Human. The API, MCP and CLI carry the same
`state`, `held`, `driver`, `in_list_since`, `age`, `usual_stay`,
`over_usual` and `stuck` on each card, and filter on them:
`slipdock cards <board> --stuck --driver agent`,
`GET /api/boards/:id/cards?stuck=true&driver=agent`, MCP `list_cards` with
`stuck` and `driver`.

**Its timeline.** Near the bottom of the card, the **Timeline** draws what
the card has been through on one time axis, from its first record to now:
a lane of the lists it has sat in, coloured by the list's category (to do,
in progress, done, dropped, and grey while archived); a lane of its waits on
a person; and a lane of its runner jobs. Hover a span for when, how long,
and who moved it. A stay recovered from the old activity log whose end the
history can't vouch for is faded and dashed. Under the lanes, *stays in
lists* lists the same stays as text. Over the API it is
`GET /api/cards/:id/timeline` (`stays`, `waits` and `jobs`, each with
`from`, `to`, `seconds` and `open`), over MCP `get_card` with
`timeline: true`, and on the command line `slipdock timeline <id>`.

## Delivery metrics: deploys and DORA

A board can record its project's deploys and say how it delivers. Off on
every board until its owner ticks **Delivery metrics** in the board's settings
(`slipdock set-board <board> --delivery-metrics`); while it is off the board
refuses deploys and shows nothing.

**Setting it up.** **Track deployments** in the board's settings asks three
things — which CI runs the deploy (GitHub Actions, GitLab CI, or another CI or
a shell script), the environments it deploys to, and how commit messages name
cards (`#123` unless you give a pattern) — then turns Delivery metrics on,
issues the board's **deploy token** and shows it once, with the step to paste.
The token records deploys for this board and can do nothing else; keep it as
the CI secret `SLIPDOCK_DEPLOY_TOKEN`. The panel waits for the first deploy and
turns green when it arrives. **Set this up for me** gives a prompt to paste into
Claude Code in the repository instead: it finds the deploy step, wraps it, tells
you the secret to add and tries it with `--dry-run`. The same from a terminal:
`slipdock deploy setup <board> [--ci github|gitlab|shell] [--env production]
[--prompt]`, and `slipdock deploy token <board> [--revoke]` for a new token.
Worked examples are served at `/deploy/examples/` (`github-actions.yml`,
`gitlab-ci.yml`, `deploy.sh`, and `curl.sh` for where the CLI can't go).

**Recording deploys.** In CI, wrap the deploy command:

```sh
slipdock deploy run --env production --tag "$TAG" -- ./deploy.sh "$TAG"
```

It asks the board for the environment's last deployed commit, sends the
commits since then (so the job needs the whole history: `fetch-depth: 0`),
records the deploy started, runs the command, and records it succeeded or
failed from its exit code, which it exits with. A board that can't be reached
never stops a deploy. Deploying a commit older than the last deploy is
recorded as a **rollback**. Where the deploy is more than one command,
`slipdock deploy start` prints an id and `slipdock deploy finish --id N
--status succeeded|failed` ends it. `slipdock deploy backfill --from-tags
[--pattern 'v*']` records past releases from git tags, once.

**Incidents** are ordinary cards tagged `incident` (the tag is a board setting).
`slipdock incident-of <card> <deploy>` says which deploy caused one. A deploy
is a **failed change** when it failed, was rolled back, has an incident linked
to it, or was followed within the hotfix window (24 hours, a board setting) by
a deploy whose commits name an incident card.

**The numbers**, for one environment over 30 days, each with the window
before: deployment frequency, lead time for changes (commit → deploy, P50 and
P85), change failure rate, time to restore (an incident card's creation to its
completion, or a failed deploy to the next good one), rework rate (deploys
naming an incident card), and **idea to production** — a card first entering an
in-progress list to the first deploy whose commits name it. Each has its DORA
band (elite, high, medium, low) where DORA defines one. A strip over the lists
says it in a line; `slipdock dora <board> [--env E] [--days N]`, `GET
/api/boards/:id/dora` and MCP `get_board` with `dora: true` give it all.

**Shipped lines.** A card a succeeded deploy names shows *Shipped to production
· 1a2b3c4 · 19 Oct* — one line per environment, and *rolled back since* when a
rollback went past it — in its panel, in `slipdock card` and as `shipped` in
its JSON.

## Recurring cards

Repeating work — "every Monday: review invoices", "first of the month: renew
the certificate", "water the plants three days after I last did" — lives on
the card it repeats. The card is the series' current instance; when the next
one comes due, the server makes it by **copying the current instance as it is
then**, so a checklist or description you improve carries forward.

**Setting it.** On the card, under **Repeat**, press **Repeat…**. Pick a
preset, worded for the card's date — daily, every weekday, weekly on its day,
monthly on its date, monthly on (say) the second Tuesday, yearly, or a week
after the last one is done — or **Custom…** and write a rule of your own.
Then the time each one is made (07:00 unless you say), how many days early to
make it, what happens if the last one is still open, and when it ends (never,
on a date, or after a number of times). The form shows the rule in words —
*Every 2 weeks on Mon and Thu, 07:00 Europe/London* — and the next three
dates before you save. Afterwards the same place shows what is next, with
**Skip next**, **Pause**/**Resume**, **Change…** and **Stop**, and the card's
front carries a **↻**, the rule as its tooltip.

A card with no due date becomes the series' first occurrence: it is given the
first date the rule falls on from today.

**Rules.** The phrases quick add, the CLI and the API take:

| Phrase | Means |
| --- | --- |
| `day`, `3d` | every day, every 3 days |
| `weekday` | Monday to Friday |
| `mon`, `mon,thu`, `2w mon thu` | weekly on those days, every 2 weeks |
| `week`, `2w`, `fortnight` | on the first instance's weekday |
| `month`, `month 1`, `month 15th`, `month last` | monthly on the first instance's date, the 1st, the 15th, the last day |
| `month first mon`, `month last fri`, `3m 1` | the first Monday, the last Friday; every 3 months on the 1st |
| `year` | yearly on the first instance's date |
| `3d after`, `2w after`, `month after` | that long after the last one is **done** |

Or an RRULE subset: `FREQ=DAILY|WEEKLY|MONTHLY|YEARLY` with `INTERVAL`,
`BYDAY` (`MO`, or `1MO`/`-1FR` in a monthly or yearly rule) and `BYMONTHDAY`
(`-1` is the last day). A day past the end of a short month — the 31st in
April, 29 February in 2027 — falls on that month's last day rather than
being skipped.

**When the next one is made.** Each instance is made at its time, in the
series' timezone, on the day it is due (or the days early you set), copied to
the top of the board's ready list (or the list you named):

- title, description, priority, cover, tags, assignees, the estimate and flags
  come along, except *blocked* and *waiting*, which were about the last one;
- the checklist comes along unticked, and subcards are copied into a new
  sub-board, every one reopened in its ready list;
- comments, dates other than the new due date, time spent, attachments, links
  and dependencies don't.

**Not stacking up.** If the last one is still open when the next is due, the
default (*Move its due date on*, `bump`) moves its due date to the new
occurrence and comments "Missed occurrence of …", so a forgotten weekly chore
is one card, not six. *Skip this one* (`skip`) leaves it alone and lets the
occurrence go; *Make another anyway* (`stack`) makes the new one regardless —
right for timesheets. A server that was down catches up once, to the latest
occurrence, never one per missed date.

**After done.** An after-done series makes nothing until its current instance
is completed; then the next is due that long after the day it was done (in
the series' timezone), and it waits again.

**Timezones.** Times are in the timezone of whoever set the series, kept on
the series, so it doesn't move if they travel. Yours is taken from your
browser the first time you sign in and can be changed under **Account →
Profile**. The older *schedule* automation trigger still runs in UTC.

**What else touches it.** Archiving the current instance pauses the series
(the card says so); deleting it stops the series. Moving the card to another
board takes the series with it. Exports between servers carry the series and
carry on from where it had got to. If the board's owner is out of cards, the
series pauses and the card says why, rather than trying every minute.

From a terminal and over the API:

```sh
slipdock repeat 12 "every mon" --at 08:00          # or --lead 2, --ends 2027-06-30, --count 10
slipdock repeat 12 "month last fri" --on-missed stack
slipdock repeat 12                                 # how it repeats, and the next three dates
slipdock repeat 12 --skip | --pause | --resume | --off
slipdock recurring ops                             # every card on the board that repeats
```

```
PUT    /api/cards/:id/recurrence       {"rule": "every mon", "at": "08:00", …}
GET    /api/cards/:id/recurrence
DELETE /api/cards/:id/recurrence
POST   /api/cards/:id/recurrence/skip
GET    /api/boards/:board/recurring
```

A card's JSON carries `recurrence` (and `series_id` on every instance); over
MCP, `get_card` shows it and `update_card` takes `recurrence` (an object, or
`null` to stop it).

**Duplicate.** The same copy, made by hand: **Duplicate** in the card's
Actions puts a copy straight after it and opens it (`slipdock copy 12`,
`POST /api/cards/:id/copy`, with `board`, `column`, `title` or `at: top`).

## Snoozing cards

Most open cards on a board that lives for years are not actionable *this
week*: they are waiting for a date, a person or a quarter. **Snooze** hides a
card until a day, then brings it back at the top of its list.

**Snoozing.** On the card, under **Snooze**, press **Snooze…** — or on the
board press `z` over a card (the one the keyboard is on, else the one under
the pointer, else labels to pick one). The picker offers **Tomorrow** (`z`),
**Next Monday** (`m`), **In a week** (`w`) and **Next month** (`n`), so `z z`
snoozes until tomorrow; or pick a day of your own, add a note ("waiting for
the vendor's quote"), and tick **Tell me when it wakes**. A day means
midnight in your timezone. A card in an in-progress list is offered a move
back to the ready list as it goes, and one due before the day you pick says
so, with *past due* against the presets that would sleep through it. In
select mode, **Snooze…** snoozes every card picked out. A completed card
can't be snoozed.

**While it sleeps** it is left out of:

- the board's lists — each list's foot says *💤 3 snoozed*, and clicking it
  shows them in place, faded, with the day each wakes, until you hide them
  again;
- swimlanes, the table and the outline, unless you turn on **Show snoozed**
  in the view's display options (saved with a view, like the rest);
- My work, the runners' pick from the top of a list, `--deps ready`, and
  the agents' guide's "open" counts, which show "snoozed N" instead;
- the stale, due-soon, overdue and starts-soon automation triggers: an
  overdue card that is snoozed is a deliberate choice, not news.

It still appears in search (marked 💤 with the day it wakes), on the calendar
and the timeline by its own dates (faded), on its own link, and in roll-ups —
a snoozed subcard still counts as open, so an epic is never done because its
remaining work is asleep. A sprint shows its snoozed cards: a sprint is a
deliberate commitment.

**Waking.** On the day, the server's clock (once a minute) clears the snooze,
moves the card to the top of its list and writes "woke up (snoozed by Ann on
Tue 3 Nov: waiting for the vendor's quote)" in the activity log; with **Tell
me when it wakes**, an alert goes up on the board too. **Wake now** on the
card wakes it by hand. It also wakes when **someone else** comments on it or
assigns it to someone new — a snoozed card people are talking about is no
longer asleep (the API's `wake_on_activity: false` keeps it asleep). An
automation can start from it: the trigger *a snoozed card wakes up*
(`card_woken`). Archiving a card clears its snooze, and an export to another
server keeps one that is still ahead.

From a terminal and over the API:

```sh
slipdock snooze 12 next week --note "waiting for the quote"   # or 2026-11-02, mon, in 3 days
slipdock snooze 12 13 14 tomorrow --notify
slipdock wake 12
slipdock cards ops --snoozed only                              # or include
```

```
POST   /api/cards/:id/snooze   {"until": "2026-11-02", "note": "…", "notify": true, "wake_on_activity": true}
DELETE /api/cards/:id/snooze
GET    /api/boards/:board/cards?snoozed=exclude|include|only
```

A card's JSON carries `snoozed_until` and `snooze` (until, note, who, when,
notify, wake_on_activity), both `null` when it isn't snoozed. Over MCP,
`get_card` shows it, `update_card` takes `snoozed_until` (a date, datetime or
phrase; `null` wakes it) and `snooze_note`, and `list_cards` takes `snoozed`.
Quick add takes `snooze: mon`.

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
| In progress, untouched | a card in an in-progress list with no activity — no edit, no comment, nothing in its log — for 14 days | move it back to the ready list; or snooze it a week, or ask on it |
| Epics with no next step | an open epic with subcards, none of them open, its work not all done | flag it for review, with a comment saying so |
| Long overdue | an open card due more than 30 days ago | give it a new date a week out; or snooze it, or archive it |
| Abandoned in the backlog | a card in a to-do list untouched for 180 days (off unless you turn it on) | archive it (it can be restored) |
| Possible duplicates | two open cards whose title and description read alike (similarity 0.92 or more, from the vectors search already keeps), not already linked | link them as duplicates and archive the one you don't keep |
| Pages nothing links to | a wiki page more than 30 days old with no backlink, no pin and no folder (templates, drafts, pages on a list, pages with pages beneath and folder indexes are never orphans; nor is a page that links to a card — it shows in that card's Docs) | archive it, or file it into a folder |
| Links that nearly match a page | a `[[link]]` to a page that doesn't exist whose title matches one page's title or alias ignoring case, or is within two edits of exactly one (two candidates suggests nothing) | rewrite the link to that page, on every page that has it |

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

**Choosing the checks.** Board settings → **Gardening** has each check on or
off, and its thresholds: days for the stale, overdue, backlog and orphan
checks, the similarity and card cap for duplicates, the number of edits for
links. Everything but *Abandoned in the backlog* is on to begin with.

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

A suggestion carries `check`, `label`, `explanation`, `cards` and `pages`
(ids and titles), `proposal` (the steps: `complete`, `move`, `archive`,
`link_duplicate`, `flag`, `comment`, `snooze`, `redate`, `rewrite_link`,
`file_page`), `alternatives` (by name) and `needs_keep`. Over MCP, `garden`
lists them (`run: true` looks the board over first) and `garden_decide`
applies, dismisses or undoes one with `confirm: true` — an agent shows you the
suggestions and applies only what you approve.

## Dependencies

Open a card and use the **Dependencies** section: pick *Blocked by* or
*Blocks*, search for another card, and click it. The search covers every
board you can open, this one's cards first; a card on another board shows that
board's code, here and in the list of dependencies. So a subcard can wait on a
subcard of another epic, or on a card on a different board altogether. You need
to be able to edit the card that waits and to see the one it waits for. A card
is *blocked* while any card it depends on is open (not completed, not
archived); blocked cards show a red lock badge with the count, and cards that
hold others up show an arrow badge. Self-links and anything that would form a
cycle, across however many boards, are refused. Removing a card removes its
links. Somebody who can see one end of a dependency but not the other sees
*A card you can't see* in its place: the card still counts as blocked, but its
title and board stay private. Each board's history records the dependency, and
names the card on the other board only by number.

## Subcards and templates

Open a card and click **Add subcards** in the Subcards section, then pick a
template. The card gets a **sub-board**: a real board with the template's
lists, named after the card and sharing the parent's colour. Everything a
board can do works inside it — drag and drop, swimlanes, saved views, the
API and the CLI — and sub-boards nest to any depth. The card modal shows the
subcards grouped by list with a progress bar, lets you add and tick them off,
and has an **Open board** button; the card itself carries a `done/total`
badge. The sub-board's header shows a breadcrumb back through every parent.

Tags are shared by a whole board tree: they live on the root board, so a tag
created on a sub-board is available everywhere under that root. Renaming a
card renames its sub-board. Deleting a card, or **Remove subcards**, deletes
the sub-board and everything on it, files included: the attachments of every
card beneath it, its wiki pages' images and its meeting recordings are removed
from disk, as are those of every card when a list is deleted with its cards.
The board index lists root boards only.

**Templates** are named lists of columns (name, optional WIP limit, colour).
Seven ship by default (Slipdock, Simple, Checklist, Bug triage, Research,
Roadmap — Now · Next · Later · Done, for the top of a tree — and Sprint
planning, below); manage them at `/templates`, pick one when creating a
board, or save any board's current lists as a template from its settings.

The ones that ship are **built in**: everybody sees them and nobody, an
admin included, can change or delete them. A template you make — at
`/templates`, from a board's settings, or by saving a new board's lists —
is **yours**: only you see it in a picker, and only you can edit or delete
it. Its name has to be new among your own templates and the built-in ones;
somebody else may have one called the same. Deleting an account deletes
that person's templates (boards already made from them keep their lists).

Or set the lists out when you create the board: pick **Custom lists…** in
the **Lists** menu and type them one per line. A list named like To Do, In
Progress or Done is given that role (the rest can be set in the board's
settings); tick **Save these lists as a template** to keep them for next
time, under a name of your own or the board's. A template name that is
already taken stops the board being made too, so you can pick another.

## Simple boards

Not every board is a project. A shopping list, a household to-do list or a
reading list has no use for start dates and health, and a card that offers
them all is a card that looks harder to fill in than it is. Tick **Simple
board** in a board's settings and it becomes a plain to-do list:

* the card leaves out **% complete**, **start date** and date precision, the
  dates rolled up from subcards, **health** and health reports, **time
  tracking**, **votes** and **Dependencies**;
* tiles drop the matching badges, and the **Display** menu stops offering
  them;
* the view menu leaves out **Timeline** and **Prioritise**.

What stays is what a to-do list needs: the title and description, the list,
assignees, priority, the due date, Completed, flags, tags, the checklist,
attachments, subcards, docs, links, comments, the cover and any custom
fields. Nothing is deleted — a card that had a start date still has it, and
unticking the setting brings everything back. Subcards made on a simple
board are simple too; each board keeps its own setting after that. From the
command line it is `slipdock set-board <board> --simple` (or `--no-simple`),
and over the API `PATCH /api/boards/:board {"simple": true}`.

## A board's default view

A board opens on its kanban, but not every board is mostly looked at that
way. A board that is really a handbook wants its **Wiki** first; a backlog
might want its **Table**. Pick **Default view** in a board's settings —
Board, Swimlanes, Table, Timeline, Calendar, Outline, Narrative, Prioritise
or Wiki — and opening the board from the board list, the board switcher
(<kbd>b</kbd>) or Favourites lands there. The view menu still reaches every
view, and the board's own address (`/boards/:id`) still shows the kanban.
A simple board has no Timeline or Prioritise, so if it was set to one of
those it opens on the board until simple is turned off again. Only a
top-level board has the setting: a sub-board is opened from its card. From
the command line it is `slipdock set-board <board> --default-view wiki`, and
over the API `PATCH /api/boards/:board {"default_view": "wiki"}`; a board's
JSON reports `default_view` (`"board"` when none is chosen).

## Sprints

A sprint is made of things a board already has: a card for the sprint, its
dates for the sprint's dates, and its subcards for the sprint's work. What a
sprint board adds is the setting up.

**A sprint board.** Make a board from the **Sprint planning** template
(Planned · Active · Closed), or tick **Sprint board** in an existing board's
settings. Every card on it is a sprint.

**New sprint.** The button in a sprint board's header opens a short form,
already filled in: the next name ("Sprint 4", counting on from the highest
"Sprint N" on the board), a start the day after the last sprint ends (today
when there is none), a length — 14 days unless you change it — and an
optional goal, which becomes the card's description. Creating it makes the
card in the first to-do list, gives it its own board of subcards (the Simple
template's To Do · Doing · Done), and goes straight on to picking its cards.

**Where sprints are planned from.** Sprints on one board almost always draw
from the same few lists — a team's backlog, an epic board's To Do. Choose
them once: when making a board from the Sprint planning template, **Plan
sprints from** lists the boards you can write to; tick a board, then, if you
want only some of its lists, tick those (none ticked means every list that
is not done or dropped). The same choice is under **Plan sprints from** in
the board's settings, and behind **Sources** in the picker. Over the API it is
`PUT /api/boards/:board/sprints/sources`; on the command line `slipdock
sprint-sources <board> work:"To Do",Backlog home`.

**The plan.** With sources chosen, **Add cards…** opens on the plan: every
source list at once, grouped by board, each open card on a row with its
priority, the board's formula scores (RICE, ICE, value ÷ effort or your
own), votes, estimate — its own, or **Σ** what its open subcards add up to —
how far its subcards have got, and its due date. A card with subcards opens
in place with the chevron, as in the outline view, and its tasks can be
ticked on their own. **Order** puts each list in board order, or by score,
priority or estimate. As you tick, the foot keeps count: the cards and hours
ticked, what the sprint already holds, and the two together over the
sprint's days (a task inside a ticked epic is not counted twice). **Other
boards…** switches to the board-by-board picker below for anything outside
the sources; ticks are kept between the two. `slipdock sprint-plan
<sprint-id>` prints the same plan.

**Add cards… without sources.** On a sprint — the button in its card's
Subcards section, or in the header of the sprint's own board — with no
sources chosen this opens a picker. Choose a board
you can write to and its lists appear, each open card with a tick box and
each list with **tick all**. A card that has subcards has a **subcards ›**
button to step into them, which is where an epic's tasks are. Ticks are kept
while you move between boards, so one sitting can draw from several; **Add to
sprint** moves everything ticked into the sprint's first to-do list. Nothing
needs doing in one go: open the picker again whenever there is more.

Picked cards are *moved*, exactly as [Moving a card to another
board](#moving-a-card-to-another-board) does it — subcards, comments and
history go with them; tags travel by name; custom fields only where the
sprint's tree has the same one. Completed and archived cards are not
offered. On a sprint board itself the cards are other sprints, so they cannot
be ticked whole; step into one to take what it left unfinished.

**Stand-ins.** A card picked into a sprint leaves a *stand-in* in the slot it
came from — a dashed tile with the card's title, the sprint it is in and a
status badge (To do, In progress, Done, Dropped) — so whoever put it on that
board does not lose track of it. Nothing on the stand-in is its own: the
title, the sprint and the status are read live from the real card, the
status from its list's category rather than its list's name, so the two
boards' lists need not match. Clicking it opens the real card on the sprint's
board, where its comments, checklist and history are; somebody who can see
the board it left but not the sprint still sees the title and status, but
cannot open it.

A stand-in can be dragged about its board and dismissed with its **×**, but
not edited. It is not work: it does not count towards a list's WIP limit, the
account's allowance, a parent's rollup or a sprint's burndown, it is not
offered for sprints or found by search, and automations ignore it. When the
real card reaches a done list, its stand-in moves to the done list of its own
board. A card carried over into the next sprint leaves no second stand-in —
the first one already follows it. Moved back to the board it came from, the
card takes its stand-in's slot and the stand-in goes. If the real card is
archived or deleted, the stand-in says so and waits to be dismissed. Exports
leave stand-ins out.

**Charts.** The **Charts** button in a sprint board's header, or in the
header of a sprint's own board, opens two charts (anyone who can read the
board can see them):

- **Burndown** — a sprint's work still open at the end of each day from its
  start to its due date, against a dashed ideal line falling straight to
  zero. The work is the cards on the sprint's own board, not archived; the
  scope is what is in the sprint now, so a card added halfway counts from
  the first day. Days still to come are left blank. On the sprint board it
  opens on the sprint running today (else the latest to have started), and
  **Burndown for** switches to another.
- **Velocity** — on the sprint board only: for each sprint, oldest first,
  the cards committed (everything in it) beside the cards completed, and a
  dashed line at the average of the finished sprints. A sprint counts as
  finished once it is completed or past its due date; a running one's bar is
  paler.

Both read when each card was completed, which a card records from the moment
it is ticked done (or lands in a done list) and forgets when it is reopened.
Cards completed before this was recorded use the last time they changed.

## Roll-ups, the outline and My work

A board, its cards' sub-boards and their sub-boards form a tree, and the
tree is meant to be read at different resolutions: a quarterly roadmap at
the top, a team's delivery plan a level down, individual tasks at the
leaves. Rather than keeping three lists in sync by hand, the leaves are the
source of truth and everything above them is derived.

Every card carries a **roll-up** of what lies beneath it: leaves done out of
leaves in all (through every level, not just the next); its **effective
dates** — its own start and due, or, when it has none, the earliest start and
latest due of its subcards; whether anything beneath is blocked or overdue;
and a **health** of *done*, *blocked*, *at risk* or *on track*. When a card has
a due date of its own and its subcards run past it, the card shows the
**slip** (`+5d`): the gap between the plan and what the work implies. Rolled-up
dates are drawn dashed with a stack icon wherever they appear, and the card
modal spells out the subcards' range under the date fields.

The **Outline** view shows a board as a collapsible tree — each card with its
subcards indented beneath it, with list, progress bar, schedule and health per
row. The **levels** control limits the depth: one level is the roadmap, all
levels the task list; rows on deeper boards link into those boards, and the
*more* button on a cut-off row opens the board beneath it. Filters, search and
sort work as in the other views; a card that fails a filter is kept, muted,
when something beneath it matches. The same levels control on the
**Timeline** nests subcards under a card's bar (see above). On swimlanes and
tables, the *Due (rolled up)* axis groups cards by their effective due date,
and the table has *Assignee* and *Health* columns.

Cards can be **assigned** to a user from the card modal, or by dragging on an
*Assignee* swimlane axis. **My work** (`/work`, in the account menu) lists
every card assigned to you on any board at any depth, grouped by due date
(overdue, today, next 7 days, later, no date), each with its path — root
board › parent cards — and a link straight to it. Above them, **Waiting on
you** lists what needs you, oldest first ([waits](#waiting-on-a-person-waits)).

## Roadmapping

**List categories.** A list's settings give it a meaning: *to do*, *in
progress*, *done* or *dropped*. Dropping a card into a done list completes
it; moving it back into a to-do or in-progress list reopens it. Cards in a
dropped list count for nothing in roll-ups and show a *Dropped* health.
Templates carry categories, and the built-in templates mark their *Done*
lists.

**Horizons.** A list can stand for a date range (from, to, and the
precision to schedule at), so *Now · Next · Later* becomes *Q4 2026 · Q1
2027 · H2 2027*. A card dropped into a horizon list that isn't already
inside the range is given the range's end as its due date at that
precision; the list header shows the range, and a count of cards whose due
date has drifted outside it.

**Date precision.** A card's dates can be *day* (exact), *week*, *month*,
*quarter*, *half-year* or *year*. At anything but day the dates snap to
whole buckets (a quarter card runs 1 Jan – 31 Mar), the timeline draws a
soft-edged bar, and dragging moves it by whole buckets.

**Milestones** are named dates on the root board (board settings), drawn
as a dashed line with a diamond on the timeline and as a chip on the
calendar of every board in the tree; the narrative view lists the ones
passed and coming up.

**Dependency lines.** The timeline connects each blocker's bar to the bars
it blocks; a connector turns red and dashed when the blocked card starts
before its blocker is done. The *Dependencies* filter has a *Dates
conflict* option for exactly those cards.

**Colour by.** Timeline and swimlane display options include *Colour by*:
cover colour (the default), list, priority, health, reported health,
assignee or first tag, with a legend in the toolbar.

**Status updates.** A card's health is computed from dates, blockers and
subcards; its owner can also *report* one — on track, at risk, off track —
with a note. The latest report is shown beside the computed health on
cards, in the table, outline and timeline, and the history is kept on the
card. Reports are logged, so they appear in the narrative.

**Published views.** From the Views menu the board's owner can give a saved
view a public link (`/p/<token>`): anyone with it sees the board through
that view, live and read-only, without an account. Unpublish to withdraw
it. Timeline and calendar readers can page through dates; narrative readers
can change the range.

**CSV.** The table's *CSV* button downloads the visible columns for the
current filters, sort and grouping.

## Custom fields, scoring and votes

Board settings (root boards) hold the tree's **fields**: number (with
optional min, max, unit), rating (1–5 by default), choice (each option with
an optional weight and colour), date, text, and **formula**. Every field
has a short key, used in formulas as `{key}`; a formula is an arithmetic
expression such as `{reach} * {impact} * ({confidence} / 100) / {effort}`,
and may use `{votes}`, `{subcards}` and `{done}` too. A formula stored as a
*weighted* score (API only, for now) normalises each input to 0–100 across
the board's cards and combines them by weight, so effort-like inputs with a
negative weight pull a score down. Presets set a scheme up in one click:
**RICE**, **ICE** and **Value ÷ Effort**.

Fields are edited in the card modal (stars for ratings), shown as table
columns (*Display*), sortable, and rating and choice fields can be swimlane
axes — *Value* on one axis and *Effort* on the other is the prioritisation
matrix, and dragging a card between cells rescores it. A number or rating
field marked *Σ* rolls up the tree (totals per card, done and all) and
totals in table group headers.

**Votes.** Everyone has a budget of votes to spend across a board tree
(board settings: votes per person, max per card). The card modal shows the
total and a stepper for your own; votes are a table column, a sort and
`{votes}` in formulas.

## Links and goals

The card modal's **Links** section searches cards on any board you can
open and links them as *relates to*, *contributes to* or *duplicates*.
Links are shown from both ends with the other card's board. A card that
others contribute to is a **goal**: it shows its contributions with a done
count, and the *Goal* swimlane axis and table column group cards by the
goal they contribute to. Blocking dependencies stay separate, since they
carry scheduling meaning.

### Web links

Separately, a card's **Web links** section holds references *out* of the
system: a page, a shared drive, a file somewhere else. Type an address and,
optionally, a label to show instead of it; a bare `example.com/spec` is taken
to be `https`, and `file://`, `smb://`, `ftp://` and `mailto:` are kept as
typed. Each link is datestamped with the day it was put there, and opens in a
new tab.

Attachments are files the board itself holds; web links point at things it
does not own. On the API they are `urls` on the card (`POST
/api/cards/:id/urls`, `DELETE /api/cards/:id/urls/:url_id`), and from the CLI
`slipdock weblink <id> <url> [--label TEXT]` and `slipdock unweblink <id> <url-id>`.

### Images on the card front

A card with an image attached shows it as a thumbnail across the top of its
front, under the cover strip — the first image attached, which counts the
screenshots pasted into its description and comments. Beside each image in
the card's **Attachments** there is a **Don't show on the card front** tick
box; tick it and the next image takes its place, or the card shows none.
Only PNG, JPEG, GIF and WebP images of 10 MB or less qualify: the front shows
the original file, and every reader of the board would download a larger one.

The **Display** menu's **Images** turns thumbnails off for the view. It is on
for comfortable cards and off for compact ones, where it shows a small square
in the row instead. A saved view made before thumbnails existed keeps the
facets it was saved with, so tick Images there and save it to get them.

On the API, `hide_on_card` is on each attachment: `PATCH
/api/cards/:id/attachments/:attachment_id {"hide_on_card": true}` sets it, and
an upload can send it as a field. From the CLI, `slipdock card-front <id>
<attachment-id> --off` keeps an image off the front (without `--off`, lets it
back), and `slipdock attach <id> <file> --hide-on-card` uploads it kept off.

### Recordings

An audio file attached to a card (MP3, M4A, WAV, OGG, FLAC, WebM — anything
whose type is `audio/…`) plays in the card's **Attachments**, with a player
that can seek: the server answers the byte ranges a player asks for.

**Transcribe**, beside the player, sends the recording to the transcription
server an admin has set up under Configuration → Server → **Transcription
server**: a server of your own that speaks the small HTTP API below. Give its address (`https://host:8765`; `/v1` or
`/api/v1` on the end is fine too) and the auth token it issued; **Test
connection** asks the server for its status before anything is saved. The
token is kept on the server and never shown again — leave the box empty to
keep it, or tick **Forget the stored token**. With no address there is no
Transcribe button.

The work runs in the background, so the card can be closed meanwhile. The
transcript appears under the recording, folded away as **Transcript**; when the
server can tell voices apart it is written one speaker turn a line
(`Steve: …`). The transcript goes into [search](#deep-search-and-ask), so what was said on
the call finds the card. If it fails the reason shows instead, and **Try again** sends it
again. Slipdock follows the server's client rules: it checks the server's API
version first, sends every recording with an idempotency key so a retry
never transcribes it twice, waits up to a minute for an answer before
following it as a job, and retries only what the server says is worth
retrying (a full queue, a model still loading, a timeout).

#### What a transcription server must speak

Any server you run can do the transcribing, if it answers these over HTTPS,
with the token as `Authorization: Bearer <token>`:

- **`GET /v1/status`** → `200` with JSON `{"api_version": "1.x", "version":
  "…", "capabilities": [...]}`. Slipdock asks this before every recording and
  refuses a server whose `api_version` major isn't `1`. List `"diarization"`
  in `capabilities` if it can tell speakers apart.
- **`POST /v1/audio/transcriptions`**, multipart with `file` (the audio),
  `model=default` and `response_format` (`json`, or `diarized_json` when you
  listed diarization). Headers: `Idempotency-Key` (the same for every retry
  of one recording: answer a repeat with the same result rather than doing
  the work twice) and `Prefer: wait=60`. Answer either
  - `200` with `{"text": "…"}`, or for `diarized_json` with `{"segments":
    [{"speaker": "Steve", "text": "…"}, …]}`, or
  - `202` with `{"id": "<job>"}` (and optionally a `Location` header), when
    it will take longer than the wait.
- **`GET /v1/transcriptions/<job>`** → `200` with `{"status": "queued" |
  "running" | "completed" | "failed" | "cancelled"}`. A completed job
  carries the answer above as `result`, and a failed one `{"error":
  {"message": "…"}}`. Slipdock polls from 2 seconds, backing off to 30, for
  up to four hours.
- **Errors** as `{"error": {"code": "…", "message": "…"}}`. `429` and `503`
  are retried after `Retry-After`. Other `5xx` are retried with backoff, and
  `504` (with the job's `id` in the error, if there is one) means "still
  working: collect it later". `401`, `403`, `413`, `415` and `422` (`code`
  `audio_too_long` or `audio_undecodable`) are final and shown to the user.

On the API, `POST /api/cards/:id/attachments/:attachment_id/transcribe` starts
it (202), and each attachment carries `transcript_status` (`running`, `done`,
`failed`), `transcript` and `transcript_error`. From the CLI, `slipdock
transcribe <id> <attachment-id> [--wait]`; an admin sets the server with
`slipdock admin set transcription_server_url=https://host:8765
transcription_server_token=…`.

### Attachments over the API

A file goes up as the multipart form field `file` — the same upload the
card's drop zone takes, to a card or to a wiki page:

```sh
curl -s -H "authorization: Bearer $TOKEN" -F file=@shot.png \
     https://slipdock.example/api/cards/12/attachments
curl -s -H "authorization: Bearer $TOKEN" -F file=@diagram.png \
     https://slipdock.example/api/pages/W-31/attachments
```

Add `-F sha256=<hex>` (the file's SHA-256, as `sha256sum` prints it) and a
file that arrives different is a 422 `sha256_mismatch` with nothing stored;
`slipdock attach` sends it for every file.

The answer is the stored file — `id`, `filename`, `content_type`, `size`,
`sha256` (of the bytes as stored, so comparing it with `sha256sum` of your
copy verifies the upload without downloading it), `url` — and the `markdown` that shows it: `![shot.png](/attachments/5/shot.png)`
for an image, a plain link for anything else. Put that in a description, a
comment or a page body and the image appears inline, exactly as a pasted one
does. An optional `filename` field stores the file under another name; a
type the client leaves as `application/octet-stream` (curl's answer for
anything it does not know) is worked out from the name. `replace=true` (#1017)
deletes the card's or page's older files of the same name once the new one is
stored, and the answer lists their ids as `replaced`: a rebuild uploaded that
way leaves one current copy, and an upload that is refused leaves the old one
where it was.

`GET …/attachments` lists a card's or a page's files and
`DELETE …/attachments/:attachment_id` removes one, bytes and all. A card's
files are also in `attachments` on `GET /api/cards/:id`. The 250 MB limit and the
account's item and storage limits apply as they do in the browser: too large or
empty is a 422, a full account a 402.

**Behind a proxy, one request may be capped lower.** Cloudflare's free and pro
plans refuse a request body over 100 MB (business 200 MB) with a 413 that never
reaches Slipdock, and nginx's default `client_max_body_size` is 1 MB. In the
browser it makes no difference: the card sends a file over its websocket in
small chunks. Over the API and the CLI a file is one request, so upload
anything larger than the proxy allows through the browser, or raise the limit
(`client_max_body_size 260m;` for nginx). The CLI streams a file from disk, so
its size costs no memory.

From the CLI, a number is a card and anything else (`W-31`) a page:

```sh
slipdock attach 12 shot.png               # prints the Markdown that embeds it
slipdock attach W-31 /tmp/x.png --name diagram.png
slipdock attach 12 out/report.docx --replace   # and deletes the older report.docx files
slipdock attachments 12                   # ids, sizes and URLs
slipdock download 5                       # attachment #5's bytes, saved under its own name
slipdock download 5 --out - | less        # or --out F; --force overwrites a file already there
slipdock detach 12 5                      # attachment #5
```

## Narrative

The **Narrative** tab tells what happened to the cards the current view
selects — filters, grouping and sort all apply — over a date range: the
last 7, 14, 30 or 90 days, or explicit dates. Under each card come the
events from the activity log in that range: added, moved, completed,
rescheduled, assigned, commented, status reported, voted; events on
subcards anywhere beneath the card are told under it, marked ↳. A summary
opens the page (how many cards changed and how, what is overdue, blocked or
at risk now), milestones passed and coming up follow, unchanged cards are
listed in a line, and changes to the board itself close it. The *Display*
menu chooses what the narrative tells: which kinds of event to include
(added, completed, moved, due and start date changes, assignments,
comments with or without their text, status reports, votes, archiving,
other edits, events on subcards) and which extra sections to show (a
summary of each card's current values — list, priority, assignee, dates,
progress, health, tags — plus unchanged cards, milestones and board
changes). Saved as a view, a narrative keeps its span and its choices but
not its dates, so a published "fortnightly update" link always shows the
last fortnight, told the same way.

## Prioritise

The **Prioritise** tab (`/boards/:id/prioritise`) is where a board gets
ranked: one row per card with everything that feeds a ranking editable in
place — the priority, votes (everyone's total, and −/+ for yours within
the board's budget) and every scoring field (RICE, ICE, value ÷ effort or
your own), with each formula's score at the end. Rows are ranked by the
first formula's score, highest first, or by votes when the board has no
scoring model yet (the owner can install a preset from the header);
click a column header to rank by that instead. Completed cards are hidden
by default; the usual filters, search and saved views apply.

## Your boards

The index at `/` is where the boards themselves are looked after, and how it
reads is yours: two controls sit beside **New board** and **New vault**, and
both are remembered between visits. Your vaults are listed among your boards,
a card each, in the same order (see [Vaults](#vaults) for what a vault's card
shows).

**Layout.** The cards are the default — a colour band, the code, the
switcher key when the board has one and your Ctrl+Shift digit when you have
given it one, the lists and cards on it and how much is done. The compact layout is the same boards as a
table, a row each, with the board's colour, code, switcher key, description,
lists, cards, how far along it is and when anything last happened anywhere in
its tree. Worth switching to once there are more boards than fit on a screen.

**Order.** *My order* is the default, and it starts as the order the boards
were made in. Drag the handle on a card or a row to move a board or a vault,
or use **Move up** / **Move down** in its menu for the same thing without a
mouse. Setting the order from the command line, which names boards only,
leaves each vault behind the same number of boards as before.
The other orders — name, recently active, newest, oldest, most cards — sort
without disturbing yours: switch back to *My order* and every board is where
you left it. **The order is yours alone.** A board shared with four people
sits in four different places, and rearranging your index never moves anyone
else's — the same way a favourite is one person's.

**Archiving.** A board that is finished with can be archived, from its menu on
the index or from **Board settings** on the board itself. Only its owner can.
An archived board comes off the index, the board switcher (`b`), quick add and
the list of boards a card can be moved to — but nothing on it is deleted: the
link still opens it (with an *archived* badge in the header), its cards still
turn up in search and in **My work**, and the API and CLI still read and write
it. Archived boards collect in an **Archived** section at the foot of the
index, in whichever layout is on, and **Restore** puts one back where it was.
Delete is still there for what should really go, and still permanent.

On the command line:

```sh
slipdock boards --all                          # archived ones too
slipdock archive-board errands                 # and restore-board to undo
slipdock order-boards qvm-v1-rem errands 3     # your own order
```

## The header and the avatar menu

The right-hand end of the header is in the same order on every page, and is
about the app as a whole: **quick add** (`+`), **Search everything**, **Ask**,
**Favourites** (the heart), the **alerts** bell, and your avatar. The bell
carries a count only when an alert is waiting. A page's own buttons, where it
has any, come first, ruled off from the app's.

What belongs to the board you are on is on the board's own toolbar, the row
below: its sprint buttons, the AI chat about the board and the board's `…`
menu sit at the right-hand end, after **Views**, in every view of the board.

The **avatar menu** is in sections, and marks the page you are on:

- **Places**: Boards, My work, Wiki, Vaults. Search, Ask and Favourites are
  not repeated here: they are buttons beside it.
- **Set up**: Templates, Groups, Tools, Set up an agent.
- **You**: **Account & settings** (one entry: Settings, API tokens, Import &
  export and the rest are tabs on the Account page), Help, and the theme as a
  row of three buttons — system, light, dark.
- **Admin**, for admins only: Overview, Users, Tool listings and
  Configuration, folded into one group that opens by itself on its own pages.
  While it is folded it carries the count of signups and tool listings
  waiting.
- **Sign out**.

A board's **`…` menu** is in three groups: what you do with the board (Share
this board, Capture a meeting when meeting mode is on, Tidy up…), how it is
set up (Tags, Automations, Board settings), and what it has done (Activity,
Archived cards).

## Favourites

A board holds more than anyone works on at once. The board you live in is one
of nine, the list you actually move cards through is one of six on it, and the
card you report against every day is one of hundreds — three or four taps
every time, and the last one a hunt.

Press the heart on a **saved view** (in the Views menu), a **list header**, or
an open **card** (beside the close button) and it lands on `/favourites` — the
heart in the header bar on a desktop, the fifth tab on a phone. So anything you go back to often is two taps from
anywhere: the heart, then the thing.

- A favourited **list** opens its board scrolled to that list, which on a
  phone — where the board shows one list at a time — is the difference between
  arriving and swiping to find it.
- A favourited **view** opens in the mode it was saved in, as the view
  switcher's favourites always have.
- Favourites are **yours**. Two people on the same board keep different ones,
  and sharing a board never hands your shortcuts to anybody else. Marking one
  changes nothing about the thing itself, so read access is enough.
- The page prunes itself: each row carries its own heart, and anything you
  lose access to, or archive, drops off the list without a trace.

The heart is deliberately not a star — a card already *has* a star, the
"Starred" flag, which is the board's and everyone's.

They are in the API and the CLI too (`GET /api/favourites`,
`slipdock favourites`), where they are worth reading at the start of an agent's
session: they say where a person actually works, which a list of boards does
not.

## On a phone

Below 640px the app is not the desktop shrunk. The server is told the window
width when the socket connects (and again when the device is turned), and the
views that cannot survive being narrowed render something else instead.

- **A floating button** in the bottom-left corner carries the app's
  navigation within reach of a thumb. Tap it and a row flies out along the
  bottom edge: Menu, My work, **Add**, Alerts, Favourites; tap it again, or
  anywhere else, and the row folds away, so the page runs to the bottom of
  the screen. A dot on the button means alerts are waiting. On a desktop these live in the
  avatar menu and the header; on a phone that is a stretch to the far corner
  and a hunt through a menu. Templates had the fifth slot and gave it up: a
  template is something you reach for when making a board, which is rare, and
  a favourite is something you reach for all day.
- **Menu**, first in that row, is the header's menus in one: on a
  board, its own entries first under **This board** (chat about the page with
  AI, then the `…` menu's groups), then everything the avatar menu holds, plus
  Search and Ask, which a desktop has as header buttons instead. The avatar is not
  in a phone's header, nor the board's `…` and chat buttons in its toolbar.
- **The header is one row**: the mark (which goes to your boards), the
  board's name, and a magnifier and a `>_`, because a phone has no Ctrl: they
  open the card finder and the command palette — the same two panels
  `Ctrl-O` and `Ctrl-P` open on a desktop, and the fastest way to a card on a
  screen that shows one list at a time.
- **Quick add** is the middle button of that bar, and it opens the same
  one-line box as the header's, full width under the header. Everything it
  understands on a desktop ("call the printers friday, urgent") it
  understands here.
- **The board** becomes a pager: one list fills the screen, swiping moves to
  the next, and a strip above names every list with its card count and slides
  to the one you tap.
- **The calendar** becomes an agenda. Seven columns across 390 points gives
  each day 50 — too narrow for a date, let alone a card — so days run down
  the page instead, the ones with something on them plus today, each card a
  full-width row. Adding a card to a day and dragging one between days work
  as they do on the grid.
- **The swimlane grid** stacks. A matrix wants both axes at once; stacked,
  each row is a section you can collapse and each column a heading inside it.
- **The timeline** becomes a schedule: a row per card with its dates in words
  and a bar drawn in percentages of the same window, so overlaps and gaps are
  still legible. Rescheduling by dragging a bar is a chart gesture and stays
  on the desktop; the card's own dates do the same job.
- **The table** and **Prioritise** turn each row on its side — the card's
  title, then its fields as labelled lines. They are the same editable cells,
  so the inline edits still work, and the vote buttons that used to sit past
  the right-hand edge are now the first thing under each card.
- **Every toolbar** keeps the view switcher, the date navigator, Filter and
  saved views on one row and folds the rest behind an **Options** button.
- **Controls that appear on hover elsewhere are simply there**: a touch
  screen has no hover, so the card's tick, a day's **+**, a cell's **Add**
  and the delete buttons on checklist items, comments, attachments and
  dependencies do not wait to be pointed at.
- **The outline** keeps what identifies a card — its title and its list — and
  puts its schedule on a second line.

Everything else — cards, modals, panels and the AI drawer — is full-screen
and allows for the home indicator's safe area.

## Keyboard

Press `?` anywhere for this list on screen. Nothing fires while you are typing
in a field. An open card takes the keyboard for itself (see below); other
dialogs leave the page's keys alone.

**Anywhere**

- `Ctrl-P` — **commands**: one box for everywhere you can go and everything
  you can set off. Type what you want — a page, a board, one of this board's
  views or pages, *quick add*, *alerts*, *sign out*. Matching walks out from
  the exact to the vague, so `bs` finds *Board settings*. The arrows walk the
  answer, `Enter` follows the row you are on, `Esc` closes it.
- `Ctrl-O` — **open a card**: type a title and jump to it, on any board you
  can open. Type a card's id (`123` or `#123`) or paste its link and that
  card comes first — even an archived one, marked *archived*, which opens in
  its board's archive to be restored — and likewise a wiki page's code
  (`W-31`) for that page. Titles find live cards only. On a wiki it is
  the **note switcher** instead (`Cmd-O` on a Mac): type a few letters of a
  note's title, one of its aliases or its path, in order but not necessarily
  together (`acmcall` finds `Projects/Acme/Call`), across every board of the
  vault the board is in, or the board alone. Nothing typed lists the notes
  changed most lately, and a page's code still goes straight to it. On a
  shell, `slipdock page switch <board> <letters…>`
- `Ctrl-Shift-1` … `9`, `0` — **open a board** you gave that digit (see
  [A board's hotkey](#a-boards-hotkey))
- `h` — all boards (the board takes this one while the keyboard is on it)
- `b` — **switch board**: every board you can open, each with its own key;
  press that key to go there
- `q` — quick add a card (see below)
- `l` — alerts (the board takes this one too, while it holds the keyboard)
- `?` — the shortcut sheet
- `Esc` — close whatever is open

**On a board**

- `v` — **switch view**: Board `b`, Outline `o`, Swimlanes `s`, Table `t`,
  Timeline `i`, Calendar `c`, Narrative `n`, Prioritise `p`
- `/` — the board's search box
- `a` — chat about the page with AI
- `j` — **labels**: one appears on every card on screen; type it to open that
  card
- `J` — **pick a card up**: the same labels, but choosing one picks the card
  up rather than opening it
- `c` — **step into a list**: a label appears on every list; choosing one puts
  the keyboard on that list's first card
- `z` — **snooze** the card the keyboard is on, or the one under the pointer
  (labels, if neither); `z` again is tomorrow — see [Snoozing cards](#snoozing-cards)

Both `Ctrl-P` and `Ctrl-O` work from anywhere at all — mid-sentence, over a
card, over another palette. The keyed palettes (`b`, `v`, `?`) are picked from
by typing a row's own key; the typed ones (`Ctrl-P`, `Ctrl-O`) by typing what
you are after and walking the answer with the arrows.

**On an open card**

A card dialog answers the keyboard itself, so the page and the board behind it
stand down while it is up (`?` still reaches the sheet, `Esc` still closes the
card).

- `↑` `↓` or `j` `k` scroll it, `PgUp` `PgDn` a screenful at a time,
  `Home` `End` the top or the bottom
- `h` `l` step to the section before or after, for when the letter escapes you
- a section's own letter jumps to it — the letter underlined in its heading:
  `f` Flags, `t` Tags, `d` Description, `a` Attachments, `e` Ch**e**cklist,
  `s` Subcards, `p` De**p**endencies, `n` Li**n**ks, `w` Web links,
  `c` Comments

Four sections do not get their first letter: Comments and Description were
there first, so Checklist and Dependencies gave way, and `h` `j` `k` `l` belong
to moving about, so Checklist and Links gave way again. The underline in the
heading is always the authority.

Once the keyboard is on the board, a strip along the bottom says what it is on
and what the keys will do. Carrying a card (after `J`):

- `←` `→` or `h` `l` move it to the list either side, keeping its place in the
  order as closely as the shorter list allows
- `↑` `↓` or `j` `k` move it one place up or down within its list
- `Enter` drops it; `Esc` lets go, leaving it where it is

Stepping through a list (after `c`):

- `↑` `↓` or `j` `k` the card above or below, `←` `→` or `h` `l` the list
  either side
- `Enter` opens the card, `J` picks it up, `c` adds a card to the list, `z`
  snoozes it (`z z` until tomorrow)
- `Esc` stops

Vim's `h` `j` `k` `l` do everything the arrows do while the keyboard is on the
board, so a hand need not leave the home row. They are the board's for as long
as it holds the keyboard: `h` and `l` walk it rather than going to all boards
or opening the alerts, and `j` walks down rather than labelling the cards
again — `Esc` hands all three back.

Labels favour the home keys (`a s d f k j l`) and are single characters while
they last; a board showing more cards than there are characters gets pairs,
which reuse the home keys first in both positions — the way a Vim browser
plugin labels links. Only things you can actually see are labelled, so scroll
and press the key again to reach the rest. While labels are up, `Backspace`
un-types a character and `Esc` dismisses them.

Each arrow moves a carried card for real rather than previewing the move, so
the board on screen is always the board as it stands — `Esc` and `Enter` differ
only in that `Esc` says nothing more is coming. Picking a card up needs write
access and the board view; the labels for opening a card work in every view.

### A board's own key

Every board has a **shortcut key**: one or two characters that reach it under
`b`. It is taken from the board's name when the board is created — "Marketing"
is `m`, and the next board wanting `m` gets the next free letter of its own
name — so unlike the labels above it does not move around as the board fills
up. Change it under *Shortcut key* in board settings, or with
`slipdock set-board <board> --shortcut K`; clear it to take a fresh one from the
name. It is in the `shortcut` field of the API and the KEY column of
`slipdock boards`, and it addresses nothing — the board **code** is what names a
board in a URL or on the command line.

### A board's hotkey

`Ctrl-Shift` and a digit (`Cmd-Shift` on a Mac; the number pad counts too)
opens a board straight from any page, even mid-sentence in a field. Pick the
digit under *Hotkey* in board settings, or with
`slipdock hotkey <board> <0-9|none>`; `slipdock hotkeys` lists yours. The digits
are yours alone — ten to go round, so they are not the board's: somebody you
share a board with keeps their own, and a board shared with you can take one of
yours from the shell (`PUT /api/boards/<board>/hotkey`). Giving a digit to one
board takes it off whichever had it. A digit with no board, or on a board you
can no longer open or have archived, says so rather than going anywhere.

## At the foot of every list

One row of three small buttons — the list is narrow, and what is in it
matters more than how to add to it. All three are shortcuts to the same
thing, one more item on the board; hover for the names:

- **Add** — the one-line card form: a title, Enter.
- **Add a page** (the document icon) — straight into the wiki's own editor,
  Markdown and all, carrying the list with it. Save, and the page is placed
  there: a tile on the board, and a page in the wiki tree. The editor says
  which list it will land in.
- **Add a document** (the paperclip) — pick a file and it lands as a card of
  its own, titled after the filename with the file attached. A spec somebody
  emailed you belongs on the board, not in a folder.

Each can be turned off for the whole board under **List settings → At the
foot of every list** (any list's; only the board's owner sees it), or from
the command line:

```sh
slipdock set-board qvm-v1-rem --no-add-document   # …and --add-document to put it back
```

A board's JSON carries `add: {card, page, document}`, so a client that draws
the list draws the same three.

The **Filter** bar's *Kind* section narrows a list to any of the three again:
*Cards*, *Documents* or *Wiki pages*, on the board and in every other view.
There are only two rows behind the three names, so a document is recognised
rather than recorded: a card whose whole content is the file on it — nothing
written in the description, nothing to tick off, no subcards beneath it.
Write a description on it and it is a card about the work again, which is the
honest answer. (Comments don't count: "here's the spec" / "thanks" is what a
document on a board is for.)

Over the API and the CLI it is `kind=document` on a card listing (`slipdock cards
<board> --kind document`) and `kinds=` on a view (`--kind page`, repeatable),
where all three are counted together.

## A list's order and groups

A list draws its cards in the order they were dragged into. **List settings
→ Order** gives it an order of its own instead:

- **Sort by** — *Created*, *Last updated*, *Start date*, *Due date* or
  *Priority*, with a **Direction**: earliest / lowest first, or latest /
  highest first. Cards without the date go last either way; cards that tie
  keep their dragged order between them. A start date sorts as the card's
  start, or its due date when it has no start.
- **Group by** — *Flags*, *Tags*, *Start date* or *Due date*, each group
  under a small heading with its count; groups with nothing in them are left
  out. Flags and tags go in their usual order (the board's tag order), and a
  card with several is drawn once, under the first of them. Dates group
  relative to today: *Overdue* (or *Started*), *Today*, *This week*, *Next
  week*, *Later*, and *No date*.

Sorting is only how the list is drawn. A sorted list keeps itself in order,
so dragging inside it has nothing to rearrange — cards still drag in from
and out to other lists. The dragged order is kept underneath and comes back
when the list is set to *Board order* again. A grouped list that is not
sorted can still be arranged by hand within each group. A small icon by the
list's name says when it has an order of its own; hover it for which.

Filters still apply, inside each group. From the command line and the API:

```sh
slipdock set-column slipdock "To Do" --sort due_date --group flag
slipdock set-column slipdock "To Do" --sort priority --descending
slipdock set-column slipdock "To Do" --sort position --group none   # back to the default
```

A list's JSON carries `sort_by`, `sort_dir` and `group_by` (`PATCH
/api/boards/:board/columns/:id` sets them). The cards in it keep their
`position`, which is still what "the top of the list" means to an agent.

## Quick add

The table and outline views have a one-line add row: type a title, press
Enter, and the input is ready for the next card. Commands mixed into the
line are recognised as you type and shown as chips:

- `due: tomorrow`, `start: next mon`, `by friday`, `due: in 2 weeks`,
  `due: 1 oct`, `due: 2026-10-01`, `+3d`, `eow`, `eom`
- `#high` (a priority), `#blocked` (a flag), `#todo` or `#in-progress`
  (a list), `#docs` (a tag) — matched loosely, in that order
- `@dan` (an assignee, by name or email prefix)
- `every: mon`, `every: weekday`, `every: 2w`, `every: month 1`,
  `every: month last fri`, `every: 3d after` — makes the card
  [recurring](#recurring-cards). Here and in the header's quick add
- `snooze: mon`, `snooze: next week`, `snooze: 2026-11-02` — adds the card
  [snoozed](#snoozing-cards) until then (the same dates as `due:`). Here and
  in the header's quick add
- `; seen on Safari only` — everything after the first semicolon becomes
  the card's first comment, as written (commands in it are not read). This
  works in a list's own "Add a card" box and in the header's quick add too

Anything not recognised stays in the title. In a grouped table each group
has its own row and new cards take the group's value; in the outline a
card with a sub-board gets an "Add a subcard" row beneath it.

### From the header, in plain English

The **Quick add…** box in the header bar of every page (or the `q` key)
opens the same one-line form, wherever you are. It puts the card on your
default board and list — set them under *Quick add* on Account ›
*Settings*,
otherwise it is the first list of the first board you can write to.

With an OpenRouter key configured the line is read by the model as well
(`SLIPDOCK_AI_QUICK_MODEL` picks a cheaper or faster one than the rest of
the AI features use), so it takes prose rather than syntax:

    call the printers about the banners friday, urgent, waiting on them
    draft the Q1 plan on the Marketing board, start monday, #docs, @dan

Dates, priority, flags, tags, the assignee, and the board and list when
the line names one, all come out of it; what it understood is shown as
chips beside the card it made, with a link to open it. Only boards you
can write to, and their own lists and tags, can be chosen — a name the
model invents is dropped rather than created. If the model is off (the
checkbox on Account › *Settings*) or unreachable, the typed syntax above is
still read, and the card still goes in.

The code lives in `Slipdock.QuickAdd.Capture` (the catalogue of what may be
picked, matching names back to rows, writing the card),
`Slipdock.QuickAdd.Model` (the one model call) and `SlipdockWeb.QuickAddHook`
(the header box on every authenticated page).

## Deep search and Ask

The search box in a board's toolbar filters the cards in front of you by
substring. Type a wiki page's code (`W-31`) into it and the strip under the
toolbar offers that page as a link, whether or not it is on the board. That is the right tool when you can half-remember the title and no
help at all when you cannot — when what you remember is that somebody said
something about refunds, on one of eleven boards, some time in the spring.

One page answers that, in two modes: **Search finds cards; Ask gives answers to
questions.** The toggle at the top switches between them and carries whatever
is in the box across, so "I searched, now ask the same thing" is one click.
Each mode keeps its own state — your results are still there when you come back
from asking. The mode is the URL (`/search` and `/ask`, the header's ⌕ and ✨
icons, or `Ctrl-P`), so it is linkable and the back button works through it.

**Search** embeds every card, comment, status update and recording transcript
as a vector; your query
is embedded the same way and matched by meaning, so the words you type need
never appear in what comes back. A result is a **card**, because a card is what
you open. Under it are the chunks that actually matched — the comment, the
status update, the description — each labelled with what it is. That matters: a
card whose only match is a two-year-old comment looks exactly like a card whose
title is a bullseye until you can see which it was.

Each match is a link of its own, to where it is rather than to the card: the
card opens scrolled to that comment, status update or meeting quote, lit up for
a moment. A recording's transcript is labelled with the file and the part
(*transcript of call.mp3, part 2 of 5*); its link opens the transcript at that
part, shaded. A page section's link goes to its heading. The links are
`…/cards/<id>?at=comment-7`, `?at=status-update-7`, `?at=provenance-7` and
`?at=transcript-5-part-2`, so they can be shared; the API gives each match
its `url`, and `slipdock search --full` prints it. Filter to one board or
include archived cards. A card's id (`#123`) or link as the query finds that
card first, archived or not and with no AI needed; a link is nothing but the
card, while a bare id goes on to search for the number as well.

Either mode's box has a **star**: press it and the query is saved. In Ask the
box empties when you send, so each question in the conversation carries a star
of its own — which is the honest place for it, since whether a question is
worth keeping is something you know once you have seen the answer. Only the
question is kept, never the answer — the answer to "what's at risk this week"
is a snapshot of a Tuesday, and the point of saving it is to ask again. Saved
queries appear where the examples were, and **once you have saved one the
examples go**: your own questions are better examples than ours, and a list of
both is a list of neither. The two modes keep separate lists, and the whole
thing is yours alone, like favourites.

**Ask** hands that same search to a model as a *tool*. The assistant on a board
page is handed the page you are looking at and answers from that; this one is
handed nothing at all. It searches, reads the cards worth reading, searches
again if the first attempt missed, and then answers — showing you what it
searched for and linking every card it looked at, because an answer assembled
from four cards on three boards is worth very little if you cannot go and check
it.

Search is only one of its tools, because most questions about a board are not
really searches. It can **list** a board — every list with an exact count,
filtered by priority, tag, flag, text, due date, dependency or assignee, and
to any depth, so subcards are counted when it matters and it says which it
counted when they are not. It can **describe** a board: the lists, the tags
and people available, the milestones, the custom fields. It can list **one
person's work** across every board and level, grouped by when it is due — the
My work page, for anybody. It can read the **activity log** for a date range,
with the comments and status updates written in it, which is the only way to
answer "what changed this week" — the search index has no sense of time. And
it can read the **alerts** the automations have raised for you. A search
ranked by meaning returns its best matches and nothing else, so counting,
completeness and chronology all used to be questions it had to decline.

Search runs as you type; Ask waits for Enter, because a model call should
be asked for. It can read, not write; edits stay with the board assistant,
where the scope is visible.

Both are scoped by the same permissions as everything else, and slightly more
tightly. A board you can only reach through a shared saved view contributes
nothing — a search has no view to apply, so it would be all or nothing, and
nothing is the safe half. A card shared with you on its own is searchable
without its neighbours coming along.

### How it works

`Slipdock.Search.Chunk` breaks each card into the pieces a person wrote — the
card, each comment, each status update, and the transcript of each recording on
it (split between lines into parts when it is long, each part naming the
recording and the card). `Slipdock.AI.Embeddings` turns each into
a unit-length vector through OpenRouter's `/embeddings` endpoint, stored packed
as 32-bit floats in `search_embeddings` (see `Slipdock.Search.Vector`, which
keeps cosine similarity to a plain dot product). A query is embedded the same
way and every chunk you may see is scored: no index, no approximation, exact
answers in a few milliseconds at this size. A plain substring match runs
alongside and lifts exact tokens — a version number, a name — that a vector
would blur.

Writes queue their card with `Slipdock.Search.Indexer`, which embeds a couple of
seconds later, so saving a card never waits on an HTTP call. Chunks are
content-hashed, so unchanged text is never re-embedded; a card that moves board
has the board on its chunks corrected *inline*, because that field is what
permission filtering reads.

On a deployed server (the Docker release), run it inside the release, which
uses the server's own database and the AI key chosen under Configuration → AI
for search and automations:

```sh
docker compose run --rm slipdock reindex   # build or repair the index
slipdock search-status                     # from anywhere: what is indexed, and whether search is on
```

From a source checkout, against a database of your own:

```sh
mix ecto.migrate                  # first: mix does not migrate on start, a release does
mix slipdock.reindex              # build or repair the index
mix slipdock.reindex --stats      # what is indexed right now
mix slipdock.reindex --force      # empty it and rebuild from scratch
```

`mix slipdock.reindex` uses whatever database `DATABASE_URL` names in that
shell — not your live server's unless you point it there — and on one that is
behind on migrations it fails at start with `column … does not exist`. Run
`mix ecto.migrate` and try again. `--force`, `--stats` and `--dry-run` are
`mix`-only; the release's `reindex` is the plain walk, which is what a
restored database or a model change needs.

Run it again after changing the embedding model: vectors from two models are
not comparable. Walking every card is cheap — anything whose text has not
changed is skipped without an API call — so running it is also how you repair
an index that drifted. Embedding a board of a few hundred cards costs a
fraction of a penny.

`SLIPDOCK_AI_EMBED_MODEL` picks the model (default
`openai/text-embedding-3-small`) and `SLIPDOCK_AI_EMBED_DIMENSIONS` the vector
size (default 768 — `text-embedding-3-*` are Matryoshka models, so that is the
full 1536-dimension vector truncated: half the storage for almost none of the
quality).

## AI assistant

With a model configured — an OpenRouter key, or an endpoint of your own; see
*Running* — three features appear. Without one they stay hidden, and nothing
is ever sent to a model unless you ask.

- **Chat about this** — the *Chat* button in the header of every board
  page (in any mode) and of *My work* opens a drawer. Each message is sent
  with the page as context: the board, its lists, tags and people, the
  cards the current view shows (title, list, priority, dates, assignee,
  tags, flags, progress, health, blockers), the board's **wiki pages** —
  listed separately, by code and title, because a document is not a card —
  and, when a card is open, that card in full (description, checklist,
  comments, status updates, relations, subcards). The open card also has
  its own *Ask AI about this card* section at the foot of its modal.
  *Open card 123* (or *show card id 123*, *go to #123*) opens that card,
  on any board you can open, without asking the model at all.
- **Edit mode** — the *Edit* toggle in the drawer (for people who can
  write) turns a request into a list of concrete changes: set or clear
  dates, priority, assignee, flags and tags, rename, rewrite a
  description, move between lists, complete or reopen, create cards,
  comment, add or tick checklist items, archive cards (one or many:
  *archive the done cards* is a step per card). Ask for a tag the board
  doesn't have yet and it makes it: the step reads *Create tag “x” and add
  it to …*, and the tag (in the default colour, on the top board so its
  sub-boards share it) is only made when you apply. Ask for a tag on several
  cards at once (*tag everything in Doing as urgent*) and it is one step per
  tag naming every card it touches — *Add tag “urgent” to 3 cards: …* —
  leaving out any that already have it. It can also **archive a
  wiki page**, named by its code or its exact title — the one change it
  makes to the wiki, since a document is written in the wiki's own editor
  rather than dictated here. Relative dates are
  resolved from today. Nothing changes until you click *Apply*; every
  step is checked against the page and your permissions first, and
  anything the model got wrong (a tag to remove that isn't there, a card
  not on the page)
  is shown struck through with the reason.
- **Generator** — on the narrative page, *Generate narrative* offers
  five levels — one-liner, three-liner, summary, stakeholder update,
  detailed — and writes prose covering everything the narrative view
  shows (its range, filters, grouping and *Display* choices all apply),
  with a Copy button.

The code lives in `Slipdock.AI` (the client, and which endpoint, key and model
each request resolves to), `Slipdock.AI.Context`
(what the model is told), `Slipdock.AI.Assistant` and `Slipdock.AI.Actions`
(chat, proposals and applying them), `Slipdock.AI.Narrator` (the generator),
`Slipdock.AI.Researcher` (the tool-calling assistant behind *Ask*, with
`Slipdock.Work` for one person's cards across every board) and the
`SlipdockWeb.AIChatComponent` / `SlipdockWeb.NarrativeGeneratorComponent`
live components. Tests stub the API through `Req.Test` (`Slipdock.AIStub`).

## Automations and alerts

Every board has an **Automations** panel (the *…* menu → *Automations*, or
`/boards/:id/automations`; owners only). You describe a rule in your own
words and the model turns it into a spec the app runs:

> when creating a new card in Doing, email someone@example.com
> automatically move cards in In progress to Backlog if they've not been touched for 7 days
> show an alert if a card is due in less than 24 hours

The rule is stored as its sentence *and* as the spec, and the panel shows
the spec read back as a sentence ("When a card is added to Doing, email
someone@example.com.") plus the raw JSON under *What this does, exactly*. Nothing
the model invents can get through: every trigger, condition and action is
checked against the vocabulary before the rule is saved, and unknown keys
are dropped.

**Ready-made rules.** Above the composer sits a gallery of the rules most
boards want, each filled in with a short form instead of a sentence — and
because no model is involved, they work on a server with no AI key:

- *Follow* — this board (every new card), a list (every card added to it or
  moved into it), one card (anything that happens to it), comments
  (optionally only on one person's cards), a field changing (or any field),
  cards assigned to someone (you, by default), a card being flagged.
- *Remind* — due soon (N hours before), overdue, gone quiet (untouched for
  N days, optionally in one list).
- *Tidy* — complete cards that land in the done list, archive what has sat
  there for N days, have a tag set the priority, and a *Weekly tidy-up*
  that looks the board over once a week and alerts you to what it found
  (see [Tidying up](#tidying-up)).
- *Connect* — call a URL on every change.

Every *Follow* and *Remind* rule asks how to tell you: an alert in the header,
an email (to you unless you give another address), both, or an email to
whoever the card is assigned to. What a preset adds is an ordinary rule — it
appears in the list, reads back as a sentence, and can be switched off or
deleted like any other.

**Triggers.** Events — a card created, arriving in a list (added there or
moved there), moved, updated (optionally one named field), completed,
reopened, archived, assigned, tagged, flagged, commented on, or anything at
all happening to a card (once per change). Clock-driven — a card untouched for N days, due within a
window, overdue, starting soon, or simply a time of day. Time-based rules
are checked once a minute and fire once per occasion (one due date, one
card going stale, one day), so nothing repeats itself.

**Conditions.** Any number, all of which must hold: the card itself (by
number, to follow one card), list, priority, tag,
assignee, flag, title, description, completed, archived, blocked, whether a
due date or assignee is set, the dates themselves, health, age in days —
tested with `is`, `is_not`, `contains`, `any_of`, `none_of`, `is_set`,
`before`, `after`, `within_days`, `older_than_days`, `gt`, `lt`.

**Actions.** Email an address or whoever the card is assigned to; raise an
alert; move the card; set priority; add or remove tags and flags; assign or
unassign; comment; set or clear the due date; complete, reopen or archive;
add checklist items; create a card; start a wiki page; call a URL back;
write a line in the activity log. Text in an action can use
`{{card.title}}`, `{{card.url}}`, `{{card.due_date}}`, `{{card.assignee}}`,
`{{board.name}}`, `{{today}}` and the rest.

**Who gets email, and how much.** Automation email goes out under this
server's name, so it only goes to people who can read the board: its owner
and the people it is shared with. A rule naming anybody else is refused when
it is saved, and somebody whose access is taken away afterwards stops
getting it. One email action reaches at most 10 addresses, a rule has at
most 20 actions and a board at most 50 rules. Each owner's rules send at
most 200 emails an hour between them, and each board's rules make at most
120 callbacks a minute; past either, the action fails with "held back" as
the rule's last error and the next window carries on. At most 50
deliveries are in flight at once (`config :slipdock, :automations,
max_in_flight: N`); beyond that a delivery is dropped and logged rather
than queued.

**Callbacks.** "POST to https://example.com/hooks/kanban whenever a card is
archived", "when a card changes, GET https://example.com/hooks/kanban". The
server calls the URL with the card: its id and title, a link straight to
it, the list it is in, priority, assignee, start and due dates, whether it
is completed, its status (`open`, `done` or `archived`), stated health, per
cent complete, whether it is blocked, and its flags and tags — plus the
board (name, code and link), the rule's name, the event and the time. A
POST, PUT or PATCH sends that as a JSON body; a GET sends the same fields
as query parameters, flattened to `card.title`, `card.url`,
`card.due_date` and so on, with lists comma-separated and anything unset
left out. The URL can use placeholders too, so
`https://example.com/hooks/{{card.id}}` works. Only `http` and `https` URLs
are called, nothing is retried, and a refusal at the other end never stops
the rule's other actions.

Every call is written down as it finishes: **Recent callbacks**, at the foot
of the Automations panel, lists the newest twenty — the method and URL, the
rule and card that set it off, and what came back (the HTTP status, or why
there was none: a refusal, a timeout, a URL that is not `http(s)`), with
how long it took and when. It updates as calls land, so you can fire a rule
and watch. The board keeps its newest 200; `slipdock callbacks <board>` and
`GET /api/boards/:board/automations/callbacks` read the same log.

A rule normally watches its own board; say "including subcards" and it
watches the whole tree beneath it. Rules can be switched off, reworded,
deleted, and (when time-based) run by hand — which also forgets what they
have already acted on. Each rule shows how often it has run and what went
wrong last time; an action that can't be resolved (a renamed list, a person
who has left) fails on its own and leaves the rest of the rule running.
Rules change cards, and changing a card sets off more rules, so a run
carries a depth and stops after three: one rule feeding another works, two
rules batting a card back and forth does not run for ever.

**Alerts** are the quiet action: no email, just a line in the collapsible
section in the header bar of every page, with a count and the worst
severity (info, warning, urgent) always visible. Each person dismisses
their own — dismissing yours leaves everyone else's alone — and an alert
raised while you are looking at a page appears there without a reload. An
alert is only shown to people who can read the board it came from, and a
rule that keeps noticing the same thing about the same card says it once.

The code lives in `Slipdock.Automations` (the context, events and the
scheduled pass), `Slipdock.Automations.Spec` (the vocabulary, validation and
the sentence it reads back as — the one place that knows the shape),
`Slipdock.Automations.Runner` (matching and doing), `Slipdock.Automations.Parser`
(plain English → spec), `Slipdock.Automations.Scheduler` (the timer),
`Slipdock.Automations.Notifier` (email and callbacks, off the caller's back)
and `SlipdockWeb.AlertsHook` (the header bar, mounted into every
authenticated page). `config :slipdock, :automations` turns rules off
(`enabled: false`), changes how often the timer runs (`interval`) or sends
deliveries inline (`async: false`, as the tests do).


## Runners

A rule's **Send to runner** action (`runner` in a spec) sends a card to a
coding agent on a machine of your own. It queues a **job** for a **pool**
of runners; a runner of that pool, on the same board tree, takes it, runs
the agent, and reports how it went.

```json
{"type": "runner", "pool": "default", "kind": "claude",
 "prompt": "optional — by default the card's number, title, link and description"}
```

The prompt may use the same `{{card.*}}` placeholders as any action. Every
job's prompt, a rule's own included, ends with a paragraph saying it runs
unattended: nobody will answer questions, so choose inputs from the card and
say what was chosen, or open a [wait](#waiting-on-a-person-waits) saying what is
needed and stop (the answer starts a fresh job); if the board is paused, finish
the card and take no other. The
**Send cards to a runner** preset is the usual rule (it is offered once the
board has a runner): when a card
arrives in a list, send it to a pool. It and *Work a list with a runner*
both take an optional **Prompt** (#1156), the action's `prompt`; left blank,
the job gets the card's title, link and description.

**Working a list in order.** *Send cards to a runner* fires as cards arrive,
so cards already in the list are never sent and the queue runs oldest job
first. To have a runner work a list the way a person would — top card first,
one at a time — use the **Work a list with a runner** preset (or *the top
card of …, one at a time* in **Connect a runner**). Its trigger is
`list_top`:

```json
{"trigger": {"type": "list_top", "column": "To Do", "unassigned": true},
 "actions": [{"type": "runner", "pool": "loop"}]}
```

Whenever nothing the rule queued is still open, it sends the top open card
of the list, in the list's order, skipping cards that are completed,
archived, stand-ins, waiting on an unfinished card or flagged `blocked` or
`waiting` — and, with `unassigned: true`, cards somebody has taken — plus
any the rule's conditions rule out. It looks again whenever its job ends, a
card on the board changes or the list is reordered, the rule is saved or
switched on, and every few minutes besides. A card whose job just ended and
which is still at the top (the runner gave up on it) is passed over for ten
minutes (`feed_cooldown_seconds`), so it doesn't go straight back out;
**Run now** sends the top card at once regardless. A `list_top` rule must
have a `runner` action, and the list must exist.

**Waiting while anything is in progress.** A `runner` action with
`"wait_while_doing": true` queues jobs that are not handed out while any
other open card is in an in-progress list (a list with the *In progress*
category) on the job's board — the job's own card doesn't count, and nor do
cards on its sub-boards. The job stays `queued`, no try is counted, and the
next claim after that list clears takes it. `slipdock jobs` and the API show
the reason (`waiting_on`), and an empty claim says which job is held back.
*Work a list with a runner* turns it on by default (its **Wait while
anything is in progress** field); *Send cards to a runner* leaves it off. A
board with no in-progress list refuses the option when the rule is saved.

**Putting back a card left in progress.** A job can end — done, failed,
cancelled, timed out — with its card still in an in-progress list: the
agent crashed, ran out of time, or simply never closed it. On a rule that
waits while anything is in progress, that card would hold the runner for
good. A `runner` action on a `list_top` rule with `"requeue_stuck": N` (0
to 10) has the server deal with it when the job ends: the card gets a
comment saying why and which retry it is, and goes back to the top of the
rule's list (unassigned, if the rule only sends cards nobody has taken), so
it is the next one sent — the cool-down doesn't apply to it. After N
retries it is flagged **blocked** and left in progress, with a comment, and
the runner waits until somebody moves or closes it. Only the job's own card
is touched, never one somebody moved to in progress by hand, and never by a
job cancelled before a runner took it; a job whose lease lapsed and was
handed out again counts once, when it finally ends. Completing the card
starts its count again. The job records what was done (`recovery`:
`requeued` or `gave_up`). *Work a list with a runner* puts a card back once
by default (its **Put a card left in progress back, N times** field; 0
turns it off); `slipdock runner new … --top --requeue-stuck N` sets it from
the command line.

**Hearing when a job goes wrong.** A rule with the trigger `job_finished`
runs once for each runner job that ends, on the job's card, so the usual
actions — an alert, an email, a webhook — can tell you about it:

```json
{"trigger": {"type": "job_finished", "outcome": ["timeout", "requeued", "gave_up"], "pool": "loop"},
 "actions": [{"type": "alert", "title": "Runner job {{job.id}} {{job.outcome}}: {{card.title}}", "severity": "warning"}]}
```

`outcome` is any of how the job ended (`done`, `failed`, `cancelled`,
`timeout`) and what its rule then did with a card left in progress
(`requeued`, `gave_up`); leave it out to hear every ending. `pool` narrows
it to one pool's jobs. A job whose lease lapsed and was handed out again is
heard once, when it finally ends. Its text may use `{{job.id}}`,
`{{job.status}}`, `{{job.outcome}}` (the recovery if there was one, else the
status), `{{job.recovery}}`, `{{job.pool}}`, `{{job.kind}}`,
`{{job.runner}}`, `{{job.attempts}}`, `{{job.exit_code}}` and
`{{job.error}}`, and a webhook is sent the same fields as `job` beside
`card`. The ready-made rule *A runner job times out or a card is given up*
fills this in, and **Connect a runner** offers it as a checkbox
(`slipdock runner new … --alert`).

**How it is kept safe.** Runners pull: they dial out and ask for work, and
the server never connects to them, so nothing needs a port, a tunnel or an
exception to the outbound-address rules webhooks live by. And the server
only ever sends data — the job's id, its kind, the card and the prompt.
What a kind *runs* is in the config file on the runner's own machine, and a
kind with no definition there is refused without running anything. A rule
can choose which kind of job to queue; it can never choose a command.

**Jobs.** A job goes `queued → claimed → running`, then `done`, `failed`,
`cancelled` or `timeout`. A runner holds a claimed job on a 90-second
lease, renewed by a heartbeat every 20 seconds or so; if the lease runs out
(the machine slept, the network went), the job goes back in the queue for
another runner, and after three tries it fails and the card is flagged with
a comment. A rule never has more than one open job for a card, so a card
moved in and out of a list does not pile up work. The card's **Runner jobs**
section shows each job, which runner took it, when, and the tail of its log;
**Cancel** stops a queued job at once and asks a running one to stop.

**Parked on a question.** A job whose agent needs something only a person
can give opens a [wait](#waiting-on-a-person-waits) and stops (`slipdock
wait <card> "…"` inside the job, `update_card` `wait` from a session, or
`slipdock finish-job <job> --status waiting --needs "…"` to ask and park in
one step). The job ends `parked`, and never comes back by itself. A
`list_top` rule puts the card back on top of its list, flagged waiting, so
the next card goes meanwhile; one question never holds up the list. When
somebody answers, the card is sent to the same rule again — one fresh job,
with the question, the answer, who answered and the handoff at the top of
its prompt. If that can't happen (the rule is off or gone, the card was
completed or moved to another tree, the queue refused), the card says so in a
comment and the wait records why.

**Pausing.** **Pause** in the Runners panel holds the whole board tree, or
one pool, with a reason you have to give. While it is paused no job is
claimed and no list sends a card; queued jobs stay queued and running ones
finish. Every board in the tree shows a banner with who paused it, when and
why; `slipdock board`, `slipdock cards`, `get_board` and `list_cards` carry
it too, so an agent working without a pool sees it and stops. **Resume**
wakes the runners and rules at once. Agents can pause (`slipdock pause
<board> [--pool P] --reason "…"`, `POST /api/boards/:id/pause`, MCP
`manage_automation` `pause`), but only a person resumes (`slipdock resume`,
outside an agent).

**WIP limits that hold automated work.** WIP limits only warn people. Turn
on **WIP limits hold automated work** in the board's settings (`slipdock
set-board <board> --automation-wip`) and, while the first in-progress list
is at its limit, runner jobs and list sends for cards not already in
progress wait. People can still drag cards in.

**Held work says why.** A queued job that isn't being handed out says one
reason, the same in the card's jobs, `slipdock jobs`, an empty claim and the
card's state line: *paused by David: bad deploy*, *WIP full: In Progress
3/3*, *#123 is in progress*, or *No runner online for pool dev*.

**Connect a runner**, in the board's Automations panel, is the way in: it
opens a dialog of its own. Pick
where the work should happen — a Linux or macOS machine, a Windows machine,
Claude Code on your own machine in a `/loop`, or Claude on a schedule (a
Claude Desktop scheduled task, or a routine in Anthropic's cloud) — and a few
options (the pool, the agent, its working directory — `/tmp` unless you say,
`~\AppData\Local\Temp` on Windows — permission mode and timeout, how to keep
it running; hooks are under **Advanced**), and it gives you exactly what to
paste: the installer's one-liner with the token in it, and behind two links the
runner script it installs and the config it will write, with **Verify the
script** for the installer's checksums; the PowerShell line, the same way; the `claude mcp add`, skills and `/loop`
lines; or the connector, prompt and schedule for a routine, warning that a
routine needs the code on GitHub and this server reachable from the internet.
It can also add the rule that sends a list's cards to the pool, or use one
you have. A runner on a machine costs nothing while it waits; the Claude
scenarios need no install but every check for work is a Claude turn. The
answers are kept on the runner (never the token), so **Setup** shows the
steps again, **Change Settings** changes only what you change, and **Make
a new token** replaces a lost one.

**The Slipdock tools.** A job runs Claude with `-p`, where nobody can approve
a tool, so a Claude runner is set up to allow every tool of the Slipdock MCP
server without asking: **Let it use the Slipdock tools**, on by default, adds
`--allowedTools` for the servers it names (`claude_ai_Slipdock`, the claude.ai
connector, and `slipdock`, one added with `claude mcp add`; the name on a
machine is in `claude mcp list`). The installers take it as `--mcp-servers
A,B` / `-McpServers 'A,B'` and write it to the config as `ALLOWED_TOOLS` /
`$AllowedTools`; `''` turns it off, and then the agent has no access to the
board. Give a Claude runner the project's folder as its working directory, too:
Claude Code loads a project's own commands, skills and `.claude/settings.json`
only from where it starts, and the wizard warns while it is blank or still the
default.

**Instructions and hooks.** The wizard also takes standing instructions — how
much to write on the card (quiet, normal or verbose) and anything else you
would otherwise add by hand — which are put after every job's prompt, and two
hooks: a command run before each job (the job runs only if it succeeds) and
one run after each, however it ended, with `$SLIPDOCK_STATUS` (`done`,
`failed`, `cancelled` or `timeout`) and `$SLIPDOCK_EXIT`. They are written
into what the wizard generates and kept on the machine; the server never
sends them at job time. For the shell runner they become `JOB_INSTRUCTIONS`
(in a quoted heredoc with a random delimiter, so nothing in the text is read
as shell) and `before_job`/`after_job` functions in its config; for a `/loop`
they go in its prompt — the hooks either as instructions Claude is asked to
follow (best effort) or as Claude Code hooks in `.claude/settings.json` that
run after `claim_job` and `finish_job` (reliable, and the wizard says which
you are getting). A cloud routine takes the instructions only: it runs on
Anthropic's machines, so there is nothing for a hook to run on — and ChatGPT
the same, on OpenAI's. **Change the
answers** on a runner shows a diff of what changes, and re-running the
one-liner on the machine puts it in place, keeping the token it has.

**Having Claude write the hooks.** What a hook should do — which notifier
to call, what to keep from each pass — differs from one machine to the
next, so rather than ship one, **Connect a runner** (Advanced → Hooks →
*Have Claude write this hook*, for the shell and Windows runners) and
`slipdock runner setup <board> <runner> --hook-prompt` give you a prompt
to paste into Claude Code on the runner's machine. It states the contract
a hook works under and asks you the site-specific questions, then has
Claude write the hooks and a test for them. What every runner needs —
putting back a card a job left in progress, and alerting on it — is the
server's (`requeue_stuck` and `job_finished`, above), so the hooks never
move cards. The prompt points at a worked example, one server's own hooks
and their test, served at `/runner/examples/after-job-hook.sh` and
`/runner/examples/after-job-hook-test.sh` (from `priv/runner/examples/`).
For the shell runner it reads:

````text
Write the before-job and after-job hooks for the Slipdock runner on this machine.

The runner takes jobs from a Slipdock board and runs a coding agent on each card. It is the shell runner, slipdock-runner; its config, ~/.config/slipdock-runner/config (config-NAME for a runner installed with --name NAME), is shell, and it calls the functions before_job and after_job, if the config defines them, around every job. Write the hooks as one script, ~/.local/bin/slipdock-hook, taking `before` or `after`, in bash or POSIX sh.

The contract every hook works under:

- The runner sets these for both hooks:
  - $SLIPDOCK_JOB_ID: the job's number
  - $SLIPDOCK_JOB_KIND: the job's kind (claude, codex, …)
  - $SLIPDOCK_CARD: the card's number
  - $SLIPDOCK_CARD_URL: a link to the card
  - $SLIPDOCK_STATUS: how the job ended: done, failed, cancelled or timeout (after-job only)
  - $SLIPDOCK_EXIT: the job's exit code (124 timed out, 130 cancelled) (after-job only)
- Exit 0, always. A before-job hook that fails stops the job from running, and an after-job hook runs before the runner reports the job finished, so neither may block, hang or fail it: wrap every step so a failure is logged and skipped, and put a time limit on anything that calls the network (well under a minute in all).
- Keep your own log file. What a hook prints goes into the job's log, whose tail the board shows as the job's output, so never print secrets there.
- Don't move, flag, complete or comment on cards. Putting back a card a job left in progress is the server's job (the rule's "Put a card left in progress back, N times", requeue_stuck), and so is alerting on it: a rule with the trigger job_finished (outcome timeout, requeued or gave_up) can raise an alert, send an email or call a webhook. A hook that moves cards races the server and can stall the runner.

What to write — ask me before you start, then write it:

1. Which notifier I use, if any: PushOver, ntfy, Slack, email, or something else, and where its credentials live (an environment variable or a file only I can read — never in the hook itself). Send an alert when a job times out or fails, with the card's link.
2. What to keep from each job. For a Claude job, a record of the pass can be made from its Claude Code transcript: in the before-job hook, touch a marker file named after the job; in the after-job hook, take the newest .jsonl in the folder under ~/.claude/projects named after the job's working directory (every / and . turned into -) written since that marker that mentions $SLIPDOCK_CARD_URL. (Or have the job function pass claude a --session-id of its own and look that file up.) It can be summarised into a page on the board's wiki (`slipdock page new <board> <title> --file F`, then `slipdock page pin <page> --card $SLIPDOCK_CARD` so it shows under the card) or kept on disk. Ask me which, if any.
3. A test script for the hooks, run against fake notify and pass-log commands and a folder of fake transcripts, that checks each status, a missing environment, a failing notifier and the exit code, and that the hooks never touch the board.

A worked example to start from — one server's own hooks, with their test:

https://your-server/runner/examples/after-job-hook.sh
https://your-server/runner/examples/after-job-hook-test.sh

When it's written and its test passes, show me the two lines for the runner's config — before_job() { ~/.local/bin/slipdock-hook before; } and after_job() { ~/.local/bin/slipdock-hook after; } — or the commands to type into the wizard's hook fields (Advanced → Hooks), and remind me that the hooks run as the runner's user, with its PATH.
````

**Runners** belong to a board tree and a pool. The board owner makes them:
each has its own token (`sdr_…`), shown once, that can take and report on
that pool's jobs and nothing else — it is not an API token and opens no
other door. Revoking a runner ends its token at once. A Claude session can
take jobs too, with the API token it already has, over MCP (`claim_job`,
`job_progress`, `finish_job`) or the CLI (`slipdock claim-job`); it shows in
the runner list as *label (session)* — from its first claim on; until then a
pool a rule sends to shows there as *waiting for a runner*. A claude.ai
connector keeps the tool list it was added with, so one added before the job
tools existed has none of them: disconnect and connect it again. A session
told to take jobs that finds no job tools stops and says so. A session reports between steps of its
own work rather than from a background loop, so it holds its job on a
20-minute lease instead of 90 seconds.

| CLI | What it does |
|---|---|
| `slipdock runner new <board> [name] --pool P [--scenario …]` | The **Connect a runner** wizard: prints exactly what to paste for `server` (the default), `windows`, `loop`, `cloud` or `chatgpt` (the connector, and a one-job prompt for a chat or a ChatGPT scheduled task; jobs of kind `chatgpt`, and `--commit` refused, as it has no repository), with `--agent`, `--command`, `--kind`, `--cwd`, `--permission-mode`, `--no-slipdock-tools`, `--mcp-servers A,B`, `--timeout`, `--service`, `--where desktop\|cloud`, `--repo`, and what a job does to its card and repository, in every scenario and each off unless given: `--in-progress` (move it to the doing list), `--assign` (assign it to the session), `--commit` (only ever in a git repository), `--push` (needs `--commit`), `--move-done`, `--complete` and `--percent-100`, each with a `--no-` form. Off ones are said in the prompt (or a runner's standing instructions) as don'ts. `--verbosity nothing` (the default) means no comments on the card at all. A working directory spelled the Windows way (`C:\…`, `~\…`) gets PowerShell steps, the skills from `/install.ps1`. For a runner of its own (server, windows) it makes one and prints its token, once; `--column LIST` adds a rule sending that list's cards. |
| `slipdock runner setup <board> <runner> [options]` | A runner's steps again, from the answers saved on it (the token left out); with any of `runner new`'s options, including `--verbosity`, the seven `--[no-]in-progress` … `--[no-]percent-100` toggles, `--instructions`, `--before-job`, `--after-job` and `--hooks prompt\|hook`, saves them and prints what changes. With `--hook-prompt`, prints the prompt that has Claude write the runner's hooks. |
| `slipdock runner token <board> <runner>` | A new token for a runner, the old one ended, with its steps written out for it. |
| `slipdock runner ls <board>` / `slipdock runners <board>` | The board's runners: pool, last seen, current job. |
| `slipdock runner show <board> <runner>` | One runner in full: what kind it is, who made it and when, last seen, the API token a Claude session works through, the job it holds now, how many of its jobs ended each way, its latest jobs (`--limit N`, 10 by default) and the rules sending cards to its pool. On the Automations panel, clicking a runner's name shows the same. |
| `slipdock runner rm <board> <runner>` | Revokes a runner. |
| `slipdock jobs <board> [--status S]` / `slipdock jobs --card ID` | Jobs, newest first. `S` is `open` or a status. |
| `slipdock job <id>` | One job: status, runner, prompt, log tail. |
| `slipdock cancel-job <id>` | Stops a job. |
| `slipdock claim-job <board> --pool P` | Takes the next job as this session. |
| `slipdock job-progress <id> [--message NOTE]` | Renews the lease; the note is also a comment on the card. Prints `ok` or `cancel`. |
| `slipdock finish-job <id> --status done\|failed\|cancelled\|timeout [--summary S]` | Ends a job this session claimed. |

**The shell runner** (`slipdock-runner`) is a POSIX `sh` script that needs
`curl` and nothing else — no `jq`, no Python, no root. It long-polls for a
job, runs the config's `job_<kind>` function with the prompt in
`$SLIPDOCK_PROMPT` (and `$SLIPDOCK_JOB_ID`, `$SLIPDOCK_CARD`,
`$SLIPDOCK_CARD_URL`), heartbeats with the tail of its log every 20 seconds,
and reports the exit code. A cancel from the board, or a job over its
`JOB_TIMEOUT`, stops the job and everything it started. One runner works one
job at a time; run more for more. Install it with

```sh
curl -fsSL https://your-server/runner/install.sh | sh -s -- \
  --url https://your-server --token sdr_... --pool default --agent claude --cwd ~/src/app
```

which writes `~/.local/bin/slipdock-runner`, its config at
`~/.config/slipdock-runner/config` (mode 600, yours to edit — it is shell,
and each `job_<kind>` function in it is a kind of job this machine will run)
and a systemd user unit (Linux) or launchd agent (macOS), and starts it.
`--cwd '~/…'` (or `-Cwd '~\…'` on Windows) is the runner's own home even
in quotes, and is written into the config as `"$HOME"/'…'` (`Join-Path $HOME
'…'`); another user's `~bob/…` is refused — give a full path.
`--agent codex` or `--agent custom --command '…'` run something else;
`--service none` and `--no-start` leave starting it to you.

**Several runners on one machine** — one per board, say — each need a name
of their own: `--name NAME` (`-Name NAME` on Windows). Runner NAME has its
config at `~/.config/slipdock-runner/config-NAME`, its own systemd unit
`slipdock-runner-NAME` (launchd `us.slipdock.runner.NAME`; on Windows
`config-NAME.ps1`, `runner-NAME.log` and the task *Slipdock runner (NAME)*),
and installing it leaves the others running. The setup steps name each new
runner after its board's code and its pool, as in `--name slipdock-loop`, so
setting up a second board on the same machine just works. Installing with no
name over a config that is another runner's — another server or pool — is
refused rather than replace it; `--replace` (`-Replace`) replaces it anyway,
keeping the old one beside it as a `.bak`. A runner set up before runners
had names keeps none: set up again, it updates the unnamed one.

The installer is
the same file for everyone; its SHA-256 is at `/runner/SHA256SUMS` to check
before running it.

**On Windows**, `slipdock-runner.ps1` does the same in Windows PowerShell
5.1, which every Windows has, or PowerShell 7: the same protocol, a
dot-sourced `config.ps1` whose `Job-<Kind>` functions are the kinds of job
the machine runs (kind `two-words` is `Job-TwoWords`), the prompt only ever
in `$env:SLIPDOCK_PROMPT`, the job in a child process whose whole tree is
stopped on cancel or timeout, and `Before-Job`/`After-Job` and
`$JobInstructions` as in the shell config. Install it from PowerShell with

```powershell
& ([scriptblock]::Create((irm 'https://your-server/runner/install.ps1'))) `
  -Url 'https://your-server' -Token 'sdr_...' -Pool default -Agent claude -Cwd 'C:\src\app'
```

which writes `%LOCALAPPDATA%\slipdock-runner\` (the runner, and the config
with an ACL leaving it readable by you alone) and a per-user Task Scheduler
entry, *Slipdock runner*, that starts it at logon — no admin rights. Its log
is `runner.log` beside the config. `install.ps1` and `slipdock-runner.ps1`
are in `/runner/SHA256SUMS` too.

The runner protocol and the session endpoints are in the agent guide
(`slipdock guide`, section *Runners*).
## Meeting capture

Send a meeting's recording or transcript to a board, and Slipdock writes it up
the way a person would afterwards: a short summary, the key topics, and the few
things that go on the board — actions somebody took on, decisions the meeting
agreed, changes to cards already there — each tied to the exact words it came
from. A person reviews
the proposals, settles anything uncertain, and commits them in one write. It is
**off unless an admin turns on meeting mode**, and with it off there is no trace
of it: no menu entries, no pages, no API routes, no CLI commands that do
anything, no MCP tools, no section in the agent guide. Turning it off deletes
nothing; turning it back on shows every capture again.

### What it promises

These are what meeting capture is built around, and each is tested.

- **Nothing is written that a person didn't approve.** Reading a meeting
  produces proposals only; the model that reads it has no tools and cannot
  write anything. The board changes when somebody presses **Commit**.
- **Nothing is claimed that the transcript doesn't say.** Every proposal
  quotes the transcript, and code — not a model — checks each quote is there
  word for word (forgiving only case, quote marks, dashes and spacing). A
  proposal whose quote isn't there is dropped, and the drop is shown.
- **Uncertainty is shown, never quietly resolved.** When the two readings of
  the meeting disagree (15% or 50%?), a name matches nobody on the board, a
  proposal only loosely matches an existing card, or who said something
  decides who owns it and the speaker is unsure, it becomes a question.
  "Not decided" and "Nobody yet" are always answers.
- **A person's call is recorded as theirs.** Every answer keeps who gave it,
  when, through what (the web, the API, an agent relaying it) and after what
  (a passage replayed). The transcript itself is never edited.
- **Existing work is changed, not duplicated.** Talk about a card already on
  the board proposes a change or a comment on it; a weak match asks.
- **What you preview is what is written.** The commit preview is the change
  set the commit applies, and the commit refuses if the review has changed
  since the preview you saw.
- **Nothing is written over newer changes.** Each proposed change remembers
  the version of the card or page it was based on; if somebody edited it
  since, the commit refuses and names it.
- **All or nothing.** The commit is one transaction: a failure part of the way
  through writes nothing.
- **Undoable as a whole**, and it says first if anything it wrote has been
  edited since, so an edit is never silently thrown away.
- **Once.** Sending the same transcript or recording to a board again finds
  the first capture; a committed capture is never committed again.
- **The trail survives.** A card or decision that came from a meeting keeps
  the quote, the speaker, the time and who committed it, after the capture
  and its recording are gone.
- **Nothing leaks across permissions.** A meeting is read alongside only what
  its sender can open.

### Sending a meeting

From a board's **Meetings** tab (or **… → Capture a meeting** on a board that
has had none yet), **Capture a meeting** takes up to three things:

| Sent | Transcribed here | Replay | Speakers from | Counts against |
|---|---|---|---|---|
| A recording | yes | yes | voices, dialogue, the invite | transcription minutes, storage |
| A recording and a transcript | no, lined up only | yes | voices, the transcript's labels, dialogue | storage |
| A transcript | no | no | the transcript's labels, dialogue | captures |
| …and an agent's findings | — | — | — | nothing more; still checked word for word |

Transcripts: WebVTT, SRT, plain `Name: words` lines (with or without
`[00:01:02]` stamps), and Fireflies or Otter exports, text or JSON. An `.ics`
invite gives the attendees — the strongest hint at who is speaking — the
start and the title. The page says where the meeting will be sent before
anything is (the reading model and its host, from your AI settings), and what
it counts against.

### What happens next

The capture is read in steps, each stored before the next, so a restart
carries on where it stopped: transcribing (for a recording), working out who
spoke, gathering what the board and its wiki already know (cards mentioned by
`#412`, `W-31` or a board code and number like `PL-14`, titles said aloud, and
semantically similar cards and pages), reading the meeting, and checking every
quote. The whole meeting is read at once, and the model is asked to be
selective: an hour's conversation usually has a handful of actions, and
opinion, background, ideas and open questions go in the summary and topics
rather than becoming things to review. (A transcript too long to read at once
is read in overlapping stretches.) The capture's page shows the steps as
they go and the findings as they appear; you can leave, and the sender is
emailed when it is ready.

### Reviewing and committing

The review shows the transcript beside the findings. Selecting a finding
lights up the words it came from; each one shows its signals as words
(*quoted word for word*, *both readings agree*, *linked by id*, *name not
recognised*… — never a confidence percentage), what Slipdock already knew
about the cards involved, its questions, and what it **becomes** in plain
words. Include it, leave it out, edit it, or add something the transcript
missed (marked as added by a person). Questions are asked only where the
answer changes what is written, and most are **optional**: a name nobody on
the board has (the card keeps the name, *For Ryan (not on this board)*, or is
matched to the person in the meeting who has it), a card only similar in
meaning (left alone, it is a new card), who said an unsure line (left alone,
unattributed). **Commit** stays off only while a question with no sensible
default is open on something going in — two members with the name said, a
card named aloud, which reading is right; leaving a finding out sets its
questions aside (they come back if it is included again), and an answered
question is marked *Settled*. A change to a card Slipdock can't find, with
none to offer, is shown left out rather than asked about. Keys: J/K between findings, 1–4 answer, I/X include or leave out, Enter
edits, N the next question.

**Commit…** opens the preview: new cards by list, changes to cards as before →
after, comments, the lines added to and struck on decisions pages, cards that
slip as a knock-on, who is assigned, what is left out, and whether anything
has moved since it was read. Each meeting gets one wiki page of its own,
*Decisions / Pricing sync · 7 Oct 2026* (a second capture of a meeting of the
same name on the same day gets *… (2)*, never the first one's page). The page
opens with the meeting, its date, who was there and a link back to the
capture, then the meeting's **summary** and **key topics** (shown above the
findings on the review, to read rather than settle), then its decisions; when
the decisions span more than one topic, each topic is a heading. A meeting
with a summary and no decisions still gets its page. The preview shows a new
page whole, exactly as it will be written. A decision that replaces an earlier one strikes it through on whichever
decisions page it is — an earlier meeting's, or an older page per topic such
as *Decisions / Pricing* — and the two link to each other.

Each open question has **listen and resolve**, which opens them one at a time:
the passage with the lines around it, what the transcriber was unsure of, what
each reading heard, other lines that bear on it, and — where a model re-listened
to it — that model's view, labelled a guess. With a recording there is a
waveform with the passage marked, **Replay**, **At 0.75×** and **Loop**; an answer
given after replaying is recorded that way ("after replaying 7:38–7:44").
Without one, the page says why there is nothing to replay. **Ask the speaker**
sends the question and the passage to the person who said it; that item waits
for their answer while everything else can be committed, and is written in a
commit of its own once they answer — every item is still written only once,
and undo reverses the lot. Re-listening is the admin's to switch on
(`meetings_relisten_model`, an audio-capable model): unclear passages a finding
depends on are cut from the recording and listened to again, and what comes
back is a signal, never an override — it agrees (the finding says
*re-listened*), or it hears something else and that becomes a question.

After the commit the capture's page is its receipt — everything written, with
links — with **Undo all**. The board's Meetings tab is the inbox: every
capture, its state, what it found and has left to settle, and who committed or
discarded it. **Discard** decides against a capture without writing anything.

### Settings

Configuration → **Meetings** (or `slipdock admin set meetings_…=…`):
`meetings_enabled`; where it shows — `meetings_visibility=used_only` (a
board's tab appears after its first capture) or `every_board`; whether people
may hide it for themselves (`meetings_hideable`, then Account → Settings →
Display); what may be sent (`meetings_accept_transcripts`, `…_audio`,
`…_findings`); and which models read a meeting (`meetings_reading_model`, empty
for each person's own; `meetings_second_reading=off|same|model` (off by
default: a second, independent reading doubles the cost, and where the two
differ it asks which is right) and
`meetings_second_model`). Readings run on the sender's AI settings. An answer
outside the findings format is sent back once; whatever still doesn't fit after
that is left out and listed on the capture's record, and the rest is kept. An
answer cut off by the model's output limit (a busy meeting) is read again in
halves; if even a few lines are too much, pick a model with a larger output
limit.

Transcription: `meetings_transcription=none` (the default: a recording needs a
transcript sent with it), `provider` (each sender's own AI settings —
OpenRouter's `/api/v1/audio/transcriptions` with their key or the shared one,
or their own OpenAI-compatible endpoint) or `endpoint` (one of the server's:
`meetings_transcription_url`, a local whisper server, say), with
`meetings_transcription_model` (`openai/whisper-large-v3`) and
`meetings_transcription_max_mb` (25), the largest file sent at once. Longer
recordings are cut into stretches that overlap by five seconds and stitched at
the middle of each overlap, word by word, so nothing is lost or said twice at a
seam: WAV files here, other formats when `ffmpeg` is installed on the server
(the Docker image does not include it; send WAV or a transcript instead). A
transcript sent with a recording is used word for word and lined up with it —
by its own times, or, for plain text, spread over the recording in proportion
to what was said, and marked as estimated. Recordings are deleted when their
keeping runs out (the scheduler checks every minute), which frees the storage;
the capture then says replay is no longer possible.

Voices: who said something decides who owns an action and who made a
decision. `meetings_diarisation=labels` (the default) takes the voices from the
transcript's own speaker labels; `endpoint` sends a recording whose transcript
has none to a diarisation service of yours (`meetings_diarisation_url`), which
answers `{"segments": [{"start", "end", "speaker"}]}` in seconds — a pyannote or
WhisperX server fits; lines two voices talk over are marked *voice unsure*.
Each voice is then attributed with its evidence shown: a label that names a
member or an attendee, being addressed by name and then answering ("Good
question, Sam."), an introduction ("I'm Ollie"), and elimination against the
attendees (`meetings_dialogue_inference=false` turns the dialogue part off).
Two voices that come out as the same person are merged. **Who said what**,
from the review, shows a card per voice — clips to replay where there is a
recording, the person and why, confirm or change — and the unsure lines a
finding depends on. Changing a voice changes the owner or decision-maker of
exactly the findings that took it from that voice, without reading again.

Voiceprints, by consent: off unless an admin turns them on
(`meetings_voiceprints=true`, with `meetings_voiceprint_url`, an embedding
service of yours that is sent a recording — and, for a stretch of a meeting,
`segments` as `[[start, end]]` in seconds — and answers `{"embedding":
[numbers]}`; a SpeechBrain ECAPA or pyannote server fits). Then each person
decides for themselves, under **Account › Voiceprint** (or `slipdock voiceprint
enrol --audio me.wav --consent`): from a short recording of their own voice,
or from a meeting where their voice was confirmed. Nobody can enrol, see or
delete anybody else's: every route is the caller's own, and one that names a
person is refused. The consent wording they agreed to is recorded, word for
word with its version, beside when; only the embedding is kept, never the
audio it was made from. Deleting it takes effect at once — later captures stop
using it — and the withdrawal is recorded. The voiceprint and the consent
record are in the person's own export (`voiceprint.json`). In a capture with a
recording, a voice whose lines sound like somebody's voiceprint gets that as
one more piece of evidence, shown with its similarity, weighed with the rest
and confirmable like any other. There is deliberately no MCP tool for it:
consent to biometric data is the person's to give, not an agent's.

Limits, per person per month, each with a switch: `meetings_transcription_minutes`
(600), `meetings_audio_storage_mb` (2048, the recordings they have stored now)
and `meetings_transcript_captures` (200); for every meeting,
`meetings_longest_minutes` (240) and `meetings_max_file_mb` (500); and how long
recordings are kept, `meetings_audio_retention`. They are checked before
anything is stored or sent to a provider, and a meeting over one is refused
with `meeting_limit_reached` (HTTP 402), naming the limit — retrying will not
help. Transcription and reading on a person's own AI key or endpoint don't
count; stored audio does. A recording's length is read from a WAV header, or
estimated from its size until the transcriber reports it. Every
transcription, model call and stored recording goes on a usage ledger;
Configuration → Meetings shows this month's totals and the heaviest users
(`slipdock admin meetings-usage`, `GET /api/admin/meetings/usage`), and the
upload page shows each person what they have left.

### From a terminal, and from agents

```
slipdock meetings                                   is it on here
slipdock capture new <board> --transcript F [--audio F] [--findings F] [--ics F]
                                [--title T] [--when T] [--attendees A] [--with-parent]
slipdock capture ls <board> | show <id> | preview <id> | schema
slipdock capture resolve <id> <question> <answer> [--replayed SPAN]
slipdock capture include|leave-out <id> <finding>
slipdock capture commit <id> [--preview DIGEST] | undo <id> [--rest]
slipdock capture retry <id> | discard <id>
```

The API is under `/api/meetings`, `/api/boards/:board/captures` and
`/api/captures/:id` (see [JSON API](#json-api)); an agent's own findings use
the format at `GET /api/meetings/findings-schema`. Over MCP, `capture_meeting`
(or `capture_chat`, [for a conversation](#capturing-a-conversation)),
`get_capture`, `resolve_capture_question` and `commit_capture`. An agent
answers a capture's questions **only with the person's own answers**, and
commits only when asked; its answers are recorded as the person's, *via
agent*. The `slipdock-capture` skill says all of this to an agent.

### Capturing a conversation

A conversation with Claude, ChatGPT or another assistant makes decisions and
to-dos too, and then scrolls away. **Chat capture** puts it through the same
pipeline and the same promises: every proposal quoted word for word from the
conversation, anything uncertain asked, nothing written until the person
commits it, undoable as a whole.

- **Its own switch, on by default.** Configuration › Meetings › *Chat capture
  is on* (`chat_capture_enabled`). It doesn't need meeting mode: there are no
  recordings, voiceprints or attendees to consent. With only chat capture on,
  the review pages, the capture API and the review MCP tools are there, and a
  meeting capture is not; with only meeting mode on, a chat capture is not.
- **Two ways in.** The model in the chat sends it, over MCP with
  `capture_chat`, as `Name: text` turns, optionally with its own findings —
  then no server model or AI key is needed, and the quotes are still checked
  against the conversation, so a model can't invent agreement. Or a person
  sends a paste or an export: `POST /api/boards/:board/captures` with
  `kind: "chat"`, or `slipdock capture-chat`.
- **Formats.** `chat` (`Name: text` turns; a turn runs on, line after line, to
  the next label; a label inside a ``` code fence is part of the turn; words
  before the first label belong to nobody), `claude-export` (claude.ai's
  `conversations.json`, or one conversation) and `chatgpt-export` (a
  conversation's `mapping`, read along the branch it was left on, so abandoned
  edits are not read). An export holding several conversations needs
  `conversation`: one's id or title. All three are detected.
- **Read as a conversation.** No transcribing, no voices to separate, no
  working out who spoke: the speakers are the person who sent it and the
  assistant. The reading treats the assistant's suggestions as suggestions —
  a decision or action needs the person's agreement in the conversation, and
  that agreement is the quote. An action with nobody named is the person's.
- **Reviewed and committed the same way.** The trail on a card it touches
  reads *From a conversation*, with the quote, and links back to the capture.
- **Keep the transcript, or not.** The conversation is stored, as a meeting's
  transcript is, and private to its sender and the board's writers. Untick
  *Keep the conversation after committing* on the commit preview (or send
  `keep_transcript: false`, `--drop-transcript`) and its lines are deleted
  once committed, leaving only the quoted evidence.

```sh
slipdock capture-chat <board> chat.txt [--format chat|claude-export|chatgpt-export]
                      [--conversation ID|TITLE] [--title T] [--findings F] [--drop-transcript]
```

## Wiki

The board answers *what are we doing*. It cannot answer *how does this work*,
*what did we decide and why*, or *what shape is the thing* — and those are the
answers that otherwise get rediscovered every few months. Each board has a
wiki for them at `/boards/:id/wiki`, reachable from the view menu: Markdown
pages in a tree of their own, with the board's permissions, the board's API
and no second system to keep in step.

**Writing.** A page's body, a card's description and the comment box are
written in a Markdown editor with a live preview, the way Obsidian's is: a
line shows formatted — headings, **bold**, links, lists, task boxes, tables,
images — until the cursor is on it, and then shows its Markdown to edit.
Enter carries a list or a quote on to the next line, Tab indents a list item
(Escape, then Tab, leaves the editor), Ctrl-F finds in the text, and pasting
or dropping an image attaches it as before (one that can't be taken — over
50 MB, or not a PNG, JPEG, GIF or WebP — is refused with the reason, and the
rest of the text saves as usual). In a card's description, Escape
finishes editing. What is saved is the Markdown, exactly as typed.

A page has three names, and they do different jobs. Its **code** — `W-31` —
is short, globally unique and stable across renames, so it is what belongs in
a commit message or a link. Its **slug** comes off the title and is what the
URL reads as. `board-code/slug` names a page on another board. All three are
accepted anywhere a page is asked for.

**Folders.** A page sits on two axes, and keeping them apart is what stops a
wiki turning into a maze. Its **parent page** says what it is *part of* — the
rollback half of the runbook, the appendix of the spec — and reading the parent
should make you want to read the child. A **folder** says where it is *kept*:
"Design", "Contracts", "Meetings", holding documents that have nothing to do
with one another except that somebody files them together. Conflating the two
forces anyone who just wants somewhere to put things to invent a parent page
that is about nothing, and then read past it forever.

So folders are their own thing: a tree of names on the board, nested to any
depth, made and renamed and moved from the wiki's own sidebar, with the pages
filed in each drawn inside them. Both axes are optional and neither implies
the other — a child page can be filed in a different folder from its parent,
and most pages are in no folder at all, which is the root rather than a limbo.

**A folder is a place you can be.** Clicking one in the sidebar opens it at
`?folder=`: what is filed in it, the folders beneath it, and the things you do
to a folder — write a page here, make one inside, rename or move it, delete it
— gathered in one place rather than only on a hover menu.

**Icons and colours.** A folder or a page can wear an icon and a colour, so
the things you reach for most stand out. A folder's **Edit folder…** (on its
own page or its tree menu) and a page's editor both offer the icon set and the
palette, each with a *None*. They show on the wiki's main page — the folder
cards, a folder's listing, Recently changed and a page's heading — and in the
tree too, unless a writer turns **Icons and colours** off under the tree's
*Show in the tree* menu; that choice is the board's, for everyone reading it.
A page's colour is the same colour it carries on the board. From the command
line: `slipdock folder new <board> <name> --icon star --color amber`,
`slipdock folder mv <board> <folder> --icon book-open` (or `--no-icon`,
`--no-color`) and `slipdock page edit <page> --icon flag --color rose`.

A board (or one folder of it) mounted in a vault shows in the vault's tree as
a folder too, and wears an icon and a colour the same way: its tree menu has
**Icon and colour…** for the vault's owner. What it wears there is the
vault's, set on the mapping rather than on the board, so it is the same
wherever the vault's tree is read. From the command line:
`slipdock vault dress <vault> /Jobs --icon briefcase --color amber`
(`none` takes either off).

**Opening and shutting the tree.** A folder's chevron opens or shuts it, and
so does a page's when it has pages under it. The double chevron at the top of
the sidebar shuts every folder at once, and opens them all again once they
are all shut. An empty folder has no chevron, there being nothing in it to
show. Which folders you had open is kept for you on the server, per board and per
vault, so the tree opens the same way next time, on any machine, and
following a link to another page doesn't spring it open or shut. The
crosshair at the top of the tree shows where you are again after you have
shut or scrolled it away. On a
first visit a small wiki (300 pages or fewer) opens with every folder open,
and a bigger one opens only the folders on the way to where you are. The
folders leading to the page or folder you are on always open, and the tree
scrolls to it, so what you just went to is never hidden.

**The keyboard.** Click a row and the tree takes the keyboard: the arrows walk
it, right opens a folder and steps into it, left shuts it or goes up to the
folder it is in, Enter opens the row, F2 renames it, Delete archives a page or
deletes a folder (both ask first), Space shows the highlighted page's
preview (and Space again puts it away), and typing a few letters jumps to the
next row that starts with them. The page-wide shortcuts stand down while it
has the keyboard.

**A page's preview.** Rest the mouse on a page in the tree for a moment and a
card beside the tree shows what is in it without opening it: its summary, the
start of its text (headings kept, code and embedded files left out, encrypted
text a 🔒), its tags, how many pages are under it, which board it is on when
that is another board of the vault, and who changed it last and when. Moving
off the page puts it away. A touch screen has no hover, so there a tap opens
the page as before.

**Wider, narrower, or out of the way.** On a wide screen the « at the left of
the wiki's bar folds the tree away, and » brings it back. Drag the tree's right
edge to make it wider or narrower (180–640px); the edge can be focused with Tab
and moved with the arrow keys, Home and End, and a double-click or Enter puts
the width back. Both are remembered in this browser, not on the board.

**A column, or the full width.** A page is read in a column of comfortable
width. The arrows button beside the « widens it to fill the whole space beside
the tree, and pressed again puts the column back. The choice holds on every
page and is remembered in this browser. Editing always uses the full width.

**Recent.** The *Tree · Recent* switch, the folder and clock icons beside
*All pages* at the top of the tree, turns it into a flat list of the board's pages, the most recently edited first (up to 100),
each with the time it was edited (the day, if not today). The filter bar
narrows it as it narrows the tree, and it keeps itself up to date as pages
change. The choice is remembered in this browser. The same list from a
shell is `slipdock page ls <board> --recent`; `?recent=true` on the API, or
`recent` on MCP's `list_pages`.

**On a phone** the tree is a drawer: **Pages** in the wiki's bar slides it in
over the page, opened to where you are, and a tap outside it, Esc, or opening
a page shuts it again. Its rows are taller for a finger, holding one opens its
menu, and the `⋯` on each row is always shown.

**Big wikis.** The tree is built for thousands of notes. It loads one folder at
a time, when you open it, and never a page's text. Only the rows on screen
are drawn, so a folder of 5,000 notes scrolls like one of fifty. A big
folder's rows arrive 500 at a time as you scroll down to them, and the page
you are reading is always loaded, however far down its folder it is.

**Jumping to a note.** `Ctrl-O` (`Cmd-O`) on a wiki opens the note switcher:
a few letters of a note's title, an alias or its vault path, matched in order
the way editors' switchers match, across the whole vault (see *Keyboard*).

**A vault's own view.** A vault opens from its tile on the home page into a
view of its own, at `/vaults/<vault>`: the vault's tree down the side, every
board of it laid out by the vault's paths (a mapped path is a folder holding
that board's wiki, or one folder of it, marked with the board it comes from),
and pages addressed by their vault paths, the same as the files on disk —
`/vaults/Notes/Projects/Roadmap`, with `.md` or without, case aside.
A page opens inside the view, under the vault's breadcrumbs, with a quiet
*on Handbook* saying which board holds it: its permissions, history and
comments are that board's, and editing, history and new pages behave as on a
board's wiki (a new note made in a folder lands on the board mapped there).
Folder **Move…**, dragging across boards and **Give it its own board…** work in
its tree. A search or a filter runs across every board of the vault, keeping
only the paths that hold a match. **Settings** (`/vaults/<vault>/.settings`)
is where boards are mounted at a path and the vault is renamed or deleted.
Board wiki addresses keep working.

**A board's wiki in a vault** is the vault from where the board is mounted
down, like a chroot. Handbook, mounted at `/`, shows the whole of
Notes: its own folders, and *Projects* (Project Work's wiki, mounted at `/Projects`) as
a folder among them, in the same order as the folders around it — by name
when the tree is sorted by name. Project Work's own wiki shows `/Projects` and what
is mounted below it, and nothing above. What is mounted below one of a
board's folders shows inside that folder. A board with only a folder of it
mapped shows its whole wiki, as a board in no vault does. There is no switch
between trees: the board's tree is the right part of the vault already, and
the vault view is the tree of the board at `/`.

Opening a page of another board from a board's tree keeps that tree and its
breadcrumbs: Roadmap opened from Handbook's tree opens at
`/boards/<project work>/wiki/roadmap?in=<handbook>`, with a
quiet *on Project Work* beside the breadcrumbs that opens it in Project Work's own
wiki. The filter bar and the tree's search cover what the tree shows, so
from Handbook they find Projects pages, and from Project Work they don't find
Handbook's. A board of the vault you can't open isn't in your tree.
Organising works across it on the boards you can write to: a page dragged
onto *Projects* moves to Project Work, after asking.

**Dragging rows about.** With a mouse, a writer drags a page, a folder or a
file straight from the tree: press on its row and move. A press that moves
less than a few pixels is still a click and opens the row, so reading is
never a filing change. Both axes are rearranged in the same tree — a page
dropped in a folder is *kept* there and belongs to no page; a page dropped
on a page becomes *part of* it, filed where that page is filed; a folder
dropped in a folder moves under it, and cannot be dropped inside itself; a
file (an image, a PDF, a drawing) dropped in a folder is filed there, and
dropped on anything else goes to the folder that row is in — a file is never
part of a page, stays on its own board, and is refused where a file of the
same name already is. Drop on the middle of a row to put something inside
it, or on its top or bottom edge to put it beside it. In a folder sorted
*as arranged*, order is what you dragged: positions are packed afterwards so
a tree arranged by hand stays arranged. A folder sorted by name (the
default) or by date keeps that order: what is dropped beside a row is filed
there but takes its a-z place, and the tree says so; choose **Sort: As
arranged** to order it by hand, and it comes back as last arranged. Rest a drag on a shut folder and it opens, so you can drop deeper
without opening it first. In a vault, a file moved here moves on disk at the
next sync.

**Organise mode.** The pencil at the top of the wiki's sidebar gives every
row a handle to drag by, with a reminder of what a drop does. It is how a
touch screen drags (a finger on a row scrolls, and resting on it opens its
menu), and works the same with a mouse.

**A row's menu.** Right-click a row, or press its `⋯`, for what can be done
to it. Anyone can open it, open it in a new tab, or copy its link. A writer
can also:

- make a new note, folder or drawing in a folder (a drawing is an empty
  Excalidraw note, `….excalidraw.md`, as Obsidian's plugin writes one), or
  a new note inside a page;
- rename it, move it, or file a page in another folder as well (see
  *One page, several folders*);
- tag a page, archive a page, or delete a folder;
- **Delete…** a page for good, history and all. It asks first, saying how
  many pages under it are kept (they move to the top of the tree), and only
  the board's owner can confirm; anyone else is told so and can archive it
  instead. Deleting the page you are reading takes you back to the wiki;
- sort a folder: as arranged, by name, last changed first, or newest first,
  with its folders always before its pages, or **Same as the top** to have
  it follow the top's order (a folder does until it is given one of its own);
- **Organise…** a folder (see below).

**Organising a folder.** A folder's **Organise…** sorts what is filed in it —
its pages (with any pages under them) and its files — in one of four ways,
shows where each item would go with a tick box beside it, and files the
ticked ones when you press **Organise**. Folders that aren't there yet are
made on the way.

- **By date** puts each item in a dated folder under a parent you choose
  (the folder itself unless you pick another; empty for the top of the
  wiki): a note written on 12 October 2026, organised into *Meetings*, goes
  to *Meetings/2026-10* under the same name. One folder per month, year,
  year then month (*2026/10*) or day. A note's own `created:` or `date:`
  front matter is its date when it has one, since a note brought in from a
  vault was only *added* the day it was imported; choose **When it was
  added here** to ignore it.
- **AI suggestions** asks a cheap model (Claude Haiku by default, or the
  model you picked under Account → AI model) to read the board's folders,
  with a few example titles from each, and the titles in this folder, and
  suggest a home for each. It may suggest a new folder inside an existing
  one, never a new top-level folder; anything else is dropped. Nothing is
  sent until you press **Suggest destinations**.
- **By tag** puts a note in a subfolder named after its first tag
  (`#project/acme` makes *project/acme*); untagged notes stay.
- **Flatten** brings everything filed in the folder's subfolders, however
  deep, back up into it. The emptied subfolders stay.

Only the folder's own board is organised; to move things to another board of
a vault, use **Move…**. A file whose name is already taken where it would go
is left where it is, and the message says so. From the command line:
`slipdock folder organise <board> <folder> --by date --parent Meetings
--dry-run`.

Right-click the tree's background for the same things at the top of the
wiki, including how the top is sorted. The top is sorted by name until
someone chooses otherwise, so a wiki reads a-z, ignoring case, folders and
pages alike, including folders a vault's sync adds later.

**Picking several.** Ctrl-click (Cmd-click on a Mac) picks rows one at a time
and Shift-click picks every row from the last one. A bar above the tree then
moves, archives or tags them all at once, and a row's menu acts on all of
them. Esc lets go.

**Moving a page to another board.** In a vault, a page can move to any other
board of the vault you can write to: drag it there in the vault's tree, or
use **Move…** from its menu. Before it moves you are shown what it takes and
what it can't. It keeps its code (`W-31`), history, comments, checklist,
links and its other folders, and the pages under it go with it. Tags and
custom field values go where the other board has one of the same name (or
key), and pinned cards stay pinned where the card is in that board's tree.
Whatever has no match is listed and stays behind, as do its place in a list,
an assignee who can't open that board, and its parent page. On a shell,
`slipdock page mv <page> --board B [--folder F] [--dry-run]`.

**Moving a folder to another board.** In the wiki, a folder's **Move…**
offers every board of the vault you can write to and its folders, and
dragging a folder onto another board in the vault's tree does the same.
Either way you are shown what goes first — how many folders, pages and files,
what can't be carried, what stays behind, pages landing beside one of the
same title — and nothing moves until you confirm. Pick several rows (pages
and folders together) and **Move** them as one, with one combined report; a
page inside a folder you also picked goes with the folder, once.

A folder moves to any board you can write to — in a vault or not — with its
subfolders, every page at home in them (and the pages under those pages) and
the files kept in them, in one go:
`slipdock folder mv <board> <folder> --board B [--parent F] [--contents]
[--dry-run]`. The folders keep their names and order, under `--parent` on the
other board or at its top; with `--contents` only what is *in* the folder
moves, landing straight there, and the emptied folder goes. Each page keeps
its code, history, comments, checklist and links, and carries its tags,
field values, pins and assignee the way a single page does. `--dry-run`
reports it all first, folder by folder: how many pages, what can't be
carried, any page that stays behind (one filed there under a parent page
that isn't moving), filing in other folders that can't follow across boards
outside a vault, and pages landing beside one of the same title. It is
refused, with nothing changed, when a folder of that name is already where
it would land, when a vault maps onto a folder in it (take that mapping out
first), or when you can't write to both boards; and it happens all at once
or not at all. A synced vault sees each moved note as the same file at its
new path, or — when the vault's mappings put it at the same path — no change
at all. Over the API it is `PATCH /api/boards/:board/folders/:folder` with
`to_board`; over MCP, `manage_vault` with `action: "move_folder"`.

**Searching the tree** matches a page's title and summary *and* a folder's
name, and hides everything that doesn't match. A folder that matches brings
what is in it, because somebody typing the name of a folder is asking where
things are. A page that matches keeps the pages and folders above it, shown
faded, so you can see where it lives. A word starting with `#` matches a tag:
a note's own `#tags` (nested ones too, so `#area` finds `#area/sub`) or one of
the board's tags by name, so `retry #ops` is pages tagged *ops* with *retry*
in their name. By default it does not read the words inside the pages; under
the search, **Match the words inside pages here too** turns that on. That is
a plain match on the text. Search (`/search`) reads bodies and matches by
meaning: **Full text search for: _what you typed_** is one click to the same
words there, already narrowed to this board.

**Picking a folder is a tree you type at.** Everywhere the app asks which
folder — filing the page you are reading, the Folder field in the editor, the
"Inside" of the New folder dialog — it shows the filing as a tree and narrows
it as you type, matching anywhere in the path, so "dec" finds `Design/
Decisions` and the arrow keys and Enter pick it without the mouse. A folder
you cannot choose, like the one you are moving, is greyed rather than hidden.

**One page, several folders.** A page has one **home** folder and can be
**also filed in** others, like a symbolic link: every one opens the same
page, with one body and one history. On a board in a vault the other folders
can be on any board of the vault. Listing a folder includes the pages also
filed there, marked `also: true` over the API, and each page appears once.
Archiving or moving a page keeps its other folders; taking it out of one
never archives it; deleting a folder takes only its placements. In the
wiki's tree the page shows in each folder it is filed in, with a link marker
on the extra ones. Its menu there has **Also file in…** to add one, and the
extra row's menu has **Take out of this folder**. Only readers who can open
the page's own board see it in the other folders.
`slipdock page file <page> --also F` (or `--not-in F`) — F a folder on its
board, on `--board B`, or a vault path such as `/Projects/Notes` — and
`{"also": F}` / `{"not_in": F}` on `POST /api/pages/:id/folder` (MCP:
`update_page`'s `also` and `not_in`) do it; a page's JSON lists them as
`also_in`.

**One folder, several places.** A folder can be also filed in other folders
the same way (#808): it appears there with its whole subtree — pages, files,
drawings and subfolders — and there is still one folder with one set of
contents, at home under its parent. The rules are the pages': the other
folder is on its board or on a board of the same vault, you need write on
both, and it is never its home parent. Nor is it ever inside its own subtree,
whether the way down runs through home parents or through other placements;
moving a folder home under one filed inside it is refused the same way. In
the tree the placed folder follows the folders at home there, with the link
marker; it opens and shuts there on its own (each place keeps its own open
state), shows only what the reader may open, and is not dragged about — nor
is anything inside it, there. Its menu has **Open**, **Open in a new tab**,
**Take out of this folder** and **Copy link**; any folder's menu has **Also
file in…**. The folder's page says where else it is filed. Listing a folder
(`page ls --folder`, `list_pages`' `folder`) includes the pages anywhere
under the folders placed there, marked `also`. A synced vault writes the
folder once, at home. Moving it to another board drops the placements the
move leaves outside one board or vault, and says which
(`folder_filing_dropped`); deleting either folder takes its placements.
`slipdock folder file <board> <folder> --also F` (or `--not-in F`; both
repeat; `--board B` for a folder on another board of the vault, or a vault
path), `{"also": F}` / `{"not_in": F}` (with `in_board`) on
`PATCH /api/folders/:id` or `/api/boards/:board/folders/<path>`, and the MCP
tool `file_folder` do it. A folder's JSON lists them as `also_in`;
`slipdock folder show <board> <folder>` and `folder ls` print them.

### Sharing pages and folders

A page or a folder can be shared on its own with somebody who has no reason to
see the rest of the board (#813): **Share…** on the page's ⋯ menu, or on a
page's or folder's menu in the tree, adds a person by email (a stranger is
invited, as for boards) or one of your groups, **read only**, **can comment**
or **can edit**, and lists and takes back what is there. Only the board's owner and writers can
share; somebody a thing was shared with cannot pass it on. A shared page or
folder wears a small people mark in its owner's tree, and Page details says how
many people and groups have it.

**Sharing a folder shares everything at home in it** — its pages, files of every
kind, drawings and subfolders, to any depth. What is only *also filed* in a
shared folder from elsewhere is **not** shared by that: it shows only to people
who can already read it, so filing a page into a shared folder never quietly
shares it.

**A shared page brings what it embeds.** An image, a file or a drawing the page
embeds with `![[diagram.png]]` shows for whoever the page is shared with, even
when it lives in a folder that isn't shared (#832) — it is served to them
through the page, and to nobody else. Only embeds count: a file the page merely
links (`[[Report.pdf]]`) stays as readable as it was. And only embeds written by
somebody who could see the file themselves: somebody the page was shared with
to edit can't write `![[secret.png]]` into it to read the owner's other files.
Images pasted into a page are the page's own, and always go with it. A published
page (`/w/…`) still shows no embeds.

**Shared with me.** Whatever has been shared with you appears under **Shared
with me**, below every one of your wiki and vault trees and on the Wiki page,
grouped by whose it is; a shared folder opens to its whole subtree, and the
section is hidden when nothing is shared. It follows the shares live: one given
appears, one taken back goes, and a page open when its share is taken back sends
you back with a word. A page opens in the Shared view (`/shared/pages/:id`),
which never shows the board it is on, its cards or its other pages — a link in
it to anything you can't open reads "a page you can't see". Files and drawings
open in their own viewers as ever, and go back to Shared with me.

**What a share to edit lets you do.** Somebody with **can edit** on a shared
folder edits and renames what is in it, makes pages, files, drawings and
subfolders inside it, and moves things about within it. New things are the
owner's: on the owner's board and counted against the owner's limits, with you
as their creator. They cannot delete, archive or restore anything; move
anything out of the share, to the top of the wiki or to another board; move the
shared folder itself or organise its folders; share it on or publish it at a
public link; or encrypt it. A page shared on its own is edited and renamed, not
moved. These rules hold in the API, the CLI and MCP as well as in the browser:
each refusal is a `403` with a code (`shared_no_delete`, `shared_no_move_out`,
`shared_no_reshare`, …) and says why. Writers on the board keep everything they
always had.

**Filing a shared item in your own tree.** **Also file in…** on a page or
folder in the Shared view files it in a folder of one of your own boards — the
one time something is filed outside its own board or vault. You need to read it
through the share and write the folder. It shows there only to people who can
read it (others on your board see nothing), opens in the Shared view, and comes
out again with **Take out of this folder**, which never touches the share.
Taking the share back takes the placement away too; sharing again doesn't bring
it back.

**In a synced vault** a shared item filed there syncs as **stubs**, never its
content: `Title.md` holding one line, a link to it in Slipdock (`name.png.md`
for a file), and a shared folder as a directory of stubs mirroring its subtree.
They follow renames and moves inside the share, and go when the share or the
placement does. An edit to a stub is not sent: the next sync puts it back and
says so (`↺`). The owner's own sync is unchanged.

`slipdock page share <page> <email|group> [--write] [--off]`, `slipdock folder
share <board> <folder> …` (nobody named lists who has it), `slipdock shared`;
`POST`/`GET`/`DELETE /api/pages/:id/grants` and `/api/folders/:id/grants`,
`GET /api/shared`; the MCP tool `share` and `list_pages` with `shared: true`.

**Filing never destroys writing — unless you say so.** Deleting a folder
deletes the folder: its subfolders move up to its parent and its pages go back
to the board's root. Deleting one that holds something asks which you meant,
and the other answer — the folder *and* everything in it, pages and history —
is the board owner's to give, as purging a page is. A folder cannot be moved
inside itself. A folder named as a path — `Design/Decisions` — makes every
level it needs, and making the same path twice makes it once, so an agent
filing a document never has to build the filing cabinet in a separate call.

**Deleting a page.** Archiving is the reversible one and is what the page's
actions menu offers first; **Delete permanently** below it is the owner's
purge — the page, its whole history and its attached images, gone, with the pages *under* it kept
and lifted to the top of the tree rather than going silently with it. The same
menu downloads one page as Markdown, front matter and all.

**The Wiki view** at `/wiki` (from the Home page, the account menu, or the
command palette) is the same thing over every board the reader can open: each
board a top-level folder, its folders and pages inside, with a search that
narrows the lot by title and summary. It is read-only on purpose — making and
moving folders belongs on the board that owns them, where the permissions and
the rest of the wiki's tools already are, and a folder's name there links
straight to it on its own board.

Bodies are CommonMark with the GitHub extensions — tables, task lists,
strikethrough, autolinks, footnotes — rendered by comrak (`:mdex`) and
sanitised, so raw HTML in a body never becomes raw HTML on the page. Headings
get ids, so a section can be linked to.

The editor is **raw Markdown with a live preview**, deliberately and for good:
the source stays diffable, greppable and identical to what an agent reads and
writes over the API, which a rich-text layer could not promise. Pasting or
dropping an image into it attaches the image, the way it does on a card.
The editor spans the whole width of the page; **Preview** beside Save puts the
preview away (and brings it back) for the source alone, and your browser
remembers which you chose.

**References.** Inside a body, `[[Retry policy]]` links a page on this board
(by title, then slug), `[[retry-policy|how it works]]` gives it link text,
`[[QVM/Retry policy]]` reaches another board, `[[W-31]]` (or a bare `W-31`)
uses a page's code, and `[[board:QVM]]` / `[[view:QVM/Blocked work]]` reach a
board or a saved view. `@name` mentions someone on the board.
`[[!toc]]`, `[[!children]]` and `[[!backlinks]]` expand when the page is read.

As in Obsidian, `[[Retry policy#Backoff]]` goes to a heading of a page and
`[[Retry policy#^a1b2]]` to a block — a paragraph or list item ending in
` ^a1b2`, which is an address and is not shown — and `[[#Backoff]]` to a
heading on the page itself. `![[Retry policy]]` **embeds** the page where it
is written, and `![[Retry policy#Backoff]]` or `![[Retry policy#^a1b2]]` just
that section or block: drawn for whoever is reading, one level deep (an embed
inside an embed is a link), and on a published page only named. An embed of a
file (`![[diagram.png]]`) stays as written for now. The API's Markdown
render quotes what an embed shows.

`#412` (or `[[#412]]`) is a **card chip**, drawn from what the card says at
the moment the page is read — its title, its list, whether it is done — so a
card renamed or finished after you wrote about it is never stale in your
prose. A number that matches no card you can open stays literal, so
"#1 priority" survives, and a chip for a card the reader cannot open degrades
to plain text rather than telling them it exists.

A reference inside backticks or a fenced block is not a reference: the wiki's
syntax is applied to the *parsed document's text nodes*, not to its source, so
that is a property rather than a promise.

**Wanted pages.** A `[[link]]` to a page nobody has written is not an error —
it renders as an invitation to write it, carrying the title through, and the
wiki's index lists every one, most-wanted first. That is the classic way a
wiki grows and a good work queue. Writing the page brings every link that was
waiting for it to life, and because a link is stored by id once it resolves,
renaming a page can never break the links into it.

**Sections.** A page can be addressed by heading — `Deploy/Rollback` is the
`## Rollback` under the `# Deploy` — and read, replaced or appended to one
section at a time. Two writers touching different sections never collide, and
an append cannot clobber anything at all, so it takes no hash and never
refuses. That is the write an agent keeping a `## Log` should use.

**Live queries.** A fenced ```` ```slipdock ```` block in a page is a question,
answered when the page is *read* rather than when it was written — so a
hand-typed list of blocked cards, which is wrong by Tuesday, becomes one that
never is:

````
```slipdock
view: table
board: this
filter: flag=blocked, due < +7d, priority in high|critical
group: assignee
sort: due_date asc
fields: title, assignee, due_date, status
limit: 20
empty: "Nothing blocked and due this week."
```
````

It is evaluated **with the reader's permissions, every time** — never the
author's — so a document cannot become a way to see cards you could not
otherwise open: a board the reader cannot read is dropped before a single
card is looked at. The block compiles to the same `Slipdock.Swimlanes.Config`
the board views use, and anything a config cannot express is handed to the
automations' own condition vocabulary, so there is one filter language rather
than two. `board:` takes `this`, `tree` (the board and everything beneath it)
or another board's code; `saved_view: "Blocked work"` embeds a view you
already made; `card: 412` with `view: progress` rolls one card's tree up;
`assigned: me` is the reader's own work. Every board view offers **Write this
into a doc**, which starts a page with the matching block already in it — the
honest way to author one without learning the syntax.

Views are `table`, `list`, `board`, `count`, `progress`, and `timeline` /
`calendar` as presets of the first two. A block that cannot be answered
renders as a note on the page with the reason and the block beneath it: a
document with one bad query is still worth reading.

In a sentence, `{{count: flag=blocked}}`, `{{progress:412}}`,
`{{card:412.due_date}}`, `{{board.name}}` and `{{today}}` answer inline. An
expression the app does not understand is left exactly as written — which is
also what keeps a template page, whose `{{card.title}}` is filled when a page
is *made* from it, readable before it is used.

**Backlinks and pins.** Every page shows what links to it. A page can be
*pinned* to a card — "this is the spec for that" — which is a person's
judgement rather than something the prose says, so it survives a rewrite.

**On the board.** A page can be put in one of its board's lists and dragged
about like a card — the spec sitting in "In Progress" beside the work it
describes, the retro waiting in "To Do" to be written. It shares one position
sequence with the cards, so it sits *between* them rather than after them all,
and moving a card past it works the way moving a card past a card does. It is
a second, optional axis: the page keeps its place in the wiki tree either way,
and taking it off the board changes nothing about the page.

**A page has the card's facets.** Priority, flags, tags, an assignee, start
and due dates with the same fuzzy precision, a done tick, a percentage, a
cover colour — the same field names and the same vocabularies, so nothing in
the view layer has to ask which it is holding. These are the attributes that
say *where a thing stands*, and they are what a board groups, filters and
sorts by.

**And nearly all of its contents.** Comments, status updates ("this spec is
at risk"), a checklist, web links, votes out of the board's budget, and the
board's custom fields. Not a second set of tables — the *same* tables, with
each row belonging to exactly one of a card or a page and the database
enforcing it. So there is one way to write a comment, one set of readers, and
the same components draw both panels.

What stays card-only is the work-shaped pair: blocking **dependencies** and
typed **card links**, which are card-to-card joins carrying scheduling
meaning, and **sub-cards**. A page has richer ways of pointing at things —
`[[wikilinks]]`, backlinks and pins, which say what a document is *about* —
and child pages, which is what its subtree is for. Ask a page for the rest
and you get an empty list, not an error.

A comment on a page is writing too: `[[Retry policy]]` in one turns up in
that page's backlinks, naming the page it was written on — exactly as a
comment on a card does.

So a placed page is drawn as a card, and behaves as one everywhere. It has a
cover strip, its priority chevron, its assignee's avatar, its due chip; it
appears in **every** view — board, swimlanes, table, timeline, calendar — and
is grouped, filtered and sorted beside the work. Drag it into the "Critical"
row and its priority changes, exactly as a card's would. The one difference
is the small **document icon** where a card's tick box would be: clicking it
opens the document, and clicking anything else opens the card-style panel —
priority, assignee, dates, flags, tags, list, and the comments, checklist,
status updates, links, fields and votes — with **Open the document** in it.
Two gestures, no ambiguity. The document's own page carries the same sections
below the prose, which is where most of that conversation actually happens.

A wiki that is only documents can do without them. Untick **Card features on
wiki pages** in the board's settings and every page in that board's wiki — its
own view and its panel on the board — leaves out the status, checklist, links,
fields, votes and comments. It is one switch for the whole wiki, and nothing
is deleted: tick it again and they are all back. From the command line it is
`slipdock set-board <board> --no-page-card-features` (or
`--page-card-features`), and over the API `PATCH /api/boards/:board
{"page_card_features": false}`.

A draft on the board is visible only to people who could edit it, and a page
counts towards nothing — not the card count, not the WIP limit. Deleting a
list leaves its pages behind, unplaced rather than deleted.

**Both ways.** A card's panel has a **Docs** section listing every page that
mentions it, pinned first, with **Write it up** to start one — pre-titled,
pinned, and filled in from a template page when the board has one — and a
picker to attach a page somebody has already written, which is the commoner
case. The page, in turn, has a **Cards this is about** section with the same
pin toggle and the same picker, so the two are one click from each other in
both directions. A pinned link is a person's judgement rather than something
the prose says, so replacing every word of a page never detaches it from its
card. From the other side, selecting a passage of a page offers to make a card
of it: the first line becomes the title, the rest the description, and the link
is written into both ends, so a document is where a backlog comes from. A
comment on a card can `[[link]]` a page too, and shows up in that page's
backlinks — writing on cards is writing.

**Templates.** A page marked a template is not read as content, it is copied.
Bodies may use the same `{{…}}` placeholders an automation action does —
`{{card.title}}`, `{{board.name}}`, `{{today}}` — plus any values passed in,
and Obsidian's own: `{{title}}` (the new page's title), `{{date}}`
(`2026-03-07`), `{{time}}` (`14:05`), and `{{date:dddd D MMMM YYYY}}` or
`{{time:h:mm A}}` in Moment's format, as Obsidian writes them — so a template
brought over from a vault works as it is. Dates and times are UTC.
A board template can carry `pages` as well as lists, so a new board arrives
with its documentation skeleton rather than an empty wiki. A page can also be
a **favourite**, alongside boards, lists, cards and views.

**Every save keeps a revision** — a full snapshot, with the author, the edit's
own message ("why", not "what"), and how it arrived (`web`, `api`, `cli`,
`assistant`, `automation`, plus the API token's name). History lists them,
any one can be diffed against the one before it or any two compared side by
side (old on the left, new on the right, the changed words picked out, as
GitHub's split view does: tick two in the history and press **Compare selected
versions**, or **Compare with current** from an old one), and any one can be put back —
which is itself a save, so nothing is ever removed. Consecutive saves by the
same hand within ten minutes collapse into one, so an agent appending every
few minutes does not bury the day's real edits.

**A save can carry the hash it was based on.** Every page has a
`content_hash`; send it back and a save that would land on top of someone
else's is refused with both versions to merge, rather than applied. Leave it
out and the last write wins, which the revision makes recoverable but is
still a paragraph gone. Two agents and a person may all be writing the same
runbook.

Pages are archived rather than deleted (with the pages beneath them), and only
a board's owner can purge one. A page can be marked a **draft**, which makes
it visible to people who could edit the board and to nobody else, and it can
be **shared on its own** — a grant on the page reaches it without opening the
board, so "share just this doc" never has to be answered with "move it
somewhere else". A board reachable only through a shared saved view does not
reach pages at all: a view is a window onto cards, and must not leak the
documents beside them.

**Semantic search covers pages too**, in the same index and ranked against
cards: "what did we decide about refunds" finds the decision record and the
card that argued about it, in one list. A page is chunked **by heading**
rather than by a fixed window — a section is what a person wrote as a unit,
and a heading is a free label for it — so a result links to the section
(`…/wiki/runbook#rollback`), editing one section re-embeds one section, and
`--kind pages` narrows the search to documents. A page's title counts for the
keyword boost as well as its body, and a document ranks a shade below a card
of equal score: the card is the live thing and the page explains it. Drafts
are never indexed, and a page the reader cannot open never comes back — the
reader's own permission is re-checked on the way out rather than trusted to
the index.

The assistant has the wiki too: `search_pages`, `read_page` and `list_pages`
alongside its card tools, so "how does X work" and "is there a runbook for X"
are answerable — and it is told to say so when a card and a page disagree
rather than choosing between them.

Over the API: `/api/boards/:board/pages` (GET, with `?tree=true`, `?q=`,
`?parent=`, `?folder=`, `?archived=`, `?template=`; POST to write one) and
`/api/pages/:id` (GET, PATCH, DELETE, plus `/render`, `/sections`,
`/section/*path`, `/append`, `/links`, `/folder`, `/restore`, `/move`,
`/revisions`, `/revisions/:rev?diff=previous` (or `?diff=<revision id>` to compare
with another version) and `/revert`). Reads return the
Markdown source, not HTML — the model edits what it reads — and `/render`
returns it with every reference followed, which is what to read to answer a
question rather than to change the page. Folders are
`/api/boards/:board/folders` (GET, POST), `/api/folders/:id` (PATCH, DELETE —
`?purge=true` takes the pages in it too, owner only; also by any handle at
`/api/boards/:board/folders/*path`), and `/api/wiki` is
every board at once. `/api/boards/:board/tree` is one level of the tree the
way the web's tree loads it — the rows directly in the root, a folder
(`?folder=`) or a page (`?page=`), each with how many rows are under it, and
never a body; `slipdock folder open <board> [<folder>]` prints it. On a shell, `slipdock page ls|tree|read|render|new|edit|
section|append|file|mv|rm|restore|links|pin|wanted|history|diff|revert`, plus
`slipdock wiki` and `slipdock folder ls|open|new|mv|rm [--purge]`.

**Publishing.** A page can be published read-only at `/w/:token`, the way a
saved view can. Its live queries are answered **when you publish** and the
answers kept, and its references — card chips, page links, mentions — become
plain text: there is nobody behind an anonymous request to have the
permissions a live query or a followable link would need, so a published page
is a live copy of its prose and a snapshot of its answers. Publishing again
refreshes them; a draft cannot be published at all.

**Automations reach the wiki.** `create_page` starts a page for the triggering
card, pinned to it and from a template page if one is named, and `has_doc` is
a condition — so "when a card lands in Ready and nothing has been written
about it, alert me" is a rule rather than a habit.

**Out and back in.** `/boards/:id/wiki.zip` downloads the whole wiki as one
Markdown file per page — front matter carrying what Markdown cannot say, the
tree as folders, and `[[links]]` left exactly as written in the dialect
Obsidian reads. A folder of Markdown imports the same way, folders becoming
parent pages, and a title already on the board is skipped and reported rather
than duplicated. This is the escape hatch, and it is deliberate: a wiki you
cannot get your writing out of is one to think twice about putting writing
into.

**Front matter is kept exactly.** A file imported with front matter keeps
all of it — key order, quoting, comments, the blank line before the body —
not just the keys Slipdock reads (`title`, `summary`, `status`, `template`).
The page shows it folded away as **Properties**, and an export writes it back
with only Slipdock's own keys patched in place; a `status: reading` of your
own is left alone. The file a later sync writes gets no key that changes on
every save — no `updated`, no author, and `code` only if asked. Read and
replace it with `slipdock page props <page> [--file F | --clear]`, the API's
`front_matter` field (the YAML between the `---` lines), or MCP's
`read_page` and `update_page`.

**Aliases.** A page whose front matter lists `aliases` (or Obsidian's older
`alias`) answers to each of them: `[[Retries]]` finds the page whose aliases
include "Retries", case aside, wherever `[[Retry policy]]` would. A page
titled with the word beats one that only answers to it, and a link written
before the alias existed comes alive when it is added. Aliases are read from
the front matter, so they are changed there (`slipdock page props`), and a
page's JSON lists them as `aliases`.

**The wiki keeps the board's bar.** The view selector, the search box, the
filter menu and the display options sit above the wiki the way they sit above
every card view — because a page answers the same filters now that it carries
the same facets. Narrow by priority, flag, tag or due date and the page tree
narrows with it; a page whose parent was filtered out stands at the root
rather than vanishing with it. The display menu is the wiki's own: whether to
list drafts, templates and archived pages at all.

The full specification, and the decisions behind it, is in `docs/wiki.md`.

### Vaults

A **vault** is a folder tree of Markdown (and other) files: notes, images,
PDFs. The word is borrowed from Obsidian, which keeps notes that way, but
Slipdock doesn't need Obsidian; any editor that works on a folder of Markdown
will do. Here a vault lays several boards' wikis out as one such tree, which `slipdock sync` mirrors to a folder on each
computer (see [Syncing a vault to a folder](#syncing-a-vault-to-a-folder)). A vault is yours alone and holds
no pages of its own. It is a name and a set of **mappings**, each a vault path
onto a board's wiki or one folder of it:

```
/            → Handbook wiki (root)
/Projects    → Project Work wiki (root)
/Projects/X  → board X wiki, folder "Notes"
```

A mapping inside another is allowed, and the **longest matching prefix
wins**, segment by segment, so `/Projects/Acme.md` lands in Project Work and
`/Projectsearch.md` in Handbook. You can only map a board you can write to,
and **a board belongs to one vault** (it may be mapped there more than once,
its root and a folder of it, say), because the vault is also where a plain
`[[link]]` on that board is looked for.

**Mappings don't overlap.** A mapping is refused while it would put pages
of one mapping at paths another owns: with Handbook at `/` holding
notes in its `Projects` folder, mapping `/Projects` onto Project Work is refused (and so
is mapping `/` onto Handbook after `/Projects`), because both boards would
claim `/Projects/...` and a synced edit to one of those notes would land on the
wrong board. The refusal says how many pages and which, and the way out:
move them to the other board first (see *Giving a vault folder its own
board*), or map somewhere else. An empty folder, or one holding only
archived pages, is no obstacle. A vault that already has an overlap is
flagged on the Vaults screen, in `slipdock vault ls` and in `overlaps` on
the API; it still syncs one file per path.

Deleting a vault takes its mappings
and leaves every page where it was; deleting a board or a folder takes the
mappings onto it.

**On the home page** your vaults are listed among your boards, a card each,
in your order like any board (drag it, or **Move up** / **Move down**), and
sorted with them by name, age, activity or cards: its name, the boards mapped
into it, how many pages it holds and the folders it is synced to, with when
each last synced. **New vault**, beside **New board**, makes one; tick *Make
a board to hold its pages* and it comes with a board of the same name, mapped
at `/` and kept inside it.

**A board kept inside its vault.** Pages live on a board — that is where their
codes, permissions and history are — so a vault like Notes has a board such
as Handbook holding its pages at `/`. That board need not stand beside
the vault as if it were something else: on the Vaults screen, **Keep inside**
on a whole board's mapping takes it off your home page's board list and names
it on the vault's tile instead (*pages stored on Handbook*, with its
card count when it has cards, linking to it). It is still the same board: its
address, the board switcher, search and its cards and rules work as before,
`slipdock boards` marks it *in Notes*, and anyone it is shared with sees it
as an ordinary board, since the vault is yours. Taking the mapping out, or
deleting the vault, puts it back on your home page. Only a whole board can be
kept inside, not one folder of it. On a shell: `slipdock vault map Notes /
--board kb --inside`, `slipdock vault inside Notes / [--off]`, `slipdock
vault new NAME --with-board`.

**The Vaults screen** (avatar menu › **Vaults**, or **Settings** at the top
of a vault view's tree) lists your vaults,
each with its mappings and how many pages each holds, and the folders it is
synced to: every `slipdock sync` token that has listed the vault or followed
its feed, by the token's label, with when it last did. Make, rename and
delete vaults there. Deleting asks first, saying that every page stays on its
board and naming the synced folders that will stop getting changes.

**Mapping from the screen.** Under each vault, *Map a path* takes a vault
path (`/`, `/Projects`), a board and, once a board is picked, optionally one of
its folders. Boards you can't map are listed but greyed out, with the reason:
you can't write to it, it is archived, or it is already in another vault.
Before you press **Map** it previews where things land: how many of the
board's pages join the vault and at which paths, which pages already in the
vault the new mapping takes over (being the longer prefix), and which synced
folders will get the new files. Each mapping's **×** takes it out, after a
confirmation naming the files that leave the vault (the pages stay on their
board) and any that fall back to an outer mapping's path. The CLI's
`vault map … --dry-run` and `vault unmap … --dry-run`, and `dry_run` on the
API and MCP, give the same preview without changing anything.

Vaults are also made and mapped from the CLI (`slipdock vault`; `vault ls`
shows the same page counts and synced folders), the API (`/api/vaults`,
whose vaults carry `mirrors` and each mapping its `pages`) and MCP
(`list_vaults`, `manage_vault`).

**Giving a vault folder its own board.** Say Notes maps `/` onto
Handbook, and Handbook keeps a `Projects` folder that should be the
Project Work board's. On that folder in the wiki's tree (yours, since it changes
your vault), **Give it its own board…** asks which board — or a new one —
and shows what would happen: how many notes and folders move, how many files
in synced folders stay exactly as they are, which of the board's own pages
join `/Projects`, and any note that lands beside one of the same title. Confirm,
and in one step everything in the folder moves to the top of that board and
`/Projects` is mapped onto it. The notes keep their vault paths, so a synced
folder sees no change to them; only the board's own pages arrive as new
files. It all happens or none of it does. On a shell:

```
slipdock vault split Notes /Projects --board work --dry-run   # what would happen
slipdock vault split Notes /Projects --board work             # do it
slipdock vault split Notes /Projects --new-board "Project Work"      # a board made for it
```

The API is `POST /api/vaults/:id/split` (`path`, `board` or `new_board`,
`dry_run`); MCP is `manage_vault` with `action: "split"`.

**Links across a vault.** On a board in a vault, a plain `[[Note]]` looks
on its own board first and then on every board of the vault. Every page
there has a vault path — its mapping's path, the folders below it, the pages
it sits under, its title: the layout an export writes — and a link matches
by name (title, slug or alias, compared as file names are, case aside).
When several pages match, the shortest path wins; write more of it,
`[[X/Dup]]` or `[[Projects/X/Dup]]`, to pick another, the way Obsidian
does. A link written relative to its note, as Obsidian writes them when
its new link format is relative — `[[../Tasks/Inbox]]`, `[[./Plan]]`, or
`[[2026/Journal/Note]]` from the note's own folder — is read from the
note's folder. A link or embed naming a file, `[[Report.pdf]]` or
`![[photo.png]]`, finds the wiki file of that name and links to it, and is
not counted as a wanted page. `[[QVM/Page]]` still means board QVM first. The words are never
rewritten, a resolved link is kept by id so a rename cannot break it, and a
page or file written later brings links on any board of the vault to life. Backlinks
cross boards with the links. `slipdock vault resolve <vault> <link>` says
which page a link finds; `slipdock vault wanted <vault>` (or
`GET /api/vaults/:id/wanted`, MCP `page_info` with `vault`) lists the pages
wanted anywhere in it. A board in no vault resolves exactly as before.

**What changed, for sync.** Every change to a page, a folder or a page's
attachment is logged with an increasing **cursor**, on every board. A
vault's feed — `GET /api/vaults/:id/changes?since=<cursor>`,
`slipdock vault changes <vault> --since N`, or MCP `list_vaults` with
`changes_since` — answers with what changed on any of its boards after that
cursor, each page or folder once and as it is now (a page's code, title,
`content_hash`, home folder, whether it is archived, and its vault path), or
`deleted`; `more: true` means ask again at once. Without a cursor it answers
with the one to start from. A client can also keep a websocket open at
`/socket/websocket?token=<API token>&vsn=2.0.0` and join `vault:<id or name>`:
each change pushes `change` with the new cursor, so it knows when to ask.
The log keeps 90 days (`config :slipdock, :wiki_changes, retention_days:`);
asked from a cursor older than that, the feed answers `resync: true` and the
current cursor, which means list the vault again rather than trust the gap.

**Tags in notes.** On a board in a vault, a note's front matter `tags` and
every inline `#tag` in its body are its tags, nested ones (`#area/sub`)
included, as Obsidian reads them: not inside code, headings, links or HTML,
and only where `#` starts a word, so a URL's `#fragment` is not one. They are
the note's own, kept apart from the board's card tags so they never fill the
tag picker, stored lower-case, and shown as chips at the top of the page. A
tag whose first part is all digits stays a card reference (`#412`). List the
notes under a tag — and anything nested beneath it — with
`slipdock page ls <board> --note-tag area`, `?note_tag=area` on the API or
`note_tag` on MCP's `list_pages`; `slipdock page tags <board>` (or
`GET /api/boards/:board/pages/tags`) counts them. On a board in no vault
nothing changes: `#word` is a word.

### Syncing a vault to a folder

`slipdock sync` keeps a folder on your computer and a vault level with each
other, both ways. The server is where the notes live; the folder is a
working copy that stays a valid Obsidian vault, so Obsidian, vim, a script
or anything else that writes a file can add to it, and what they write
becomes a page.

```sh
slipdock sync init ~/Notes --vault Brain    # bind the folder, then bring the vault down
slipdock sync ~/Notes                        # one pass, both ways
slipdock sync ~/Notes --watch                # keep at it
slipdock sync from-server ~/Notes            # one pass, only bringing changes down
slipdock sync to-server ~/Notes              # one pass, only sending changes up
slipdock sync service install ~/Notes        # …in the background, starting at login
slipdock sync status ~/Notes                 # what is waiting, and what is in conflict
```

**Files.** A note is `Title.md` in the directory its folder names; a page
with pages under it is `Title/index.md`, with its children beside it. A
title a file name cannot hold (`Retry: why`) is written with the
characters substituted (`Retry- why.md`), and the true title kept in front
matter. A note that arrived with a name of its own — front matter giving it
another title, a name longer than 80 characters or ending in a space — keeps
that name until the page is renamed. Renaming the file renames the page, and the other way round; moving
it to another directory refiles it, making the folder if there is none, and
under another board's mapping it becomes a page on that board. Notes made
in the folder are always plain files. A page filed in several folders is
written once, at its home, with `also-in: [Path/One, Path/Two]` in its front
matter; edit that list and the page is filed accordingly. Images, PDFs,
`.excalidraw` drawings and other files are kept at the same vault path, up
to 250 MB each, and `![[photo.png]]` draws them in the web app too.

**Opening a file.** Click a file in the tree, or a `[[Report.pdf]]` link
in a page, and it opens in the page's place, filling the wiki beside the
tree (on a phone it covers the page); the address stays where it was. The
file has Download, an arrow that opens it on a page of its own
(`/files/<id>`, also where Ctrl/Cmd-click and "open in a new tab" go), and
an X; Escape closes it too, and either brings back the page you were
reading, a half-written edit included. Opening a page from the tree puts
the file away. Images (PNG, JPEG, GIF, WebP,
and SVG, which is shown so it can run nothing) are drawn; a PDF opens in
the browser's own PDF viewer; an HTML file (`.html`, `.htm`) is drawn in a
sandbox: its scripts don't run, its forms don't send and it fetches
nothing, so pictures it links to are left out; audio (`.mp3`, `.m4a`,
`.wav`, `.ogg`, `.opus`, `.aac`, `.flac`) plays in the browser's own
player, the one a card's recordings have, and can be skipped through; a
transcript (`.vtt`, and `.srt`) reads as a conversation, each speaker's
turn under their name in a colour of their own with the time it starts
(a `<v Name>` tag or a `Name:` prefix names them); JSON is a tree whose objects and arrays fold
(the outer two levels open), JSON Lines an array of its lines, invalid
JSON the line and column where it went wrong; CSV and TSV are a table
with the first row as its header, the first 1,000 rows shown; `.txt`,
`.log`, `.md`, YAML, TOML, INI and XML are shown as text. Text over 2 MB,
and kinds with no viewer yet (video, archives), offer the download.
Drawings still open in the Excalidraw editor and whole Meld notes where
the browser decrypts them.

**Archiving or deleting a file.** A file's menu in the tree (right-click,
or a long press) has **Archive…** and **Delete…**, and Delete on the
keyboard asks to archive the highlighted file. Archiving takes it out of
the tree but keeps its bytes, which still count towards the board owner's
storage. Deleting it is for good and gives that storage back; only the
board's owner can delete a file, and a synced vault takes its copy away too.

**Over the API.** `GET /api/boards/<board>/files` lists the board's live
files by path (`folder=` keeps to one folder and what is under it), each
with its size, sha256 and the URL it is read from; `GET
/api/boards/<board>/files/<path>` (`Tool/template.docx`) is its bytes,
always as a download (#1156). Both need read on the board, with a token like
the rest of the API. In the CLI they are `slipdock wiki files <board>
[--folder F]` and `slipdock wiki get <board> <path> [--out F|-]`. This is how
an agent reaches a [Tool](#tools)'s board files.

**What the folder remembers.** `.slipdock/state.json` holds, for each file,
which page it is and the hash both sides last agreed on — never front
matter, so your files stay your own. That is what makes a rename the same
page rather than a delete and a new one.

**One way.** `slipdock sync from-server` brings the server's changes down
and sends nothing: no page written, archived or moved there. `slipdock sync
to-server` is the other half: it sends what changed here and writes nothing
in the folder. Either lists what it left (`· Name.md (not sent)`) as held,
and the folder keeps the version both sides last agreed for each, so the
next pass — one way or both — still finds it waiting. A note changed on
both sides is still a conflict copy under `from-server`, the copy left
unsent; `to-server` touches neither and leaves it for a pass both ways.
Both take `--watch` and `--json`.

**Conflicts.** Every write to the server says which version it was made
against. If a note changed on both sides, the server's version keeps the
name and yours is saved beside it as `Name (conflict 2026-10-12 laptop).md`
— and synced too, so nothing lives only on one machine. Merge it into the
note and delete the copy; `sync status` lists the ones left.

**Deletes.** Deleting a file archives its page (restore it from the wiki's
archive); it is never purged. A page archived on the server is removed from
the folder, unless you had edited it there, in which case your edit goes
back up as a new page. A folder made on the server is made in the folder,
empty or not, and one deleted on the server is removed from it once nothing
but empty folders is left inside — anything else in it (a dot file, a
note you have just written there) keeps it.

**What is left alone.** `.obsidian/`, `.trash/`, every other dot folder and
file, and the temporary and swap files editors write while saving. Add your
own in `.slipdockignore` at the folder's root, one gitignore-style pattern a
line (`*.pdf`, `Private/`, `drafts/*.md`).

**Watching.** `--watch` looks at the folder every second and sends a change
once the folder has been still for two seconds, so an editor that saves
through a temporary file has finished. It asks the server's change feed
every ten seconds (`--interval`), and passes anyway every ten minutes.
`sync service install` sets that up as a systemd user service on Linux, a
launchd agent on macOS or a logon task on Windows (`print` shows what it
would write; `uninstall` takes it away).

**One sync per folder.** It replaces Obsidian Sync rather than running
beside it. `sync` warns when Obsidian Sync, Dropbox, iCloud Drive,
OneDrive, Google Drive or Syncthing seems to be syncing the same folder:
two of them undo each other's changes and make conflicts out of nothing.

### Importing an Obsidian vault

An Obsidian vault you already have comes in once with `slipdock vault import`,
and then the same folder carries on as a synced mirror:

```sh
slipdock vault import ~/Obsidian --vault Brain --dry-run   # what would happen; nothing is written
slipdock vault import ~/Obsidian --vault Brain             # do it
slipdock sync init ~/Obsidian --vault Brain                # then keep it level, both ways
```

Each path goes where the vault's mappings send it (the longest prefix
wins), each note becomes a page and every other file — images, PDFs,
drawings, `.canvas` — a file at the same vault path. A note goes up byte for
byte: its front matter (key order, quoting and comments), tags, aliases and
links, an Excalidraw drawing's `.excalidraw.md`, and Meld's ciphertext,
which is never decrypted. What the import leaves out, it says: whatever
sync leaves alone (`.obsidian/`, `.trash/`, `.slipdockignore`), paths no
mapping covers, files over 250 MB, and paths the vault already has — the
same bytes count as already there, anything else is listed and left as it
is, never overwritten.

The dry run also reads every note's `[[links]]`, `![[embeds]]` and local
Markdown links, and lists those that would find nothing — by Obsidian's
rules, against the folder and what is already in the vault: a bare name
finds a note or file of that name anywhere, `Folder/Note` one whose path
ends that way, and an alias counts as a name. It lists what only an
Obsidian plugin draws (Dataview, Tasks, Templater, a Kanban board, a
Canvas), which comes across as the text it is. `--all` shows every line of
a long list, `--json` all of it.

The folder's files are not touched. The import remembers what each became in
`.slipdock/import.json`, so running it again sends only what is new.

**Then sync.** Stop Obsidian Sync (or whatever else syncs the folder) first,
then `slipdock sync init` the same folder. It adopts what the import sent
rather than sending it again: a note still as it was imported takes the
vault's copy of itself (the same note, perhaps with a `title` key the server
added), a note edited since goes up to the page it became, and one edited on
both sides is a conflict like any other. Nothing is archived or removed by
adopting: a file deleted since comes back down, and one whose page was
archived goes up again. Once a pass has come through without an error the
import record is spent and removed.

### Meeting recordings from Google Drive

A recorded meeting can be one page: the summary, a `## Recording`
section, and the transcript in a ```` ```vtt ```` block under
`## Transcript` (the format is below, in
[Meeting transcripts: what Slipdock expects](#meeting-transcripts-what-slipdock-expects)).
The recording stays on Google Drive and is never
copied here. The page names it in its front matter, as
`recording: gdrive:<path from My Drive>`.

A ```` ```vtt ```` block reads as the conversation, the same as a `.vtt`
file. With a recording, a bar sits under **Recording** and stays in view
as you scroll. It has play, ±10 s, a scrubber and 0.75×–2× speed. The line
being spoken is highlighted and kept in view; scroll away and it stops
following until you press **Follow**. Click a line to play from there. The
search box marks the lines that match (Enter steps through them). While
you're not typing, space plays and pauses, ← and → skip 10 seconds, and
[ and ] change the speed. Moments tagged while recording, written in the
summary as `Tags: #important (0:05) #action (12:40)`, show as chips inline
in the transcript where they were pressed, and the tags in that line become
links to them; click either to play from there.
The **▶ Play recording and transcript** link in
the page jumps to the bar and starts it. Nothing is fetched from Drive
until you press play.

To make it play:

1. **Connect Google Drive** on **Account → Settings** (read-only). The
   section is only there when the server has a Google client (see the
   README).
2. **Set the vault's recordings folder** on the vaults screen (e.g.
   `Meeting Recordings`), or `slipdock vault set Notes --recordings-folder
   "Meeting Recordings"`. The recordings are streamed through the vault
   owner's connection, for anyone who can read the page, and only files
   under that folder will play. `slipdock drive status` shows where you
   stand.

If a recording won't play, the bar says why: see
[Why it won't play](#why-it-wont-play) below.

#### Meeting transcripts: what Slipdock expects

This is the contract for whatever records and transcribes your meetings: a
recorder app, a script, a transcription service. Write a page like this and
it plays. Nothing here is specific to one tool.

**One Markdown page per meeting**, in this order:

1. The summary, written however you like. Moments tagged while recording go
   on one line, `Tags: #important (0:05) #action (12:40)` (each a `#tag` and
   `m:ss`, or `h:mm:ss` from an hour). Each shows as a chip in the
   transcript where it was pressed, and as a link to it in this line.
2. `## Recording`, holding the line `[▶ Play recording and transcript](#recording)`.
   Leave the whole section out when there is no audio.
3. `## Transcript`, holding the transcript.

**Front matter:**

````markdown
---
title: "Weekly sync: budget"
date: 2026-09-16T12:08:42+01:00
type: meeting
recording: "gdrive:Meeting Recordings/2026-09/2026-09-16 12.08.42 weekly-sync.m4a"
recording_drive_id: 1AbCdEf…   # optional
recording_duration: 3725.4     # optional, seconds
participants: [Me, Alice]      # optional
tags: [budget]                 # optional
---
````

- `title`, `date` (ISO 8601 with its UTC offset) and `type: meeting`.
- `recording: gdrive:<path>`, the audio's path **from the root of My
  Drive**. If your uploader's "root" is really a subfolder (an rclone remote
  with `root_folder_id`, say), put that folder's path in front.
- `recording_drive_id` (the Drive file id) is only an optimisation: without
  it Slipdock finds the file by its path. Add it once the upload has landed.
- Don't write `code`, `slug`, `status` or `updated`: Slipdock owns them.
- Quote any value that YAML would misread, such as a title with `:` or `#`.

**The transcript** is the whole WebVTT file inside a fenced code block
whose info string is `vtt`:

````markdown
## Transcript

```vtt
WEBVTT

NOTE
Transcribed automatically

1
00:00:01.500 --> 00:00:03.250
<v Alice>Shall we start?

2
00:00:04.000 --> 00:00:06.000
<v Bob>Yes.
```
````

- Every cue needs its timing line (`start --> end`, `hh:mm:ss.mmm` or
  `mm:ss.mmm`). The cue numbers are optional.
- Speakers are `<v Name>` voice tags; a `Name: ` at the start of the text
  works too. Cues in a row from one speaker read as one turn, and each
  speaker keeps a colour. Without either, the lines are shown untitled, in
  time order, and still play and highlight.
- `NOTE` blocks are skipped. A transcript with no cue that has words shows
  "No speech detected." when it says `NOTE No speech detected.`, and "No
  transcript." otherwise.
- Text in cues is shown as text, never HTML (`&amp;` and the like are
  decoded).
- If any line of the VTT starts with three backticks, fence the block with
  four (or more), so it can't close early.

**The audio** stays on Google Drive and is never uploaded to Slipdock, which
streams it from Drive when someone presses play. It has to be audio
(`audio/*`; an `.m4a` that Drive labels `video/mp4` is fine too) and inside
the vault's recordings folder. Write MP4s with their index at the front
("faststart", `moov` before `mdat`; `ffmpeg -movflags +faststart`), so
playback starts and seeks without fetching the end of the file first.

**How the page gets in**, either way:

- **Through the vault's folder.** Write the `.md` file into a local folder
  that `slipdock sync` keeps level with the vault (see
  [Syncing a vault to a folder](#syncing-a-vault-to-a-folder)). It arrives
  like any other note.
- **Over the API**, with a write token:
  `PUT /api/vaults/<vault>/sync/pages` with `{"path": "Meetings/2026-09-16
  weekly-sync.md", "content": "<the whole file>"}`. The answer has the page's
  `id` and `hash`. To add `recording_drive_id` later, `PUT
  /api/vaults/<vault>/sync/pages/<id>` with the new content and `"base":
  "<hash>"`. A `409` means the page changed meanwhile, and carries it as it
  now stands: add your front-matter key to *that* content and send it again,
  rather than overwriting it. Keep sends that failed in an outbox and retry
  them later.

**Old-style notes**, with a separate `.vtt` file or a play link of the
recorder's own, are left exactly as they are, and don't get the player.

#### Why it won't play

The bar names the problem:

| It says | Fix |
| --- | --- |
| Google Drive isn't set up on this server (`not_configured`) | The admin sets `GOOGLE_CLIENT_ID`/`SECRET` (README, *Google Drive*). |
| Google Drive isn't connected (`not_connected`) | The vault owner connects Drive on **Account → Settings**. |
| Drive access was revoked (`revoked`) | Connect again on **Account → Settings** (weekly, in Google's Testing mode). |
| No recordings folder set (`no_folder`) | The vault owner sets it on the vaults screen, or `slipdock vault set V --recordings-folder PATH`. |
| This page isn't in a vault (`no_vault`) | Map the page's board into a vault. |
| Not in the vault's recordings folder (`outside_folder`) | Move the file under that folder, or fix the `recording:` path (from the root of My Drive). |
| That file isn't audio (`not_audio`) | Point `recording:` at the audio, not a video or document. |
| Recording not found on Drive (`not_found`) | The path or `recording_drive_id` is wrong, or the upload hasn't landed yet. |

### Encrypted notes

A note can hold an encrypted passage, written in the format of
[Meld Encrypt](https://github.com/meld-cp/obsidian-encrypt), the Obsidian
plugin. The vault's Obsidian opens Slipdock's, and Slipdock opens Meld's
(every version Meld has written). Encrypting and decrypting happen in your
browser or on your machine, and the passphrase and the plain text never
reach the server.

- **Reading.** An encrypted passage shows as a locked chip with its hint.
  Select it and enter the passphrase, and the text appears in place. It
  locks again after five minutes, when you press *Lock*, or when you leave
  the page or reload. *Remember for this session* keeps the passphrase in
  the tab's memory, so the next passage opens without asking. Nothing
  decrypted can be turned into a card. A whole encrypted note (`.mdenc`)
  opens the same way from the tree.
- **Writing.** In the editor, *Encrypt* with nothing selected opens a box
  where you type the secret, the passphrase twice and an optional hint.
  Only the encrypted block goes into the page, so the secret is never saved
  or sent. With text selected, *Encrypt* encrypts the selection, and
  *Encrypt whole note* does the whole body as one block. *Decrypt to edit*
  opens the block under the cursor so you can change it, and saves it
  encrypted again with the same passphrase. *Remove encryption* puts the
  plain text back, after asking.
- **History.** Text that was on the page before you encrypted it is still in
  the page's earlier revisions, and the editor says how many. The board's
  owner can choose *Purge them when I save*. Only those revisions are
  deleted, the page as saved is kept, and the purge is written in the
  board's activity. It is the one exception to "nothing is lost to a save".
- **Search** never sees the ciphertext. Listings show 🔒 in its place, and
  the tree marks a page holding some with a lock.
- **CLI.** `slipdock page encrypt <page> [--section S] [--hint H]
  [--purge-history]` and `slipdock page decrypt <page> [--section S]
  [--in-place]` do the same on your machine. They ask for the passphrase, or
  read it from `--passphrase-file` or `$SLIPDOCK_MELD_PASSPHRASE`.

### Drawings

Drawings made with Obsidian's [Excalidraw](https://github.com/zsviczian/obsidian-excalidraw-plugin)
plugin are drawn in the page. Both of its files work: a `.excalidraw.md` note
(compressed or not), which is a page, and a plain `.excalidraw` file, which
is kept with the wiki's other files.

- **Viewing.** `![[Plan.excalidraw]]` or `![[Plan.excalidraw.md]]` shows a
  preview of the drawing where it is written; select it to open the drawing.
  A drawing's own page shows the drawing rather than the plugin's Markdown.
  The preview is drawn by the server with clean lines rather than
  Excalidraw's hand-drawn ones, in the fonts your computer has, and a
  dark-theme drawing is shown dark. Images the drawing holds are drawn too.
- **Editing.** *Edit drawing* on a drawing's page (or selecting a `.excalidraw`
  file in the tree) opens it in Excalidraw itself, the same editor as the
  plugin's. There is no Save button: the drawing saves itself a couple of
  seconds after you stop, and the corner says *Saving…*, *Saved* or
  *Reconnecting…*. Ctrl+S saves at once. The drawing is saved in the format
  it came in — a compressed note stays compressed, its text list is brought
  up to date, and anything else in the note is kept — so the plugin goes on
  opening it. People who can only read the board can open a drawing to look
  round, but not change it. *Edit Markdown* is still there for fixing the
  note by hand.
- **Drawing together.** When two people (or two of your tabs) have the same
  drawing open, each sees what the other draws as it is drawn — whether they
  reached it through the board or through a share. The header shows who is
  there, each in a colour of their own (faded, and marked *viewing*, for
  someone who can only look), and their pointers and selections move on the
  canvas, named, in that colour. Pointers are never saved. Each shape is merged the
  way Excalidraw's own collaboration merges it: if two people change the same
  shape at once, the later change to it wins; nothing else either of them
  drew is lost. A burst of drawing is one entry in the page's history, put
  down to whoever drew last and naming everybody who drew in it. If the
  connection drops, the editor says so, and sends everything it has when it
  is back. A change that arrives another way while the drawing is open — a
  vault sync from Obsidian, an agent or the API — is merged in the same way
  and shows up in the editor; if it isn't a drawing at all, the editor warns
  you, the change is kept in the page's history, and your next stroke saves
  the drawing back.
- **Search.** A drawing note is found by the words in it: its text, and any
  prose written above the drawing. Its listing shows them too. (A plain
  `.excalidraw` file is not searched; files in the wiki aren't yet.)
- **New drawing.** *New drawing* in a folder's menu in the tree makes an
  empty drawing there, named the way the plugin names one, and opens it in
  the editor.

## Moving boards between servers

A board as one JSON file that another Slipdock can read back: its lists, its
cards and their subcards, tags, checklists, comments, status updates, web
links, custom fields and the values cards hold in them, what waits on what,
typed links, and the wiki. **Account → Import & export** has a
picker and a download link; `slipdock export [<board>...] --out boards.json`
and `slipdock import boards.json` do the same from a shell, and
`GET /api/export` / `POST /api/import` are the contract under both.

This is not the wiki's Markdown export above. That one is for reading your
writing somewhere else; this one is for moving a board, and only this one can
be read back into a board. Nor is it `/account/export.zip`, which answers "let
me leave with my data" and is written for a person rather than for a machine.

Three things are worth knowing before you use it.

**It only ever carries boards you own.** A board shared with you is somebody
else's to hand on, and an export that quietly swept it up would be a way to
take a copy of their work off the server.

**An import never merges.** A document always becomes *new* boards, even when
a board of that name is already there. Merging means deciding, per card,
whether "the same card" means the same title — and getting that wrong quietly
destroys work, where a second copy is obvious and can be deleted. A board code
that is taken is reissued (`del` becomes `del-2`) and the answer says so. So
importing the same file twice gives you two copies, by design.

**Automation rules do not fire on an import.** Four hundred cards arriving
would otherwise run every rule on the board four hundred times and email
somebody about each. Rules are about what happens here; an import is history
arriving.

The limits, where a server has them, are answered once for the whole document
before anything is built: the cards and pages it would add, and the boards. A
file that will not fit is refused outright rather than stopping half way and
leaving a part-built board, and so is one that arrives after a free trial has
ended.

### What does not travel, and why

| Left out | Because |
|---|---|
| Attachments | Bytes rather than structure; they stay on the server they were uploaded to |
| Votes | A person's budget spent, which does not mean the same thing elsewhere |
| Wiki page history, activity | A record of one server's past, which another cannot honestly adopt |
| Public share tokens | A secret that would otherwise be valid in two places |

The export says how much of each it left behind — and says nothing when there
was nothing, so a board with no attachments does not warn about attachments.

Two things cannot survive verbatim and are handled rather than ignored. A
page's code (`W-31`) is unique across a whole server, because `[[W-31]]`
resolves with no board behind it, so imported pages are given fresh codes —
and then `[[W-31]]` inside the imported bodies is rewritten to the code that
page now has, so a wiki that comes out still links to itself. A board's
shortcut key is server-wide in the same way, so the importing person picks
their own.

One thing genuinely does not survive: `#412` typed inside a **page body**
points at a card id on the server the file came from, and there is nothing in
the document to match it against. Card-to-card links and dependencies are
preserved — those travel as references within the file — but a card id written
into prose is not.

People travel as email addresses, because a user id from another server names
nobody. An address with no account on the receiving server lands unassigned
and is named in the report, rather than failing the import on the last card
because somebody left.

### From Trello

The same upload, `slipdock import` and `POST /api/import` also read a Trello
board: in Trello, **Menu → Print, export and share → Export as JSON**, and hand
that file in as it is. It is recognised by its shape; `?from=trello` (or
`slipdock import board.json --from trello`) says so outright, and the answer
carries `"source": "trello"`. Everything above still holds — a new board every
time, rules not firing, the limit answered for the whole file first.

| Trello | Here |
|---|---|
| Open lists, in order | Lists — one called *Done*, *Doing*, *To Do* and the like gets that category |
| Cards, archived ones too | Cards, archived ones archived; *due complete*, or being in a done list, is completed |
| Labels | Tags — an unnamed label is named after its colour, and labels sharing a name become one tag |
| Checklists | The card's checklist; several are laid end to end, each item prefixed with its checklist's name |
| Comments | Comments, oldest first, each opening with who wrote it on Trello and the date |
| Attachments | Web links |
| Due and start dates | Due and start dates |

What stays behind, and the answer says so when it applies: **members**,
because Trello's export carries no email addresses to match anybody with, so
cards come in unassigned; **archived lists** and the cards on them, since a
list cannot be put away here and dropping its cards into an open one would
bring back finished work; and **custom fields**. Files uploaded to Trello come
in as links that need a Trello login to open. Trello's own export holds only
the most recent thousand actions, so an old, busy board's oldest comments never
reach the file.

Other tools are meant to follow the same way: each is a small reader that
turns its export into this document (`Slipdock.Importers`), so the rules above
apply to every one of them.

## Accounts and sharing

Every page needs a signed-in user. The login page asks for an email address and
sends a one-time link **and a six-digit code**, either of which works, once,
within 15 minutes; using one signs you in for 30 days on that browser. The code
exists for the times the link cannot be clicked — read out of a log, typed from
a phone.

**Passkeys.** Once signed in, add a passkey under **Account → Passkeys** (or, when
finishing an email sign-in, press **Sign in and set up a passkey** under the
**Sign in** button to land straight there): name
it, press **Add a passkey**, and unlock the device the browser asks for (a
fingerprint, a face, a PIN, a security key). From then on the login page has a
**Sign in with a passkey** button that needs no email: the device offers the
accounts it holds for this server and signing in takes a touch. The email link
and code keep working; a passkey is another way in, not a replacement.

- A passkey belongs to the address the browser was on when it was made. One
  made at `https://slipdock.example.com` does not work at a tailnet IP, and
  browsers only offer passkeys over https (or on `localhost`).
- The device has to verify you (not just be present), so a passkey stands in
  for the email *and* the code.
- Up to 20 per account. Each lists when it was added and last used; **Remove**
  stops it signing in at once. A lost phone can also be removed from a
  terminal: `slipdock passkeys`, then `slipdock passkeys remove <id>`, or
  `GET` / `DELETE /api/me/passkeys[/:id]`.
- A disabled account cannot sign in with a passkey either. A security key
  whose signature counter goes backwards (a copied key) is refused.

Every board has an owner, fixed when it is made: the board settings form and
`PATCH /api/boards/:board` cannot change it, and a board somehow left with no
owner is open to nobody rather than to everybody. Ownership moves only when an
account is deleted and its boards are handed over.

**Your own four pages**, under the avatar menu's **Account & settings** and tabbed across the top of
each other, because one long scroll had the display name, the AI key and a
board importer on it and nothing told you which was which:

- **Account** (`/account`) — your display name, how many cards you have used
  against the limit if there is one, every time an admin has been let into
  your boards and why, your passkeys, signing out, and the licence.
- **Settings** (`/account/settings`) — the dials: where quick add puts a card,
  whether the line is read by a model, and your OpenRouter key.
- **API tokens** (`/account/tokens`) — make, inspect and revoke the tokens the
  CLI and agents sign in with.
- **Import & export** (`/account/data`) — everything you have as a zip, and
  boards as files another Slipdock can read back.

**Setting the server up.** A server nobody has claimed shows a setup wizard and
sends every other page to it. It asks who may register, how mail goes out and
who the admin is, and it wants a token printed in the log on first boot — so
that finding the page first is not enough to claim somebody else's instance.
Finishing it closes the page for good. `SLIPDOCK_ADMIN_EMAIL`, or
`mix slipdock.setup --admin you@example.com`, does the same thing without a
browser.

**Who may get an account** is then one of four modes, under **Admin**:

- **Nobody can register** (the default) — accounts exist only because you made
  them by sharing something.
- **Only addresses I list** — an allowlist of addresses and of domains. A bare
  domain lets anybody there in, which is how you admit a team.
- **I approve each request** — people ask on the sign-in page and you say yes or
  no. Needs a working mail server, and Slipdock refuses the mode without one,
  because otherwise nobody is ever told that somebody is waiting.
- **Anyone can register** — only sensible when the server is already behind a
  boundary of your own (Tailscale, a VPN, an authenticating proxy).

Changing the mode never removes anybody: people who already have an account keep
it.

**Running it for other people.** A few more settings make a shared server
defensible. An **item limit** caps how much one person's own boards may hold —
a card, a wiki page and an uploaded file each count as one item, so writing the
work up as pages is not a way round it; things on boards shared *with* them cost
them nothing, and archiving a card or a page frees one up. A **free trial** can
be switched on: free accounts stop being able to add anything so many days after
they were made, which is independent of the item limit, so an account can have
no item limit at all and still run out of trial. Neither deletes anything or
locks anybody out — what ends is adding. **Who people can see** can be narrowed
from everyone on the server to only the people somebody actually shares a board,
card or page with, which also keeps other customers' addresses out of anything
sent to a language model. And **whether sharing with a stranger makes them an
account** can be turned off, so you can only share with people who already have
one.

**The ceilings.** Separately, every install has three of them on, however it is
run: 1,000 boards one person may own, 250,000 items on those boards, and 10 GB of
uploaded files. They are a safety rail rather than a price list — a runaway
script should hit something — so **admins are not exempt either**, and an admin
who means to go past one raises it. Each has its own switch, so any of them can
be turned off without losing the number behind it. Where a free account's own
allowance is lower than a ceiling, the lower one wins.

**Who has paid.** There is no billing in Slipdock. What takes somebody off the
free allowance and off the trial clock is a **paid-up date**, set per person
under Users (or `slipdock admin paid <email> <date>`) by whoever took the money.
An account with no date in the future is a free one — unless an admin has marked
it **unlimited** (Users → *Make unlimited*, or `slipdock admin unlimited <email> on`),
which does the same for a named person with no date to invent: no free allowance,
no trial. The ceilings above still apply to them, as they do to admins.

**Looking at somebody's boards to help them.** Being an admin does not let you
read other people's boards. **Support**, on a person's row under Users, does —
read only, for four hours, and only with a reason, which they are emailed and
which stays on their Account page for good. Their boards are not added to your
own list; while the session lasts they are listed, as links, under **Support
access in force** on Users and in a **Supporting** *name* panel at the top of
your Boards page, where **End now** finishes it early. Sub-boards open from
their parent cards as usual. Demoting or disabling the admin ends it too.

**What it is being used for.** **Overview**, in the avatar menu's **Admin** group, puts
the whole server on one page: how many accounts (admins, disabled, never seen),
how many joined and how many were active in the last 7 and 30 days, and the
boards, lists, cards, wiki pages, files and storage across all of them. Below
that is a row per person — when they signed up, when they were last active, and
what they own — sortable by any column (`?sort=storage`, `cards`, `last_active`,
`signed_up`, `email` and the rest). Things are counted against the **owner** of
the board they are on, sub-boards included, exactly as the limits count them,
so a guest working on your board adds nothing to their own row. *Last active*
is the later of the last browser sign-in and the last use of one of their API
tokens, so an account worked only by an agent still shows as active. It is
read-only; changing anybody's standing is on Users. From a terminal:
`slipdock admin overview [--sort cards]`, or `GET /api/admin/overview` with an
admin-scoped token.

**Admins.** One role, and the oldest account has it after an upgrade. Admins
change all of the above, see everybody, grant and remove admin rights, disable
accounts, set per-person item limits and record who has paid. On Users they can
also **add somebody** by address (they are emailed an invitation when there is
mail, whatever *invites create accounts* says), **change the address** somebody
signs in with (the pencil beside it; the old address is told, and a sign-in link
already sent there stops working), and **close an account** for good, after it
has said what it will take with it and the address has been typed to confirm.
Disable first: it is reversible and immediate, and closing takes their cards and
the boards only they used with it. From a terminal: `slipdock admin add <email>`,
`slipdock admin email <email> <new-email>`, `slipdock admin close <email> --force`
(`POST`, `PATCH` and `DELETE /api/admin/users`, the last with `?confirm=<email>`).
Three things are deliberately refused: mail settings will not save without a
test message that arrived, the last admin cannot be demoted, disabled or closed,
and the admin address only changes once the new address confirms a code.

**When there is no mail server**, sign-in codes are written to a file on the
server (`SLIPDOCK_LOGIN_FALLBACK_PATH`, mode `0600`) and to the log, so a fresh
install can be used at all. Anyone who can read either can sign in as anybody,
so it switches itself off once mail works, and `SLIPDOCK_LOGIN_FALLBACK=false`
forbids it in a way the application cannot undo. Set that on anything other
people can reach.

A refused address is told exactly what an accepted one is told — "if that
address can sign in here, a link is on its way" — and in the same time, because
the email is sent in the background, so the page cannot be used to find out who
has an account. Asking for links is rate limited (five an hour per address,
twenty per IP; `config :slipdock, :rate_limit, enabled: false` turns that off),
so nobody can use this server to mail strangers. Typing a code counts
separately, per IP and address, so somebody flooding your address with link
requests cannot also stop you entering the code you were sent. All of these
count in memory on this node and are forgotten on restart.

"Per IP" means the visitor's address. Behind a reverse proxy that comes from
`X-Forwarded-For`, believed only from a trusted proxy — loopback and the private
ranges by default, or the CIDRs in `SLIPDOCK_TRUSTED_PROXIES` (`none` trusts
nobody). A proxy connecting from a public address has to be listed there, or
every visitor shares its address and its limit.

Browser responses carry a Content-Security-Policy that allows script from this
origin only — see `SlipdockWeb.Plugs.ContentSecurityPolicy`, which explains each
directive and how to replace the header (`config :slipdock, :csp`) if your proxy
sets its own.

Mail goes out over SMTP when `SLIPDOCK_SMTP_HOST` (plus optional
`SLIPDOCK_SMTP_PORT`, `SLIPDOCK_SMTP_USER`, `SLIPDOCK_SMTP_PASSWORD`,
`SLIPDOCK_MAIL_FROM`) is set. Without it, sent mail stays in an in-memory
mailbox at `/dev/mailbox`, and while the sign-in fallback is on (the default
until mail is configured) the code and link are written to
`log/sign-in-links.log` and the server log
(`journalctl -u slipdock | grep "Sign-in code"`). Turn the fallback off and
they are written nowhere; once mail works, sign-in links and codes never reach
the log at all.

### Signing an agent in

An agent cannot read your email, so it cannot follow a magic link. It gets a
token instead, and there are two ways to give it one. ([Setting up an
agent](agents.md) is the whole job end to end; this is the credential half of
it.)

**The device flow** (`slipdock auth`, with no token) is the way to do it from
anywhere — a laptop, a sandbox, a container, any machine that is not this
server:

```sh
$ slipdock auth
  Open  https://slipdock.example/activate
  Enter WDJB-MJHT

  Signing in as "slipdock CLI on laptop". Waiting — Ctrl-C to stop.
```

You open `/activate` in a browser where you are already signed in, type the
code, and see what is being asked for — what called itself what, what it would
be allowed to do, where it asked from, and when. Approve it and the agent is
holding a token a few seconds later; refuse it and the agent is told so rather
than left waiting. The code lasts ten minutes and works once.

`--scope read` asks for a token that cannot change anything, and `--label`
names the client on the approval screen. Under the covers this is
[RFC 8628](https://datatracker.ietf.org/doc/html/rfc8628): `POST
/api/auth/device` starts it, `POST /api/auth/device/token` is polled until a
person decides. Neither needs a token, because they are how you get one.

> Approving gives whatever asked a token that acts as you until you revoke it.
> If you did not just start it yourself, refuse it — a code somebody else sends
> you is somebody else asking for access to your account.

**A token you make yourself** suits anything with no human to approve it —
CI, cron, a scheduled job. Create one under **Account → API tokens**, give it
a scope and an expiry, and put it in the secret store. This is the right
answer there: no interactive flow helps a machine that nobody is watching.

**API tokens** carry a scope (read-only or read/write, optionally confined to
named boards) and an optional expiry, and Account › *API tokens* shows when each was
last used and from where. A read-only token is refused any request that would
change something, and a board-scoped one cannot see — or even list — boards
outside its scope. Revoke one and it stops working at once.

### Agentic Login (for automated testing)

> **Not the way to sign an agent in.** Use the device flow above. This exists
> for an agent running *on the server itself*, and it is an authentication
> bypass by design.


Receiving an email is awkward for an automated agent driving the app, so the
sign-in page can also offer an **Agentic Login** button. Enter an email address
and press it instead of "Email me a sign-in link": the server mints the same
one-time link but writes it to a fresh, randomly named file
(`slipdock-agentic-login/slipdock-agentic-login-<random>.txt` under the system temp dir by default, readable only by the account running the server) and shows that filename
on the page. An agent with shell access to the server then reads the file and
opens the link it contains in its browser, then presses **Sign in**. Opening any
sign-in link only shows that button — signing in is the POST it makes, so a mail
scanner that prefetches links cannot use one up. The link works once and expires
in 15 minutes, as usual; the file is left behind for the agent to delete.

It is on in `dev` and `test`. In production it is off unless the server runs
with `SLIPDOCK_AGENTIC_LOGIN=true` (and optionally `SLIPDOCK_AGENTIC_LOGIN_DIR`
to change the directory). Anyone who can reach the sign-in page can create these
files, so only enable it on machines used for automated testing.

**Groups** (`/groups`) are named sets of people you can share with at once.
Members are added by email; the group's creator manages it.

**Sharing** — a board belongs to the user who created it. From the board's
settings the owner can grant *read only*, *can comment* or *can edit* access
to a person or a group; board access covers every card on it and the
sub-boards inside them. **Can comment** (#863) is a reader who may also join
the discussion: comment, post a status update and vote, and take back their
own comments — but not change the card's title, dates, assignees, flags, list,
checklist or anything else. A commenter's card modal keeps the comment box,
status updates and votes live and the rest disabled. A single card can be shared the same way from its modal (by the owner
or anyone who can edit it): the recipient sees that card, listed under
"Cards shared with you" on the home page, and nothing else on the board. A
card grant can also raise a board reader to a commenter or an editor on that
one card. A
saved view can be shared from the Views menu: the recipient opens the board
only through that view, sees just the cards it selects, and can edit them
only if the view grant is "can edit". Readers get a disabled card modal, no
drag and drop, and no add buttons; the server refuses their writes too.

A board somebody shared with you sits on your board list beside your own, and
says **shared by** whoever owns it — on the cards and in the table, and in the
tooltip in full. The API says the same thing in data: every board response
carries `owner` (`id`, `email`, `name`), and a listing marks each board
`shared` when its owner is somebody other than you. `slipdock boards` grows an
OWNER column when any of them are, and `slipdock board <ref>` names the owner
on its own line.

**Giving a share back.** The *…* menu on a board somebody shared with you has
a **Shared** item (`/boards/:id/shared`). The page it opens says who the board
belongs to, who handed it over, when, and on what terms — the board itself, or
a saved view onto it — and carries a **Discard** button. Discarding takes away
the grants that name *you*: the board leaves your list, your switcher and your
search, and nothing on the board changes, so the owner can share it again.
Access that came through a **group** is not yours to give up, so the button is
disabled and the page says what would end it (leaving the group, or the owner
revoking the group's access). Owners have no use for the page and are sent to
their board's settings, which is where sharing out lives.

A **wiki page** can be shared on its own too, and a page grant behaves like a
card grant: the recipient reads (or edits) that page without the board coming
with it. A view grant is the exception that goes the other way — it reaches
cards through the view and never reaches pages at all.

**API tokens** are created under Account, or by the device flow above; the
CLI stores one with `slipdock auth <token>` or gets its own with `slipdock
auth`. See [Signing an agent in](#signing-an-agent-in).

## Roadmap features in the API and CLI

Boards carry `fields`, `milestones` and `votes` (the budget); columns carry
`category` and `horizon`; cards carry `date_precision`, `stated_health`,
`status_updates`, `fields` (stored values by key), `scores` (formula
results by key), `votes` and `links`. Set fields with
`PATCH /api/cards/:id {"fields": {"reach": 100, "size": "Large"}}`.
Endpoints: `/api/boards/:board/fields` (GET, POST; PATCH and DELETE with
`/:id`), `/api/boards/:board/presets/:key` (POST), `/api/boards/:board/milestones`
(GET, POST; DELETE with `/:id`), `/api/cards/:id/vote` (POST `count`),
`/api/cards/:id/status` (POST `health`, `body`), `/api/cards/:id/links`
(POST `to`, `kind`; DELETE with `/:link_id`), `/api/cards/:id/urls`
(POST `url`, `title`; DELETE with `/:url_id`).

CLI: `slipdock fields <board>`, `new-field`, `delete-field`, `preset <board>
rice|ice|value_effort`, `set <id> key=value…`, `vote <id> <n>`, `status <id>
on_track|at_risk|off_track [note]`, `link <id> <kind> <card-id>…`, `unlink`,
`weblink <id> <url> [--label TEXT]`, `unweblink <id> <url-id>…`,
`attach <id> <file>… [--name N]`, `attachments <id>`, `download <attachment-id> [--out F]`,
`detach <id> <attachment-id>…`,
`milestones <board>`, `milestone <board> <name> --date D`,
`delete-milestone`. Sorting accepts `votes` and `f:<field id>`.

## Running

### With Docker

Nothing but Docker needed — no Elixir, no Node, no database server, and nothing
to compile: the image is published to `ghcr.io/dadamsuk/slipdock`.
[The README](../README.md#with-docker) has the step-by-step version, including
backups and what to do when something is wrong.

```sh
docker compose up -d
docker compose logs -f          # the setup token and sign-in codes are in here
```

Open <http://localhost:4000>. A server nobody has claimed shows a **setup
wizard**, which asks for a token printed in the log on first boot — so that
finding the page first is not enough to claim somebody else's server. It asks
who may register, how mail goes out and who the admin is, then disappears for
good. `SLIPDOCK_ADMIN_EMAIL` skips it entirely.

Everything that must survive an upgrade is on two volumes: `slipdock-db` is
the Postgres database, and `slipdock-data` holds uploaded files, each person's
OpenRouter key, and a `SECRET_KEY_BASE` the container generates for itself on
first run. Those volumes are the thing to back up — the database with
`pg_dump`, which is consistent and restorable into a later Postgres.

Settings go in a `.env` beside `compose.yaml` — copy `.env.example`, which lists
every variable with its default. The ones that matter first:

```sh
PHX_HOST=slipdock.example.com     # the address people use; sign-in links are built from it
SLIPDOCK_PUBLISH=4000             # every address; unset, 127.0.0.1:4000 only
SLIPDOCK_ADMIN_EMAIL=you@example.com               # skips the setup wizard
SLIPDOCK_SMTP_HOST=smtp.example.com               # so codes are emailed rather than logged
```

Behind a TLS proxy, set `SLIPDOCK_URL_SCHEME=https` and `SLIPDOCK_URL_PORT=443` so
the links the app builds point at the proxy. If people reach the server by more
than one name, list the others in `SLIPDOCK_CHECK_ORIGIN` or live updates will be
refused for the names you did not mention.

A release has no `mix`, so the two administrative tasks are on the entrypoint:

```sh
docker compose run --rm slipdock setup --status              # what this server allows
docker compose run --rm slipdock setup --admin you@example.com
docker compose run --rm slipdock setup --sign-in-link you@example.com
docker compose run --rm slipdock setup --make-admin you@example.com   # no admin can get in
docker compose run --rm slipdock ai-key                      # who has an OpenRouter key
docker compose run --rm slipdock ai-key you@example.com sk-or-…
docker compose run --rm slipdock welcome you@example.com     # the Getting Started tour board
docker compose run --rm slipdock reindex                     # rebuild the search index
docker compose run --rm slipdock migrate                     # migrations, by hand
docker compose run --rm slipdock remote                      # an IEx shell in the app
```

`docker run` on its own works too
(`docker run -p 4000:4000 -v slipdock-data:/data ghcr.io/dadamsuk/slipdock`).
The image does not force HTTPS, on the assumption that something in front of it
terminates TLS; build with `--build-arg SLIPDOCK_FORCE_SSL=true` if the app
itself should.

### From a checkout

```sh
mix setup          # deps, database, seeds, assets
mix phx.server     # http://<tailscale-ip>:4000
```

In development the server binds to this machine's Tailscale IPv4 (found via
`tailscale ip -4`). Override with `SLIPDOCK_BIND_IP=0.0.0.0` (all interfaces) or
`SLIPDOCK_BIND_IP=127.0.0.1` (loopback), and `PORT` to change the port.

The AI features run on **each person's own key, or their own endpoint**, set
under **Account → Settings → AI model** in the web UI (`slipdock ai-key <key>`
and `slipdock ai-endpoint <url>` from the CLI, `mix slipdock.ai_key <email>
<key>` on the server). Both are kept in one JSON file, `ai_keys.json` in the
app's directory, `0600`, outside the database — `SLIPDOCK_AI_KEY_FILE` moves
it, and it holds secrets in the clear, so back it up like a `.env`. Somebody
with neither gets no AI features: the chat drawer, the narrative generator and
the rest stay hidden, and `/api/ask` says what is missing.

### A local model instead

Everything here speaks the OpenAI-compatible `/chat/completions` API, which is
what OpenRouter speaks and so does every local model server — **LM Studio**,
**Ollama**, **llama.cpp**'s server, **vLLM** — as well as most company
gateways. Point *Account → Settings → AI model* at one:

| Field | What it is |
| --- | --- |
| Endpoint | The API root, the part before `/chat/completions`: `http://llm.local:1234/v1` (LM Studio), `http://llm.local:11434/v1` (Ollama). A trailing slash, or a pasted `/chat/completions`, is trimmed for you. Empty means this server's default |
| API key | Optional. Most local servers want none, and none is sent if you leave it empty. The server's shared OpenRouter key is **never** sent to an endpoint of yours |
| Model | *List models* asks the endpoint what it has (its `/models`, the same list `slipdock ai-models` prints) and offers them in a picker. Save the endpoint first — the list comes from what is stored |
| Embedding model | Only if the endpoint serves one, and only read for the account that indexes (Configuration → AI for search and automations). Changing it invalidates every stored vector: reindex (`docker compose run --rm slipdock reindex`, or `mix slipdock.reindex --force` from a checkout) |

An endpoint of your own is enough on its own — with one set, the AI features
turn on whether or not you have a key, because a box on your own network has
nothing to bill. A model id matters, though: an OpenRouter id (`google/…`)
means nothing to a local server and the other way round, which is what the
picker is for. A server running several models at once will say so rather than
guess, if you have picked none.

To make a whole instance local, set `SLIPDOCK_AI_BASE_URL` (and
`SLIPDOCK_AI_MODEL`) instead: everybody who has not chosen for themselves then
uses it, no keys anywhere, and no board content leaves the network.

Unattended work — the search indexer, every search query, scheduled
automations — has no person to bill, so it uses a *system* key: one admin's
AI settings. Choose whose under **Configuration → AI for search and
automations** (or `slipdock admin set ai_system_user=<email>`; empty clears
it). The page says what is in effect now and why. Only admins can be chosen,
and someone demoted or disabled since stops being used at once.

With nobody chosen, the older rules decide, in order:
`SLIPDOCK_AI_SYSTEM_USER=<email>` names whose key to spend; and on a
one-person install — registration closed, and the only stored settings an
enabled admin's — those are used without being asked for. That last one
switches itself off the moment registration opens or a second person saves
a key, which is the usual reason search suddenly says it isn't set up.
Nothing else is guessed: the indexer sends every board through the system
settings, so one person's own endpoint never receives them unless an admin
named that person. `OPENROUTER_API_KEY` still works and beats all of these,
but it is now a **shared** key for everyone on the server, which is rarely
what you want.

Other settings come from the environment or a `.env` file (`KEY=value` lines)
in the project directory or its parent — `SLIPDOCK_ENV_FILE` names another
location, and the systemd unit reads the same file. **`.env.example` lists every
variable the app reads, with its default**, so an empty `.env` is already a
working configuration and nothing in the repo assumes a particular machine.
`SLIPDOCK_AI_BASE_URL` moves the default endpoint for everyone (default
`https://openrouter.ai/api/v1`; a local endpoint needs no key, so this is how
an instance becomes local-first). `SLIPDOCK_AI_MODEL` picks another model
(default `google/gemini-2.5-flash-lite`, chosen for price — change it with the
endpoint, since the ids do not carry over) and `SLIPDOCK_AI_QUICK_MODEL`
one for the header's quick add alone, where latency matters more than depth
(it falls back to `SLIPDOCK_AI_MODEL`). `SLIPDOCK_AI_ORGANISE_MODEL` is the
one a folder's **Organise… → AI suggestions** asks (default
`anthropic/claude-haiku-5.5`; with `SLIPDOCK_AI_BASE_URL` set and this unset,
it falls back to the quick model). `SLIPDOCK_AI_EMBED_MODEL` and
`SLIPDOCK_AI_EMBED_DIMENSIONS` pick the embedding model behind deep search;
reindex after changing either (`docker compose run --rm slipdock reindex` on a
release, `mix slipdock.reindex` from a checkout). Restart the server after
changing any of them.

Automation emails link back to the board; set `SLIPDOCK_BASE_URL` when the
address people use isn't the one the endpoint is configured with (behind a
proxy, say). Real mail needs `SLIPDOCK_SMTP_HOST` — without it, sent mail
stays in the in-memory mailbox at `/dev/mailbox`. The relay's TLS certificate
is verified against the system CA store and the relay's name; a relay with a
self-signed certificate needs `SLIPDOCK_SMTP_TLS_VERIFY=false`.

## As a service

`deploy/slipdock.service` is a systemd unit template that runs a production
release on boot. It is a template because a few lines are specific to your
machine and everything else is not — the file marks them: `User`/`Group`,
`WorkingDirectory`, the release path in `ExecStart`/`ExecStop`, and the
`EnvironmentFile` path.

```sh
cp .env.example .env            # DATABASE_URL, SECRET_KEY_BASE, PHX_HOST at least
chmod 600 .env
MIX_ENV=prod mix deps.get --only prod
MIX_ENV=prod mix assets.deploy
MIX_ENV=prod mix release --overwrite
sudo cp deploy/slipdock.service /etc/systemd/system/
sudoedit /etc/systemd/system/slipdock.service   # the lines it marks
sudo systemctl daemon-reload
sudo systemctl enable --now slipdock
journalctl -u slipdock -f
```

Rebuild the release and restart the unit to upgrade. It is deliberately not
`mix phx.server`: the development server has a mailbox at `/dev/mailbox` that
shows anybody who can reach it every sign-in link it has sent, Phoenix's debug
error pages, and a `secret_key_base` published in this repository. If you do
run the dev server where other people can reach it, `SLIPDOCK_DEV_TOOLS=false`
turns off the mailbox and the debug pages.

The release listens on every address over plain http. Put a TLS proxy in front
and keep the port itself off the internet. When the server's address is https
(`SLIPDOCK_URL_SCHEME`, https by default in production), the session cookie is
marked `Secure`.

Settings go in `.env`, not in the unit file, so the unit stays the same on every
machine and the thing that differs between them is one file you already have to
protect. Nothing to do with a particular account — mail relay, hostnames,
sign-up rules — belongs in the unit.

## Licence

Free software under the [GNU Affero General Public License v3](../LICENSE).
Copyright © 2026 David Adams.

The AGPL's point, and the reason it was chosen here: if you run a modified copy
as a network service, the people using it are entitled to your changes. The
Account page links to the source for exactly that reason — point
`SLIPDOCK_SOURCE_URL` at your own repository if you run a fork.

See [CONTRIBUTING.md](../CONTRIBUTING.md) to work on it and
[SECURITY.md](../SECURITY.md) to report a vulnerability.

## Data

Everything lives in Postgres — the `slipdock_dev` database on the server in
`compose.dev.yaml` unless `DATABASE_URL` says otherwise. `mix ecto.reset` wipes
it and re-runs
`priv/repo/seeds.exs`, which builds the demo workspace (`Slipdock.Demo`) on an
empty database: two boards, an epic with subcards, a scoring scheme, a wiki and
an automation, all on `example.com` addresses. `mix slipdock.demo` builds the
same thing on demand (`--force` to add it to a database that already has
boards), and `tools/screenshots.sh` is what photographs it for the README.

## JSON API

Everything the UI can do is available under `/api`. Every request needs an
API token (create one under Account) as `Authorization: Bearer <token>`;
`GET /api/me` shows who the token belongs to, whether their API key is on file
(`ai_key`), and which endpoint and model their AI requests use (`ai`).
`PUT /api/me/ai-key {"api_key": "sk-or-…"}` sets that key,
`DELETE /api/me/ai-key` removes it; the key itself is never read
back out, only its masked shape.
`PUT /api/me/ai-provider {"base_url": "http://llm.local:1234/v1", "model": "…"}`
points them at a model of their own (only the fields sent are changed, `""`
clears one), and `GET /api/me/ai-models` lists what that endpoint can run.

`GET /api/guide` is the exception: it needs no token and answers in Markdown
with the API's own instructions for an agent — the model, the convention that
top-level cards are epics holding their tasks as subcards, how to choose what
to do next (in progress before To Do before Backlog, depth first through an
epic's subcards, skipping what is blocked), and what to write back while
working (claim, comment, flag, complete). The vocabularies and the endpoint
list in it are generated from the code at request time, and a token earns a
closing section naming your boards and what each of their lists means.
`?format=json` returns the same text plus those parts as data, and
`slipdock guide` prints it. Point an agent at it before letting it near a board. Permissions match the UI:
reading needs read access, changing needs edit access, and renaming or
deleting a board needs its owner. Boards and columns can be referenced by id
or name, and a board by its code as well — `/api/boards/qvm-v1-rem`.

```
GET    /api/search   ?q= &board= &limit= &archived= &kind=card|page|all
                                                        search every board you can read, by meaning
GET    /api/search/status                               what is indexed, and whether anything is queued
GET    /api/saved-queries   ?mode=search|ask            your own saved queries (yours alone)
POST   /api/saved-queries   {mode, q}                   save one; saving it twice saves it once
DELETE /api/saved-queries/:id      DELETE /api/saved-queries   {mode, q}
POST   /api/ask     {q, history: [{role, content}]}     ask the assistant; it searches for itself
GET    /api/templates                      POST   /api/templates   {name, description, columns: ["Name" | {name, wip_limit, color}]}
GET    /api/templates/:id                  PATCH  /api/templates/:id   DELETE /api/templates/:id
GET    /api/boards                         POST   /api/boards   {name, code, description, color, template,
                                                   columns: ["Name" | {name, wip_limit, color, category}],
                                                   save_template: "Name" | true}
       ?archived=true|all &sort=manual|name|active|newest|oldest|cards
GET    /api/boards/:board                  PATCH  /api/boards/:board   DELETE /api/boards/:board
POST   /api/boards/:board/archive          POST   /api/boards/:board/restore   (owner only)
POST   /api/boards/order   {boards: [ref, ...]}   your own order for the index; others unaffected
POST   /api/boards/welcome   {force}   build the Getting Started tour board (409 if you have one)
GET    /api/boards/:board/cards            POST   /api/boards/:board/cards
       ?column= &tag= &priority= &flag= &q= &completed= &archived=true|all
       &due=overdue|today|week|month|has|none  &deps=blocked|ready|blocking|violated|free
       &assignee=EMAIL|NAME|me|none            (the board views' own filters; a bad bucket is a 400)
       POST takes "archived": true to make the card straight into the archive
GET    /api/boards/:board/columns          POST   /api/boards/:board/columns
PATCH  /api/boards/:board/columns/:id      DELETE /api/boards/:board/columns/:id
GET    /api/boards/:board/tags             POST   /api/boards/:board/tags
DELETE /api/boards/:board/tags/:id         GET    /api/boards/:board/activity?limit=&card=
GET    /api/boards/:board/swimlanes         ?view= &rows= &cols= &unit= &sort= &dir= &q= &due= &done= &empty=
                                            &tags= &priorities= &flags= &columns= &colors=   (lists are comma-joined)
GET    /api/boards/:board/views            POST   /api/boards/:board/views   {name, ...config params}
GET    /api/boards/:board/views/:id        PATCH  /api/boards/:board/views/:id   DELETE /api/boards/:board/views/:id
GET    /api/favourites                     POST   /api/favourites   {kind: board|column|card|view, id}
DELETE /api/favourites/:kind/:id           (yours alone; both writes are idempotent)
GET    /api/cards/:id                      PATCH  /api/cards/:id       DELETE /api/cards/:id
POST   /api/cards/:id/move   {column, index: "top"|"bottom"|N}
POST   /api/cards/:id/move   {board, column}   to another board, with its subcards; answers
                                               `moved: {tags_created, fields_dropped, milestones_unpinned}`
POST   /api/cards/:id/archive              POST   /api/cards/:id/restore
POST   /api/cards/:id/timer {action: start|stop}   stopping adds the minutes it ran to time spent
POST   /api/cards/:id/checklist {text}     POST   /api/checklist/:item_id/toggle   DELETE /api/checklist/:item_id
POST   /api/cards/:id/comments {body}      DELETE /api/comments/:comment_id
GET    /api/cards/:id/handoff              POST   /api/cards/:id/handoff {next_step, body} | {clear: true}
GET    /api/cards/:id/timeline             the lists it sat in, its waits and jobs, as spans
POST   /api/cards/:id/dependencies {blocked_by: id} | {blocks: id}
POST   /api/cards/:id/subboard {template}  DELETE /api/cards/:id/subboard
GET    /api/boards/:board/sprints/next     (what New sprint would fill in: name, start, days)
POST   /api/boards/:board/sprints {name, start, days, goal}   all optional; answers the sprint card
POST   /api/cards/:id/sprint {cards: [id...]}   move cards into a sprint; answers `added` and
                                               `skipped` ({id, reason}) — a board's `kind` is
                                               "sprints" on a sprint board (PATCH it to set one)
GET    /api/cards/:id/burndown             a sprint's {sprint, total, done, estimate, days:
                                               [{date, remaining, remaining_estimate, ideal}]};
                                               remaining is null for days still to come
GET    /api/boards/:board/sprints/velocity {sprints: [{id, title, start, due, committed,
                                               completed, committed_estimate, completed_estimate,
                                               finished}], average} — estimates in minutes
DELETE /api/cards/:id/dependencies/:other_id     (either direction)
GET    /api/automations/vocabulary         (the grammar a spec is written in, plus an example)
GET    /api/automations/presets            (the ready-made rules, and the fields each one takes)
GET    /api/boards/:board/automations      POST   /api/boards/:board/automations   {spec | preset+params | text, name, scope}
GET    /api/boards/:board/automations/:id  PATCH  /api/boards/:board/automations/:id   {enabled | name | spec | text}
DELETE /api/boards/:board/automations/:id  POST   /api/boards/:board/automations/:id/run
GET    /api/alerts                         DELETE /api/alerts/:id   DELETE /api/alerts
GET    /api/boards/:board/pages            ?tree=true &q= &parent= &archived=true|all &template= &status=
POST   /api/boards/:board/pages            {title, body, summary, parent, status, template, message}
GET    /api/pages/:id                      PATCH  /api/pages/:id   {title, body, summary, slug, status, base_hash, message}
DELETE /api/pages/:id      ?purge=true     POST   /api/pages/:id/restore
POST   /api/pages/:id/move                 {parent, position: N|top|bottom}
GET    /api/pages/:id/revisions            GET    /api/pages/:id/revisions/:rev   ?diff=previous|<rev id>
POST   /api/pages/:id/revert               {revision_id, message}
GET    /api/pages/:id/render               ?format=markdown|html|text  (references resolved)
GET    /api/pages/:id/sections             the heading paths a section may be addressed by
GET    /api/pages/:id/section/*path        PUT (replace)  POST (append — cannot conflict)
POST   /api/pages/:id/append               {body, message}
GET    /api/pages/:id/links                POST /api/pages/:id/links   {card | page, pinned}
GET    /api/boards/:board/pages/wanted     GET  /api/pages/resolve   ?board= &title=
GET    /api/cards/:id/pages               POST /api/cards/:id/pages   {title, template, values}
POST   /api/pages/:id/cards               {text, column}
POST   /api/boards/:board/pages/from-template  {template, title, card, values}
POST   /api/pages/:id/place    {column, before}    put it in a list, before a card or page-N
DELETE /api/pages/:id/place                          take it off the board
POST   /api/pages/:id/publish   {published: false to withdraw}   read-only at /w/:token
GET    /api/boards/:board/pages/export    POST /api/boards/:board/pages/import  {files, overwrite}
GET    /api/export   ?boards=del,ops &archived=cards|pages|boards|all   board trees as one document
POST   /api/import   <a document>                       build the trees in it, as new boards
                     (or a Trello board's JSON; ?from=trello to say so)
GET    /api/pages/query-vocabulary        the grammar a ```slipdock block is written in
POST   /api/pages/query    {board, body}  try a block without writing it anywhere
GET    /api/skills                         GET  /api/skills/:name    GET /api/skills/:name/*file

# Meeting capture: only while meeting mode is on (404 "meeting mode is off on this server" otherwise)
GET    /api/meetings                      is it on, where it shows, what may be sent
GET    /api/meetings/findings-schema      the format an agent's own findings use
POST   /api/boards/:board/captures        multipart: audio, transcript, findings, ics; or JSON with
                                          them as text; title, when, attendees, format, parent
GET    /api/boards/:board/captures        GET  /api/captures/:id    state, lines, findings, questions, record
POST   /api/captures/:id/resolve          {question, answer: value | number | label | null, replayed}
POST   /api/captures/:id/findings/:fid    {included} or {title, body, list, due_date, topic}
                                          (topic: a decision's heading on the meeting's decisions page)
GET    /api/captures/:id/preview          the change set and its digest, and what has moved
POST   /api/captures/:id/commit           {preview: digest}; 409 committed / stale (named) / changed
POST   /api/captures/:id/undo             {rest}; 409 lists what was edited since
POST   /api/captures/:id/retry            POST /api/captures/:id/discard
GET    /api/me/voiceprint                 your own voiceprint, the consent wording, meetings to enrol from
POST   /api/me/voiceprint                 multipart audio, or capture (id); consent: the wording's version
DELETE /api/me/voiceprint                 delete it now (only while an admin has voiceprints on;
                                          any user, user_id or email in the request is a 403)
```

A page's `:id` is its numeric id, its code (`W-31`), or `board-code/slug` with
the slash URL-encoded. Reads return the Markdown source in `body`, never HTML.
`base_hash` is the `content_hash` the edit was made against: send it and a
save that would land on someone else's comes back as a **409** with the page
as it now stands in `current`; omit it and the last write wins. `message` is
the edit's own note, kept in history beside the author, the client (`via`) and
the API token's name (`agent`). Drafts are invisible to anyone who could not
have written them — a reader gets a 404 rather than a 403, because the page's
existence is itself the thing being withheld.

Automation rules are the board owner's: listing or changing them needs
`:owner`, not just write access. `POST` takes either `spec` — the trigger,
conditions and actions written out, validated and stored exactly as given, no
model involved — or `text`, a sentence the server's model turns into a spec
(the web UI's path, and it needs an OpenRouter key). A program should send
`spec`; `GET /api/automations/vocabulary` is the whole grammar as data so it
can. Or send `preset` and `params` — one of the ready-made rules from
`GET /api/automations/presets`, filled in (`{"preset": "follow_list",
"params": {"column": "Doing", "notify": "email"}}`), again with no model; a
missing or unusable field is a 422 naming it. An unknown trigger, action or
condition comes back as a 422 naming it.
`…/run` runs a rule now, first forgetting what a timed rule has already acted
on, and answers `{"fired": n, "automation": {…}}`. Alerts are listed for
whoever the token belongs to, and dismissing one is per person — `DELETE
/api/alerts/:id` removes it from your list, not everyone's.

Card fields for create/update: `title description priority flags start_date due_date completed color`,
plus `column` (name or id), `tags` (replace), `add_tags` / `remove_tags`, `add_flags` / `remove_flags`,
and `assignee` (a user's email, or `me`; `""` or null unassigns). A card can
have several people on it: `assignees` (a list of emails) replaces the whole
set, the first becoming the lead; `assignee` replaces it with one person; and
`add_assignees` / `remove_assignees` change it without restating it.

Card JSON includes `blocked` (boolean), `blocked_by` and `blocks` (lists of
`{id, title, completed, archived}`), `sub_board` (`{id, name, completed,
total, columns: [{id, name, cards}]}` or null), `assignees` (a list of
`{id, email, name}`, lead first), `assignee` (the lead, or null) and `rollup` — null for a card without subcards, else
`{done, total, start, due, start_derived, due_derived, slip_days, blocked,
overdue, health, depth}` summarising every level beneath the card. Board JSON
includes `root_id` and `parent_card` (`{id, title, board_id}` or null).
Templates are addressed by id or name.

Swimlane config params accept tags and lists by name or id. On the grid
endpoint, `view` loads a saved view and the other params override it; the
response holds `rows`, `cols` (with labels and counts), `cells[row][col]`
(card lists) and the effective `config`. Views are addressed by id or name.

## CLI

`cli/` is a zero-dependency escript that wraps the API.

On Windows, one line in PowerShell installs it from the server you use, for
you alone and with no admin rights of its own:

```powershell
irm https://your-server/cli/install.ps1 | iex     # again later to update it
slipdock auth
```

It puts the escript and a `slipdock.cmd` that runs it in
`%LOCALAPPDATA%\Programs\slipdock`, adds that folder to your PATH and saves the
server's address in `~\.config\slipdock\url`. The escript needs Erlang/OTP 27
or later: if there is none it is installed with winget (`Erlang.ErlangOTP`,
which asks for admin rights once); `-NoErlang` stops instead, and `-Escript
C:\path\to\escript.exe` names one it can't find. The download is checked
against `/cli/SHA256SUMS` before anything is written. To take it away again:
`& ([scriptblock]::Create((irm https://your-server/cli/install.ps1))) -Uninstall`
(your sign-in is kept). The Docker image builds the escript from its own `cli/`
and serves it at `/cli/slipdock.escript`; a server run from a checkout has none
to serve, and says so.

Everywhere else, build and install it:

```sh
cd cli && mix escript.build && cp slipdock ~/.local/bin/
slipdock auth <token>    # from Account → API tokens; stored per server in ~/.config/slipdock/tokens/
slipdock whoami
slipdock ai-key            # your API key, masked; `ai-key <key>` sets it,
                         # `ai-key` alone with OPENROUTER_API_KEY set uploads that,
                         # `ai-key --remove` deletes it
slipdock ai               # endpoint, key and model your AI requests use
slipdock ai-endpoint <url> # point at a local OpenAI-compatible server instead of
                         # OpenRouter (`--key K` too, `--remove` to go back)
slipdock ai-models        # what that endpoint can run
slipdock ai-model <id>    # pick one (`--embed <id>` for the search index).
                         # The AI features need a key or an endpoint
slipdock guide             # the server's instructions for agents (GET /api/guide)
slipdock --help
```

`~` is `$HOME`, else `%USERPROFILE%` (Windows sets no HOME). It finds the
server via `SLIPDOCK_URL`, else `~/.config/slipdock/url`, else this
machine's tailnet address on port 4000; and the token via `SLIPDOCK_TOKEN`, else
the one saved for that server under `~/.config/slipdock/tokens/`. `slipdock url
<address>` writes the first of those (`slipdock auth` writes it too, for the
server you just signed into), and `slipdock url` on its own says which address
is in use and where it came from — the first thing to check when nothing can be
reached. The env vars win, for a one-off against another install.

A token is only ever sent to the server that issued it: point the CLI at
another address and it starts signed out there, rather than handing that
server your token. A token from before this (the single
`~/.config/slipdock/token`) is bound, the first time it is read, to the server
in `~/.config/slipdock/url`. The files are written mode 600 in a mode 700
folder. Plain `http://` to anything that isn't loopback, a private range or
your tailnet gets a warning on stderr; and nothing the server sends — a card
title, a comment — can carry terminal control sequences to your screen, as
they are stripped before printing (`--json` output is escaped instead).

```sh
slipdock swimlanes 1 --rows tag --cols due_date --unit month --open
slipdock save-view 1 Tags by month --rows tag --cols due_date --unit month
slipdock swimlanes 1 --view "Tags by month" --tag bug     # saved view plus an extra filter
slipdock cards 1 --kind document                          # just the files on the board
slipdock table 1 --kind card --kind page                  # cards and placed wiki pages, no files
slipdock views 1 | slipdock update-view 1 "Tags by month" --sort title --descending | slipdock delete-view 1 "Tags by month"
slipdock table 1 --open --fields id,title,column,due,deps   # table view; --group tag to group rows
slipdock table 1 --fields id,title,assignee,rollup,health    # what each card's subcards roll up to
slipdock swimlanes 1 --rows assignee --cols schedule --unit quarter   # who has what due when, rolled up
slipdock edit 12 --assignee ada@example.com                  # --no-assignee clears it
slipdock edit 12 --assignee ada@example.com --assignee me    # both of you, Ada leading
slipdock edit 12 --add-assignee sam@example.com              # join without taking it off anyone
slipdock move 12 "To Do" --board errands   # to another board, with its subcards and its tags
slipdock blocked-by 12 7 9        # #12 waits for #7 and #9;  --off removes
slipdock blocks 7 12              # same link from the other side
slipdock search what did we decide about refunds       # by meaning, every board, comments included
slipdock search flaky tests --board qvm-v1-rem --limit 5 --full
slipdock search how do retries work --kind pages       # the wiki only; --kind cards for the work
slipdock ask which boards have unfinished critical work    # it searches, then answers
slipdock search-status                                     # is the index built, is anything queued
slipdock saved                                             # the searches and questions you have saved
slipdock save what did we decide about refunds             # --ask saves it as a question instead
slipdock unsave --id 3                                     # or `slipdock unsave <the same words>`
slipdock templates
slipdock new-template Sprint --desc "Two weeks" --list Todo --list "Doing:2:amber" --list "Done::emerald"
slipdock new-board Q4 plan --template Sprint
slipdock new-board Hiring --list Applied --list "Interview:3" --list Done --save-template "Hiring"
slipdock welcome                  # rebuild the Getting Started tour board; --force for another
slipdock boards --all             # archived boards too;  --archived for those alone
slipdock boards --sort active     # or name, newest, oldest, cards; default is your own order
slipdock archive-board errands | slipdock restore-board errands
slipdock order-boards qvm-v1-rem errands 3     # your own order; boards left out fall to the end
slipdock subboard 12 --template "Bug triage"   # card #12 becomes a board; prints its id
slipdock new-board Delivery --template "Sprint planning"   # or: set-board <board> --sprints
slipdock sprint delivery --days 10 --goal "Ship the importer"   # the next sprint, dated on from the last
slipdock sprint-add 88 41 42 57                # move cards #41 #42 #57 into sprint #88
slipdock burndown 88                           # sprint #88's work left, day by day, against the ideal
slipdock velocity delivery                     # committed and completed per sprint, and the average
slipdock board <sub-board-id>                  # then use it like any board; --off removes it
slipdock automation-help                       # the triggers, conditions and actions a spec may use
slipdock automation-presets                    # the ready-made rules and the fields each one takes
slipdock new-automation 1 --preset follow_list column=Doing notify=email     # no AI needed
slipdock new-automation 1 --spec '{"trigger":{"type":"card_overdue"},"actions":[{"type":"alert","title":"Overdue: {{card.title}}","severity":"urgent"}]}' --name "Overdue alerts"
slipdock new-automation 1 when a card lands in Done, email me   # the server's AI writes the spec
slipdock automations 1 | slipdock automation 1 "Overdue alerts"                # list; show one in full
slipdock set-automation 1 3 --off | slipdock run-automation 1 3 | slipdock delete-automation 1 3
slipdock alerts | slipdock dismiss 7 | slipdock dismiss --all
slipdock wiki                                  # every board's wiki at once, folders and all
slipdock folder ls qvm-v1-rem                  # one board's filing: folders, then pages
slipdock folder new qvm-v1-rem "Design/Decisions"   # a path makes every level
slipdock folder mv qvm-v1-rem Decisions --name Choices --parent Design   # or --root
slipdock folder mv qvm-v1-rem Choices --icon light-bulb --color amber   # what it wears; --no-icon, --no-color
slipdock folder rm qvm-v1-rem Choices          # the folder only; nothing filed in it is deleted
slipdock folder organise qvm-v1-rem Inbox --by date --parent Meetings --dry-run   # or --by ai|tag|flatten; --per year; --root
slipdock folder rm qvm-v1-rem Choices --purge  # and the pages in it, history and all (owner only)
slipdock page file W-31 --folder "Design/Decisions"   # where it is kept; --no-folder takes it out
slipdock page ls qvm-v1-rem --folder decisions       # or --no-folder for the unfiled
slipdock page file W-31 --also Ideas [--board B]   # also filed there too (or a /vault/path); --not-in F takes it out
slipdock folder file qvm-v1-rem Design --also Ideas --also /Projects/Notes   # a folder too, all in it; --not-in F
slipdock folder show qvm-v1-rem Design          # its path, and where else it is filed
slipdock vault new Notes | slipdock vault ls      # board wikis laid out as one vault
slipdock vault map Notes /Projects --board projects [--folder Inbox]   # a vault path onto a wiki
slipdock vault locate Notes /Projects/Acme.md       # which mapping a path lands in (longest prefix)
slipdock vault unmap Notes /Projects | slipdock vault rm Notes      # the pages always stay
slipdock vault resolve Notes X/Dup | slipdock vault wanted Notes   # links across the whole vault
slipdock vault changes Notes [--since 812]     # what changed after a cursor: what sync polls
slipdock page tags brain | slipdock page ls brain --note-tag area   # a vault's notes' own #tags
slipdock page props W-31 [--file F | --clear]  # the front matter its file came with, kept exactly
slipdock page ls qvm-v1-rem --q retry           # the board's wiki; --tree for the shape of it
slipdock page read W-31                        # the Markdown source (--json for the hash and the rest)
slipdock page new qvm-v1-rem Retry policy --body - --summary "How retries work" --message "first draft"
slipdock page edit W-31 --body - --base-hash <hash> --message "log: rolled back at 14:05"
slipdock page history W-31 | slipdock page diff W-31 --rev 12 [--against 7] | slipdock page revert W-31 --rev 12
slipdock page section W-31 Log --append "- 2026-09-29 rolled back at 14:05"   # cannot conflict
slipdock page section W-31 "Deploy/Rollback" --file rollback.md --message "why"
slipdock page render W-31                      # every reference followed, for answering questions
slipdock page links W-31 | slipdock page wanted qvm-v1-rem | slipdock page pin W-31 --card 412
slipdock writeup 412 --template "Spec template"   # start a page for a card, pinned to it
slipdock page card 412                            # what has been written about a card
slipdock page from qvm-v1-rem "Decision record" --title "Dropping the queue" --set owner=ops
slipdock page make-card W-31 --body - --column "To Do"   # a passage becomes a card, linked both ways
slipdock page query-help                       # the grammar a ```slipdock block is written in
slipdock page query qvm-v1-rem --body -        # try a block before writing it into a page
slipdock page edit W-31 --priority high --flag review --due 2026-10-09 --assignee sam@example.com
slipdock page edit W-31 --percent 40 --color amber --done   # the card facets, on a document
slipdock comment W-31 "needs a worked example"  # comment, check, status, vote, weblink and
slipdock check W-31 "worked example"           # unweblink all take a page code as readily
slipdock status W-31 at_risk "stalled on SRE"  # as a card number
slipdock handoff 12 --next "Write the test" --body "State: …"   # where a card was left
slipdock page place W-31 "In Progress"         # put the doc in a list, beside the work
slipdock page place W-31 Backlog --before 42   # before card #42 (or --before page-7)
slipdock page unplace W-31                     # off the board; it stays in the wiki
slipdock page publish W-31                     # read-only at a public link; --off withdraws it
slipdock page share W-31 sam@example.com --write   # share it to edit (a group by name too); --off takes it back
slipdock page share W-31 lee@example.com --comment # read, comment, report and vote; no edits
slipdock folder share kb Specs Ops                 # a folder and all in it, with a group, read only
slipdock shared                                    # what other people have shared with you
slipdock page export qvm-v1-rem --dir ~/wiki   # out as .md files, front matter and all
slipdock page import qvm-v1-rem --dir ~/wiki   # and back in; --overwrite replaces rather than skips
slipdock export --out boards.json              # every tree you own as one portable document
slipdock export qvm-v1-rem --archived --out b.json   # one board, archived things included
slipdock import boards.json                    # build the trees in it; always new boards
slipdock import trello.json                    # a Trello board's JSON export works too
slipdock skills | slipdock skills install | slipdock skills check   # the agent instructions this server ships
slipdock skills chatgpt --dir ~/Downloads     # the same skills as zips for ChatGPT, which can't run this
slipdock tools                                # the Tools you can see: yours, shared, listed
slipdock tools show job-scan                  # its board, skills, files and versions
slipdock tools publish ./my-tool              # pack a folder and publish it as a new version
slipdock tools install job-scan               # its skills into ~/.claude/skills (--dir D)
slipdock tools check                          # are the installed Tool skills behind?
slipdock tools install-board job-scan         # have the server build its board (--name, --version)
slipdock tools request-listing my-tool        # ask an admin to list a version for everyone
slipdock tools file job-scan skills/job-scan/SKILL.md   # one file of the package, latest version
slipdock wiki files job-scan --folder Tool    # a board's wiki files that are not pages
slipdock wiki get job-scan Tool/cv.docx       # one of them, saved here (--out F, or - for stdout)
slipdock favourites                            # what you keep going back to, with the URL of each
slipdock fav list qvm-v1-rem "In Progress"     # also: fav card 42 | fav view <board> <view> | fav board <board>
slipdock hotkey slipdock 1                     # Ctrl+Shift+1 opens it in the web app; `slipdock hotkeys` lists yours
slipdock unfav list qvm-v1-rem "In Progress"   # or `fav ... --off`
```
## Tools

A Tool packages a way of working so other people on the same server can
install it: a board blueprint, agent skills, files and docs (#958). Tools
live at `/tools`; each has a page at `/tools/<name>`.

[Tool packages: the reference](tool-packages.md) has everything a program
building a Tool needs, in one place, with a worked example that a test holds
to the server. This section is the overview.

### Installing

The Tool's page renders its README, shows everything it would install — the
board's lists (with their roles), folders, tags, pages and rules, its board
files, and **every skill file in full** — and walks through installing it
from claude.ai, Claude Code or ChatGPT. Every route ends with the person
asking their agent to set the Tool up.

The board is built by the server, never by an agent. `install_tool` (MCP),
`POST /api/tools/<name>/install` (`version`, `name`), `slipdock tools
install-board <name> [--version V] [--name N]` and **Make the board** on the
page all call the same code: the lists are made with the categories their
roles need, then the rest of the blueprint is applied
(`Slipdock.Blueprint`), board files go into a wiki folder called `Tool`, and
a `tool_installs` row records who installed which version onto which board.
The answer is the board's code (`201` when made, `200` when it already
existed). Installing again returns the same board. A Tool's skills find
their board through that record: `list_tools` gives each Tool with
`installed.board`.

**Upgrading.** Installing a newer version over an install adds only what the
board is missing — lists, folders, tags, pages, rules and files — and
replaces a page only while its body is still exactly the installed version's
skeleton, so an edited page is never touched. The answer has `upgraded: true`
and says what was `added` and `skipped`. The same or an older version
changes nothing.

**Skills.** `GET /api/tools/<name>/skills.tar.gz` is every skill laid out
for a skills directory (`local` files beside their skill), which `slipdock
tools install <name> [--dir D]` unpacks; `slipdock tools check` compares the
local copies by sha. Each skill is also `…/skills/<skill>/claude.zip` (for
claude.ai's skill upload) and `…/skills/<skill>/chatgpt.zip` (with a note on
the connector), and the page offers both through the browser session.

**One file at a time** (#1156). `GET /api/tools/<name>/files/<path>` is one
file of the package by its path (`skills/<skill>/SKILL.md`,
`skills/<skill>/references/procedure.md`, `files/build.py`): text as
`text/plain`, anything else as a download. The headers carry
`x-tool-version` and the file's sha as its `etag`. It comes from the latest
version the caller can see unless `version` says otherwise, so a stub skill
can fetch its procedure at run time and pick up a new version without being
reinstalled. MCP `list_tools` with `tool` and `file` gives the same file's
text (with `skill`, `file` is a path in that skill's folder, and `skill` alone
is its `SKILL.md`), and with `link: true` (#1158) a single-use `download_url`
instead, good for 10 minutes with no token: for that file, for a skill's
claude.ai zip, or with neither for the skills tarball. So a scheduled task or
a chat that has the connector but no API token still reaches all of it. And the CLI is `slipdock tools file <name> <path>`. `GET
/api/tools/<name>` gives each skill's `skill_md` URL and each file's `url`.
Once the caller has installed the Tool, each board file also has a
`board_url`, the copy in the board's `Tool` folder, read with `GET
/api/boards/<board>/files/Tool/<path>`.

### Publishing

`slipdock tools publish <folder>` packs the folder and sends it to
`POST /api/tools` (multipart field `package`, or an `application/gzip`
body). A package is:

```
my-tool/
  tool.json     name, version, summary; optionally title, author, requires, files
  README.md     the docs, rendered as the Tool's page
  board.json    optional: the board blueprint
  skills/<name>/SKILL.md, and anything else under skills/<name>/
  files/        optional: each listed in tool.json's files
```

- **`tool.json`**: `name` is lowercase letters, digits and dashes, and is
  the Tool's address; the first person to publish a name owns it.
  `version` is a version number and must be newer than the latest published;
  a version never changes once published, and is identified by a sha over
  every file. `summary` is one line (200 characters at most). `files` lists
  each file under `files/` as `{"path", "install": "board"}` (into the
  board's `Tool` folder) or `{"path", "install": "local", "skill"}` (beside
  that skill's `SKILL.md`, on the installer's machine).
- **`board.json`**: `lists` (a name, or `{"name", "role", "category",
  "color", "wip_limit"}`; `role` is `ready`, `backlog`, `doing`, `done` or
  `dropped`, sets the category, and is checked against how the server will
  actually read the lists), `folders` (paths like `Config/Archive`), `tags`
  (names or `{"name", "color"}`), `pages` (`{"title", "body", "summary",
  "folder"}`; bodies may use `{{board.name}}` and `{{today}}`) and
  `automations` (`{"preset", "params", "name"}`, from the ready-made rules:
  `slipdock automation-presets` lists them). A rule may only name lists the
  blueprint makes. The runner presets take a `prompt`, so a blueprint's
  runner rule can say what its jobs are told.
- **Skills**: each `SKILL.md` starts with front matter whose `name` is its
  folder's and which has a `description`.

The server refuses a package with anything else at the top, a symlink or any
non-regular file, a path that is absolute or climbs out, more than 300
entries, more than 10 MB compressed, 25 MB unpacked or 10 MB in one file,
and says why. A version counts against its owner's storage.

Templates use the same blueprint: a template can carry `folders`, `tags` and
`automations` as well as its lists and pages, and a board made from it gets
them through the same applier.

### Sharing and listing

A Tool is private to its owner until shared. The owner shares it by email
on its page (an access grant, `read`: see and install). To offer it to
everyone on the server, the owner asks for a version to be listed (on the
page, `POST /api/tools/<name>/listing`, or `slipdock tools request-listing
<name> [--version V]`); an admin approves or declines it under **Tool
listings** (`/admin/tools`). Somebody who sees a Tool only because it is
listed sees the approved version and no newer one until that is approved
too. `list_tools` and `slipdock tools` give each Tool's `kind`: `mine`,
`shared` or `listed`.

## Skills

> Setting an agent up — the address, the approval, the skills — is
> [its own page](agents.md), written for the person doing it rather than for
> somebody reading the code. The rest of this section is how it works.

`priv/skills/` holds the agent instructions this app ships, and the server
serves them at `/api/skills` — versioned with the code they describe, so a
copy in somebody's agent directory can be checked against the API that
actually answers. Three ways to install them:

- `curl -fsSL <server>/install.sh | sh` — needs only `curl` and `tar`, so it
  works on the machine an agent is actually running on. It unpacks
  `/api/skills.tar.gz` into `~/.claude/skills` (an argument puts them
  elsewhere) and saves the server's address in `~/.config/slipdock/url`.
- `irm <server>/install.ps1 | iex` — the same on Windows, in PowerShell, into
  `%USERPROFILE%\.claude\skills` (`-Dir` for elsewhere, run as
  `& ([scriptblock]::Create((irm <server>/install.ps1))) -Dir C:\somewhere`).
  `install.sh` under WSL would put them in the WSL home instead, which
  Claude on Windows doesn't read.
- `slipdock skills install` (`--dir` for somewhere else), for anyone who has
  the CLI, with `slipdock skills check` to say whether a local copy is behind.
- `GET /api/skills` for the listing — every file, with a sha over each skill —
  and `GET /api/skills/<name>/<file>` for one file, for a client that would
  rather walk it itself.

**For ChatGPT**, which can't run the CLI, every skill but `slipdock-loop` is
also a zip to upload: `GET /api/skills/<name>/chatgpt.zip`, linked from *Set
up an agent*, or all of them at once with `slipdock skills chatgpt` (`--dir`
for somewhere other than here). They are built from `priv/skills` when asked
for, with a section at the top that maps each `slipdock` command onto the
tool of the MCP connector that does the same, and a description that names
the connector rather than the CLI. The listing's `chatgpt_zip` says which
skills have one. `slipdock-loop` is left out: it commits, pushes and watches
CI, which a chat can't.

- **`slipdock`** — the command and API reference: what each call does and when
  to reach for it, and the `curl` form for a machine with no CLI on it.
- **`slipdock-work`** — working *from* a board: epics and subcards, what to
  pick up next, what to write back as you go.
- **`slipdock-wiki`** — the wiki reference: finding, reading, writing, linking
  and the section writes, with `references/` for the markup, the section
  rules and the raw HTTP.
- **`slipdock-docs`** — the harder half: what belongs in a document and where.
  A page or a comment? Search before writing. Pin it to the card. Append to
  `## Log`, don't rewrite.
- **`slipdock-loop`** — working the ready list unattended: one pass, one card,
  its subcards included, claimed before the work and closed out with a
  wrap-up comment and the commit id. Where the work lands in a GitHub repo it
  watches the build too: a red default branch becomes a card at the top of
  To Do before anything else is picked, and every push gets a `Build started`
  comment. Subcards close without waiting for their build, which is checked
  before the next subcard starts; the epic, or a card with no subcards, waits
  for the build and is never closed on a red one.
  Written for `/loop`, a schedule or a cron, so the board carries all the
  state between passes.
- **`slipdock-capture`** — [meeting capture](#meeting-capture), where an admin
  has meeting mode on: sending a recording or transcript, putting the
  capture's questions to the user and recording only their answers,
  previewing, and committing only when asked.

Board-specific detail — board codes, list names, tag vocabularies — stays out
of these files on purpose and comes from `GET /api/guide`, which generates it
per caller. A skill that hardcodes them rots; one that sends the agent to the
guide first does not. They are plain Markdown, and the two that an agent
reaches for first — `slipdock` and `slipdock-work` — carry the `curl` form
alongside the CLI one, because the CLI is an escript and the machine the agent
is on usually has no Elixir. Everything else is in the guide, which is `curl`
throughout.

## MCP server

> Connecting a particular client step by step is in
> [Setting up an agent](agents.md#over-mcp). This section is the reference:
> what the server offers, how it authenticates, and the limits it keeps.

The app is also an MCP server, at `https://your-server/mcp` — the same
address as the web app with `/mcp` on the end; **Set up an agent** shows this
install's own. It speaks stateless Streamable HTTP (MCP revisions 2025-03-26
to 2025-11-25): every call is one `POST`, nothing is kept between them, and
there is no session to resume. claude.ai, the Claude desktop and mobile apps,
Claude Code, the Claude API's MCP connector and IDE clients all connect to it.

### The tools

A client gets a small, coarse set of tools rather than the whole
[JSON API](#json-api): every tool's schema costs context in every session of
every client that connects, so there are few of them and each does a whole
step of the work. Each one goes through the same access checks as the API,
so a token can do exactly as much over MCP as over HTTP — no more.

| Tool | What it does |
|---|---|
| `whoami` | Who the connection is signed in as, the token's scope, and how much of the account's item limit is used. |
| `get_guide` | The [agent guide](#skills) for this caller: the conventions, and the caller's own boards and lists. Read once per session, before changing anything. Gives the short guide by default; `section` gives one of the others it names, or `all`. |
| `list_boards` | Boards you can see, with code, lists and which list is ready, in progress and done. `archived: true` includes archived ones. |
| `get_board` | A board's lists in order, with a summary of each card and its description. |
| `list_cards` | Cards in list order, filtered by `column`, `open`, `deps: "ready"`, `no_assignee` and `archived` (`exclude`, `include` or `only`). `full: true` gives each card as `get_card` does (comments, checklist, docs), 20 at a time unless `limit` says otherwise. |
| `get_card` | A card in full: description, checklist with item ids, comments, dependencies, subcards and the wiki pages about it. With `timeline: true`, also its timeline: each list it sat in, its waits and its jobs. |
| `search` | Cards, comments and wiki pages by meaning, across every board you can read or one. `archived: true` includes archived cards; a card's id or link as `q` finds that card, archived or not. |
| `ask` | A `question` in prose, answered from the boards as `POST /api/ask` answers it, with the cards and pages it read (`id`, `title`, `kind`). `board` keeps it to one board. A model call on your own AI key and provider, so it can take a while; a token confined to some boards is refused, as it is by `/api/ask`. |
| `read_page` | A wiki page's Markdown and its `content_hash`, by code (`W-31`) or by board and slug or title. `board` says whose page it is (`id`, `code`, `name`) and whether that board is `archived` — a code reaches pages on your archived boards, which `list_boards` leaves out unless asked. A page on a board you cannot see is not found. |
| `list_pages` | A board's wiki pages in order — code, title, summary, folder, parent and pinned cards — filtered by `q`, `archived` (`exclude`, `include` or `only`), `template` and `draft`; `tree: true` nests children under their parents. `shared: true` (no board) lists what other people have shared with you, by owner. |
| `page_info` | Finding the way round a wiki, by `what`: `links` (a page's outgoing, unresolved and incoming links), `sections` (its heading paths, as `write_page`'s section modes take them), `wanted` (a board's linked-to pages nobody has written) and `resolve` (is there a page for this `title`, and the `[[link]]` to write). Drafts stay out of sight of readers who cannot edit them. |
| `page_history` | A page's revisions, newest first (`limit`, default 20): who saved each, how (`web`, `cli`, `mcp`…), the message and when. With `rev`, that revision's body and the diff it made against the one before, or with `against` (another revision id) the diff from that version instead; `diff: true` alone gives the latest save's diff. Long unchanged stretches come back as `skip` with a count, so a one-line edit does not return the whole page. |
| `list_vaults` | Your [vaults](#vaults) and their mappings; with `vault`, one of them; with `vault` and `path`, which mapping that vault path lands in (the longest matching prefix) and what is left of the path below it. |
| `activity` | A board's activity log, newest first; `card` narrows it to one card's entries. |
| `download_file` | A file attached to a card or a page, by its `attachment` id (`get_card` and `read_page` list them, `read_page` under `attachments`). The attachment's details come first; then a text file's contents as `text` (cut at 100,000 characters, with `truncated`), an image as an MCP image block, or anything else up to 5 MB as an embedded resource in base64. A bigger file is refused with its link in the web app. Checked as reading the card or page is: a file the token can't reach is not found. **`link: true`** (#1147) sends no bytes: it answers with the attachment's details and a `download_url` that works once, for 10 minutes, with no token (`curl -fsSo cv.docx <download_url>`), so a file of any size reaches a shell without passing through the model. A read-only token may have one. The link is checked again as that token when it is used; a used, expired or unknown one is `410 link_gone`. |
| `list_automations` | A board's [automation rules](#automations-and-alerts), as `GET /api/boards/:board/automations` gives them: each one's name, trigger, `spec`, `scope`, whether it is `enabled`, and how often it has run; `rule` (an id or name) gives one. `vocabulary: true` adds every trigger, condition and action a spec may use and the ready-made presets, so a client can write one without guessing. Only the board's owner, on a write token, may read them, as over HTTP. |
| `list_tools` | The [Tools](#tools) the caller can install — their own, the ones shared with them, the ones listed for everyone — each with its `kind` and the board their install made (`installed.board`), which is how a Tool's skill finds its board. With `tool` (and optionally `version`), that Tool in full: its README, board blueprint, skills with shas and download links, files, and, for its owner, where listing stands. With `tool` and `file` (a path in the package, like `skills/<skill>/SKILL.md`), that file's text from the latest version, or from `version` (text up to 200 KB; anything else names the API URL to fetch). With `skill`, that skill's `SKILL.md`, or with `file` a path in its folder. With `link: true`, a single-use `download_url` (10 minutes, no token) for the file, the skill's claude.ai zip, or the skills tarball. Read-only. |
| `garden` | A board's open [tidy-up suggestions](#tidying-up), as `GET /api/boards/:board/garden` gives them: each with its check, explanation, the cards and pages it is about, the steps applying it takes and any alternatives; plus the last run and every check's settings. `run: true` looks the board over first (write access); `check` narrows to one. Changes nothing on the board. |
| `create_card` | A card on a board, or with `parent` a subcard (making the sub-board if needed). |
| `update_card` | Title, description, priority (or clearing it), start and due dates, percent, flags, tags, assignees, what blocks it, its checklist — add, tick and untick items — and whether it repeats (`recurrence`, or `null` to stop it). Only what is passed changes. |
| `move_card` | To another list on its board, or with `board` to another board, subcards and all. |
| `comment` | A Markdown comment on a card; `@name` mentions notify. |
| `leave_handoff` | Leaves the card's handoff, as `POST /api/cards/:id/handoff` does: `next_step` (one line) and a `body` note, or `clear: true`. Write one whenever you stop with the card unfinished; `get_card` shows it first. |
| `garden_decide` | Applies, dismisses or undoes one gardener suggestion (`decision`: `apply`, `dismiss` or `undo`), as `POST /api/garden/suggestions/:id/…` do. Only for what the person approved, so it needs `confirm: true`. `keep` names the card that stays for a duplicate; `choice` takes one of its alternatives. |
| `upload_file` | Attaches a file to a `card`, or to a `page` (a code, or a slug with `board`): `filename`, and the bytes as `content_base64` or a text file's contents as `text`; `content_type` (else the name decides), `hide_on_card` and `sha256` are optional. `sha256` is the hex SHA-256 of the file's bytes before base64: given, bytes that arrive different (one flipped bit leaves the size as it was) are refused with `sha256_mismatch`, saying what arrived, and nothing is stored. Up to 10 MB — the CLI's `slipdock attach` and the API take bigger files. Answers with the attachment, its `sha256` the hash of the bytes as stored (compare it with the source's to verify in one call), and the `markdown` that embeds or links it, as `POST /api/cards/:id/attachments` does, and counts towards the owner's limits the same way. **In chunks** (#1016), for anything over a few KB, since base64 written out by a model is damaged more often the longer it is: the first chunk with `append: true` (plus `card` or `page`, `filename`) and that chunk's own `sha256` answers with an `upload_id` and `received`; each next chunk sends `upload_id`, `append: true`, `offset` (the last `received`) and its own `sha256`. A chunk that doesn't match is refused with `sha256_mismatch` and the rest is kept, so only it is resent; a resend of a chunk that already landed at that `offset` isn't added twice, and a wrong `offset` is `offset_mismatch`. Then `upload_id`, `finish: true` and the whole file's `sha256` (no content) checks the assembled file and attaches it, with the same access and limit checks as a single call; until then nothing is on the card. A whole file that differs discards the upload. Unfinished uploads expire after a day, and one person may have 10 open. `replace: true` (on a single call, or on the first chunk or `finish`) deletes the card's or page's older files of the same `filename` once the new one is stored, so a rebuild leaves one current copy; their ids come back as `replaced`. The old files go only after the new one is in, so a refused upload keeps them. **`link: true`** (#1147), with only `card` or `page` (and `board`), sends no file: it answers with an `upload_url` that works once, for 10 minutes, with no token. `curl -F file=@cv.docx -F sha256=<hex> <upload_url>` then takes what `POST /api/cards/:id/attachments` takes (`file`, `sha256`, `filename`, `replace`, `hide_on_card`), up to its limit, and answers as it does. It acts as the token that asked for it: that token needs write scope, its access is checked again when the link is used, and deleting the token kills its links. A refused upload (a `sha256_mismatch`, no `file`) stores nothing and leaves the link good to try again; a used, expired or unknown link is `410 link_gone`. For a scheduled task or a shared skill that has a connector but nowhere to keep an API token. |
| `delete_attachment` | Deletes a file from a card or a page by its `attachment` id (`upload_file`, `get_card` and `read_page` give it), as `DELETE /api/cards/:id/attachments/:attachment_id` does. Needs `confirm: true`. Checked as editing the card or page is; a file the token can't read is not found. |
| `complete_card` | Marks a card completed and moves it to the done list, with an optional closing comment. |
| `status_update` | Posts a status update on a card, as `POST /api/cards/:id/status` does: its `health` (`on_track`, `at_risk`, `off_track`) and an optional `body`. The latest is the card's stated health. |
| `archive_card` | Puts a card away, or with `restore: true` brings it back. |
| `delete_card` | Deletes a card with its subcards, comments and files. Needs `confirm: true`. |
| `create_list` | A list at the end of a board, with its category (`todo`, `doing`, `done`) and an optional WIP limit. |
| `create_tag` | A tag on a board (on its root, so the whole tree shares it), with an optional colour. A tag of that name already there comes back with `created: false` rather than a second one. |
| `delete_list` | Deletes an empty list; one holding cards only with `with_cards: true`. |
| `create_board` | A board of your own, with a template's lists (Backlog, To Do, In Progress, Done by default), or `lists` of its own that `save_template` can keep as a new template. |
| `archive_board` | Archives a board you own, or with `restore: true` brings it back. |
| `delete_board` | Deletes a board you own and everything on it. `confirm` must repeat the board's code. |
| `write_page` | The wiki: `create` a page, `append` or `append_section` to one, or `replace_section` and `replace`, which need the `content_hash` from `read_page` so nobody's edit is overwritten. |
| `update_page` | Everything about a page but its body: `title`, `summary`, `parent` (`""` for the top) and `position` among its siblings, `folder` (made if new; `""` unfiles), `also` / `not_in` (other folders it is also filed in), `archived` (`false` restores it, children too), and `pin_card` / `unpin_card` to mark it *the* page for a card you can read. Only what is passed changes. Purging a page for good stays on the CLI. |
| `file_folder` | Files a wiki folder in one more folder as well as its home (`also`), or takes it out of one (`not_in`): a folder on its board, on `in_board`, or a vault path. Same board or same vault, write on both, never inside itself. Answers with where it is filed now (`also_in`). |
| `share` | Shares a wiki page (`page`, a code) or folder (`folder`, with `board`) with a person (`with`, an email) or a group of yours (`group`), `level` read, comment or write; a folder shares everything at home in it. `off: true` takes it back; neither `with` nor `group` lists who has it. Only the board's writers share; somebody it was shared with gets `shared_no_reshare`. |
| `revert_page` | Puts a page back to a revision from `page_history`. The revert is a new revision, so nothing leaves the history and it can itself be undone; it needs `base_hash`, the page's current `content_hash`, so a newer edit is not lost to it unseen. |
| `manage_vault` | Changes a [vault](#vaults), by `action`: `create` (`name`), `rename` (`vault`, `name`), `delete` (`vault`, `confirm: true`; the pages stay on their boards), `map` (`vault`, `path`, `board` and optionally `folder`) and `unmap` (`vault`, `path`), either with `dry_run` to preview which pages join, move or leave; `move_folder` (`board`, `folder`, `to_board`, optionally `parent`, `contents`, `dry_run`), a folder with everything in it to another board; and `split` (`vault`, `path`, `board` or `new_board`, `dry_run`), giving a vault folder its own board and mapping its path onto it. |
| `manage_automation` | Changes a board's [automation rules](#automations-and-alerts), by `action`, as the API does and for its owner only: `create` from a `spec` (exact, no model), a `preset` with its `params`, or `text` (a sentence the server's model turns into a spec, on the AI key), with optional `name` and `scope` (`board`, or `tree` for its sub-boards too); `update` a `rule` (id or name) with any of `name`, `scope`, `enabled` and `spec`, or `text` to have the model rewrite it; `delete` a `rule` with `confirm: true` — `enabled: false` turns it off without losing it. A spec that doesn't validate is refused with the reason. |
| `install_tool` | Builds the board a [Tool](#tools) comes with, for the caller: the lists, folders, tags, page skeletons and rules from its `board.json`, and its board files in a `Tool` folder, by `tool` (its name), with optional `version` and `board_name`. Answers with the board's code and url and what was added. Installing again answers with the board already made, and makes nothing. |
| `claim_job` | Takes the oldest [runner job](#runners) queued for a pool on a board, with a lease: the card, its link, the job's kind and prompt. Answers `nothing queued` when there is none, so an idle check costs little. The session shows in the board's runner list. |
| `job_progress` | Renews a claimed job's lease; `note`, if given, is also a comment on the card. Answers `ok`, or `cancel` when somebody has stopped the job. |
| `finish_job` | Ends a claimed job: `outcome` done, failed, cancelled or timeout, and a `summary` kept on the job. Only the token that claimed it may. |
| `capture_meeting` | Sends a meeting's transcript (WebVTT, SRT, `Name:` lines, a Fireflies or Otter export) to a board for [meeting capture](#meeting-capture), with `title`, `when`, `attendees`, and optionally the agent's own `findings` in the published schema. Nothing is written to the board by it. Recordings go through the CLI or the API. |
| `capture_chat` | Sends the conversation the model is in (`Name: text` turns, or a Claude or ChatGPT export with `format` and `conversation`) to a board for [chat capture](#meeting-capture), optionally with the model's own `findings`: then no server model or AI key is needed, and every quote is still checked against the conversation. Only while chat capture is on (the default). Nothing is written to the board by it. |
| `get_capture` | A capture: its state, what it found and what each finding becomes, the open questions with numbered answers, and — once it is ready — the `preview` digest to commit with. |
| `resolve_capture_question` | Answers one question with the answer the person gave in the conversation (never the model's own); recorded as theirs, *via agent*. |
| `commit_capture` | Writes a ready capture to the board in one go, when the person asks; pass `preview` so exactly what they saw is written. Refused, naming the card, if something it changes was edited since. |

The last four exist only while an admin has [meeting mode](#meeting-capture)
on: off, they are not listed, and calling one by name is an unknown tool.

The reading tools are marked read-only, so a client can let them run
without asking each time. The deletes are marked destructive and none of
them can be undone, which is why each needs its confirmation; archiving,
which restoring undoes, is not. Writes count towards the board owner's
limits exactly as they do through the API, and a refusal comes back as the
tool's error — `card_limit_reached`, `trial_expired`, a read-only token —
rather than as a failed connection.

Every tool's schema lists the arguments it takes and allows no others, and
the server holds it to that: an argument the tool doesn't name (`archved`
for `archived`) is refused before anything is written, with the tool's
real arguments listed. A tool that writes a card answers with the card,
always saying whether it is `archived`.

### The prompts

Besides tools the server offers **prompts** (`prompts/list`, `prompts/get`):
ready-made workflows a client lists in its own menu — the **+** menu in
Claude Desktop and claude.ai, slash commands such as
`/mcp__slipdock__plan-my-day` in Claude Code — so nobody has to know what to
ask. ChatGPT's connectors use tools only, so they don't show there.

A prompt is not canned text. It is rendered with the caller's token, with
live board data already in it — the board's lists and counts, the cards
that matter — so the model starts from the facts instead of spending its
first calls finding them. Every rendered prompt starts with the boards'
conventions, ends by naming the tools to use, and is held to about 6,000
tokens: a long list ends with "…and N more, use list_cards".

| Prompt | Arguments | What it starts |
|---|---|---|
| `plan-my-day` | `board` (optional) | My work: overdue, due today, in progress and snoozed cards waking today, and the top of each ready list. Proposes a short ordered plan and asks before moving anything. |
| `weekly-review` | `board` (optional) | The last 7 days as a narrative — finished cards and the activity — then what slipped (open, past due) and what is stale (in progress, untouched for a week). Changes nothing. |
| `triage` | `board` | The board's intake list (its Backlog or Inbox) card by card: keep, move to the ready list, tag, date or archive, as you decide each. |
| `resume` | `card` | The card's [handoff](#where-it-was-left-handoffs), blockers, open subcards and latest comments; says where it stands and the next step. |
| `leave-handoff` | `card` | Writes the card's handoff from this conversation with `leave_handoff`, showing you the note first. |
| `capture-this-chat` | `board` | Sends this conversation through [chat capture](#capturing-a-conversation) and walks the preview; commits only when you say. Listed only while chat capture is on. |
| `tidy-board` | `board` | Looks the board over with the [gardener](#tidying-up) and walks its suggestions one at a time with `garden_decide`. With a read-only token it lists the suggestions as they stand. |

A prompt that writes is still listed for a read-only token; its text then
says so, and the workflow reports what it would do instead. A board-scoped
token's prompts see only its boards. While you type a `board` argument the
client is offered the codes of your boards, and a `card` argument offers
`#id title` (`completion/complete`), on the board already chosen if there is
one. A connector caches the list, so after an upgrade that adds a prompt,
disconnect and connect it again (or restart Claude Code).

### The resources

A **resource** is something you attach to a conversation yourself, the way you
would attach a file: "the Q4 plan page", "the Payments board". The model then
starts with it in front of it instead of searching for it. Tools are the
model's choice; resources are yours. In Claude Desktop and claude.ai they are
under the **+** menu; in Claude Code you mention one, as in
`@slipdock:slipdock://card/42`. ChatGPT's connectors don't use them.

| Resource | What it reads |
|---|---|
| `slipdock://board/{code}` | The board: each list in order with its open cards (number, title, priority, due date, flags, assignees) and how many are done. |
| `slipdock://card/{id}` | The card in full, as `get_card` gives it: handoff, description, checklist, open subcards, the latest 10 comments and the wiki pages about it. An archived card still reads by its number. |
| `slipdock://page/{code}` | A wiki page's Markdown source, front matter included. An encrypted note comes back as its ciphertext, with a line saying so. |
| `slipdock://view/{board}/{view}` | A [saved view](#swimlanes)'s rows. The view is its id or its name. |
| `slipdock://work` | [My work](#roll-ups-the-outline-and-my-work): the cards assigned to you, by when they are due. |

The list a client shows (`resources/list`) is not everything you can read: a
picker of every page in a big vault is no use. It is My work, your
[favourites](#favourites) (boards, cards, views and pages, in the order you
marked them) and the pages pinned to your favourite boards. To put something
in the menu, make it a favourite. Anything else is reached by its URI.

Every read goes through the same access checks as the tools, with your
token's scope: a board-scoped token reads only its boards, and a read-only
token reads everything you can. A URI that names nothing you can read is
"resource not found" (`-32002`), word for word what a URI naming nothing at
all gets. Each resource is capped (about 40,000 characters, 100,000 for a
page); a cut one ends with the tool that reads the rest. There are no
subscriptions: a client reads a resource again when it wants it fresh.

### Signing in

Two ways, and the server takes either on any request:

- **OAuth**, for clients that only take an address — claude.ai and the
  Claude apps above all. The server publishes its metadata at
  `/.well-known/oauth-protected-resource` and
  `/.well-known/oauth-authorization-server`, registers clients dynamically
  at `/oauth/register`, and uses PKCE. Connecting sends you here to sign in
  and see what is asking; you approve it, or lower it to read-only first.
  Each connection appears under **Account → API tokens** as a *connected
  app* named for the client, and deleting it there disconnects it. The
  connection renews itself while it is used at least once every 90 days.
- **An API token** in an `Authorization: Bearer` header, for clients that
  take a URL and a header. Make one under **Account → API tokens** (see
  [Signing an agent in](#signing-an-agent-in)). A read-only token gets the
  reading tools, and the writing tools answer that it is read-only; a token
  confined to some boards sees only those, and cannot `create_board`.

For Claude Code, either:

```sh
claude mcp add --transport http slipdock https://your-server/mcp        # then /mcp in a session to sign in
claude mcp add --transport http slipdock https://your-server/mcp \
  --header "Authorization: Bearer <token>"
```

In claude.ai: **Settings → Connectors → Add custom connector**, the name and
`https://your-server/mcp`, then **Connect**.

### Reaching it

claude.ai and the Claude apps connect from Anthropic's servers, not from
your browser, so a connector needs a server reachable from the internet over
https; if you self-host behind an allowlist, let in `160.79.104.0/21`. Claude
Code and other local clients connect from the machine they run on, so a
server on a LAN or a tailnet works for them as long as that machine can reach
it. Either way the server has to know its own public address (`PHX_HOST`,
and `SLIPDOCK_URL_SCHEME=https` behind a TLS proxy — see [Running](#running)),
because the OAuth metadata hands out URLs built from it.

The code is `SlipdockWeb.MCP.Plug` (the transport), `SlipdockWeb.MCP.Tools`
(the list, in the order `tools/list` gives it) and one module per tool under
`lib/slipdock_web/mcp/tools/`.
