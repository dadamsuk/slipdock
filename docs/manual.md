# Slipdock — the manual

Everything this app does, in detail. [README.md](../README.md) is the short
way in: what it is, the pictures, and how to get it running.

## Features

- Multiple boards, each with its own colour, description, tags and a short
  **code** — a unique, URL-safe handle of up to 10 characters ("QVM V1
  Remediation" becomes `qvm-v1-rem`), taken from the name and editable in
  board settings, that addresses the board in the API and the CLI
- Lists (columns) with drag-and-drop reordering, inline rename, colour and WIP limits
- Cards with drag-and-drop between and within lists, description, priority
  (low → critical), five flags (flagged, blocked, needs review, waiting, starred),
  due dates with overdue/soon states, completion toggle, cover colours, tags,
  checklists, comments, archive/restore and delete
- Time tracking: a start/stop timer on each card, time spent and an estimate
  shown in a unit of its own, and a colour-coded bar between them — see
  [Time tracking](#time-tracking)
- Attachments: files up to 25 MB on any card, and images pasted or dropped into
  the description or a comment are uploaded and shown inline (stored under
  `priv/uploads/`, `SLIPDOCK_UPLOADS_DIR` to move it; served with access checks)
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
- A phone-specific layout below 640px: a bottom bar with quick add in the
  thumb zone, the board as a one-list pager, and the calendar, swimlanes,
  timeline, table and Prioritise rendered for a narrow screen rather than
  scrolled sideways (see [On a phone](#on-a-phone))
- Filter bar: full-text search, kind (cards / documents / wiki pages), tag,
  priority, flag, due date, hide completed
- Web links on a card: pages, shared drives and files elsewhere, datestamped
- Command palette (`Ctrl-P`) for everywhere you can go and everything you can
  set off, and a card finder (`Ctrl-O`) that opens any card by title
- Keyboard throughout: `?` for the sheet, `b` to switch board (each has its own
  key), `v` to switch view, `q` to add, `/` to search; on a board `j` labels
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
  fills gaps between date buckets).
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

## Dependencies

Open a card and use the **Dependencies** section: pick *Blocked by* or
*Blocks*, search for another card on the board, and click it. A card is
*blocked* while any card it depends on is open (not completed, not archived);
blocked cards show a red lock badge with the count, and cards that hold others
up show an arrow badge. Self-links, links across boards, and anything that
would form a cycle are refused. Removing a card removes its links.

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
the sub-board and everything on it. The board index lists root boards only.

**Templates** are named lists of columns (name, optional WIP limit, colour).
Seven ship by default (Slipdock, Simple, Checklist, Bug triage, Research,
Roadmap — Now · Next · Later · Done, for the top of a tree — and Sprint
planning, below); manage them at `/templates`, pick one when creating a
board, or save any board's current lists as a template from its settings.

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

**Add cards….** On a sprint — the button in its card's Subcards section, or
in the header of the sprint's own board — this opens a picker. Choose a board
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
board › parent cards — and a link straight to it.

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
reads is yours: two controls sit beside **New board**, and both are
remembered between visits.

**Layout.** The cards are the default — a colour band, the code, the lists and
cards on it and how much is done. The compact layout is the same boards as a
table, a row each, with the board's colour, code, switcher key, description,
lists, cards, how far along it is and when anything last happened anywhere in
its tree. Worth switching to once there are more boards than fit on a screen.

**Order.** *My order* is the default, and it starts as the order the boards
were made in. Drag the handle on a card or a row to move a board, or use
**Move up** / **Move down** in its menu for the same thing without a mouse.
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

## Favourites

A board holds more than anyone works on at once. The board you live in is one
of nine, the list you actually move cards through is one of six on it, and the
card you report against every day is one of hundreds — three or four taps
every time, and the last one a hunt.

Press the heart on a **saved view** (in the Views menu), a **list header**, or
an open **card** (beside the close button) and it lands on `/favourites` — the
heart in the header bar on a desktop, the fifth tab on a phone, and an entry in
the avatar menu either way. So anything you go back to often is two taps from
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

- **A bottom bar** carries the app's navigation within reach of a thumb:
  Boards, My work, **Add**, Alerts, Favourites. On a desktop these live in the
  avatar menu and the header; on a phone that is a stretch to the far corner
  and a hunt through a menu. Templates had the fifth slot and gave it up: a
  template is something you reach for when making a board, which is rare, and
  a favourite is something you reach for all day. Templates keep their place
  in the avatar menu.
- **The header carries a magnifier and a `>_`**, because a phone has no
  Ctrl: they open the card finder and the command palette — the same two
  panels `Ctrl-O` and `Ctrl-P` open on a desktop, and the fastest way to a
  card on a screen that shows one list at a time.
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
  can open
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
- `Enter` opens the card, `J` picks it up, `c` adds a card to the list
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

Each can be turned off per board under **Board settings → At the foot of
every list**, or from the command line:

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

## Quick add

The table and outline views have a one-line add row: type a title, press
Enter, and the input is ready for the next card. Commands mixed into the
line are recognised as you type and shown as chips:

- `due: tomorrow`, `start: next mon`, `by friday`, `due: in 2 weeks`,
  `due: 1 oct`, `due: 2026-10-01`, `+3d`, `eow`, `eom`
- `#high` (a priority), `#blocked` (a flag), `#todo` or `#in-progress`
  (a list), `#docs` (a tag) — matched loosely, in that order
- `@dan` (an assignee, by name or email prefix)

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
substring. That is the right tool when you can half-remember the title and no
help at all when you cannot — when what you remember is that somebody said
something about refunds, on one of eleven boards, some time in the spring.

One page answers that, in two modes: **Search finds cards; Ask gives answers to
questions.** The toggle at the top switches between them and carries whatever
is in the box across, so "I searched, now ask the same thing" is one click.
Each mode keeps its own state — your results are still there when you come back
from asking. The mode is the URL (`/search` and `/ask`, the header's ⌕ and ✨
icons, or `Ctrl-P`), so it is linkable and the back button works through it.

**Search** embeds every card, comment and status update as a vector; your query
is embedded the same way and matched by meaning, so the words you type need
never appear in what comes back. A result is a **card**, because a card is what
you open. Under it are the chunks that actually matched — the comment, the
status update, the description — each labelled with what it is. That matters: a
card whose only match is a two-year-old comment looks exactly like a card whose
title is a bullseye until you can see which it was. Filter to one board or
include archived cards.

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
card, each comment, each status update. `Slipdock.AI.Embeddings` turns each into
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

```sh
mix slipdock.reindex              # build or repair the index (run this once, after migrating)
mix slipdock.reindex --stats      # what is indexed right now
mix slipdock.reindex --force      # empty it and rebuild from scratch
```

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
- **Edit mode** — the *Edit* toggle in the drawer (for people who can
  write) turns a request into a list of concrete changes: set or clear
  dates, priority, assignee, flags and tags, rename, rewrite a
  description, move between lists, complete or reopen, create cards,
  comment, add or tick checklist items, archive. It can also **archive a
  wiki page**, named by its code or its exact title — the one change it
  makes to the wiki, since a document is written in the wiki's own editor
  rather than dictated here. Relative dates are
  resolved from today. Nothing changes until you click *Apply*; every
  step is checked against the page and your permissions first, and
  anything the model got wrong (an unknown tag, a card not on the page)
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
  there for N days, have a tag set the priority.
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

## Wiki

The board answers *what are we doing*. It cannot answer *how does this work*,
*what did we decide and why*, or *what shape is the thing* — and those are the
answers that otherwise get rediscovered every few months. Each board has a
wiki for them at `/boards/:id/wiki`, reachable from the view menu: Markdown
pages in a tree of their own, with the board's permissions, the board's API
and no second system to keep in step.

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

**Organise mode.** The pencil at the top of the wiki's sidebar turns the tree
into a drag-and-drop one, and only then: dragging by default would make every
mis-aimed click a filing change in the one place somebody is trying to read.
In it, every row has a handle, and both axes are rearranged in the same tree —
a page dropped in a folder is *kept* there and belongs to no page; a page
dropped on a page becomes *part of* it, filed where that page is filed; a
folder dropped in a folder moves under it, and cannot be dropped inside
itself. Order is what you dragged: positions are packed afterwards so a tree
arranged by hand stays arranged. Every folder opens while you organise,
including the empty ones, which open into a drop target the moment a drag
starts.

**Searching the tree** matches a page's title and summary *and* a folder's
name, and hides everything that doesn't match. A folder that matches brings
what is in it, because somebody typing the name of a folder is asking where
things are; a page that matches keeps the folders above it so you can see
where it lives. What it does *not* match is the words inside the pages — that
is Search (`/search`), which reads bodies and matches by meaning — so above
the results sits **Full text search for: _what you typed_**, one click to the
same words on `/search`, already narrowed to this board. It is most useful
exactly when the tree search has just come back empty.

**Picking a folder is a tree you type at.** Everywhere the app asks which
folder — filing the page you are reading, the Folder field in the editor, the
"Inside" of the New folder dialog — it shows the filing as a tree and narrows
it as you type, matching anywhere in the path, so "dec" finds `Design/
Decisions` and the arrow keys and Enter pick it without the mouse. A folder
you cannot choose, like the one you are moving, is greyed rather than hidden.

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
purge — the page and its whole history, gone, with the pages *under* it kept
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

**References.** Inside a body, `[[Retry policy]]` links a page on this board
(by title, then slug), `[[retry-policy|how it works]]` gives it link text,
`[[QVM/Retry policy]]` reaches another board, `[[W-31]]` (or a bare `W-31`)
uses a page's code, and `[[board:QVM]]` / `[[view:QVM/Blocked work]]` reach a
board or a saved view. `@name` mentions someone on the board.
`[[!toc]]`, `[[!children]]` and `[[!backlinks]]` expand when the page is read.

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
`{{card.title}}`, `{{board.name}}`, `{{today}}` — plus any values passed in.
A board template can carry `pages` as well as lists, so a new board arrives
with its documentation skeleton rather than an empty wiki. A page can also be
a **favourite**, alongside boards, lists, cards and views.

**Every save keeps a revision** — a full snapshot, with the author, the edit's
own message ("why", not "what"), and how it arrived (`web`, `api`, `cli`,
`assistant`, `automation`, plus the API token's name). History lists them,
any one can be diffed against the one before it, and any one can be put back —
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
`/revisions`, `/revisions/:rev?diff=previous` and `/revert`). Reads return the
Markdown source, not HTML — the model edits what it reads — and `/render`
returns it with every reference followed, which is what to read to answer a
question rather than to change the page. Folders are
`/api/boards/:board/folders` (GET, POST), `/api/folders/:id` (PATCH, DELETE —
`?purge=true` takes the pages in it too, owner only; also by any handle at
`/api/boards/:board/folders/*path`), and `/api/wiki` is
every board at once. On a shell, `slipdock page ls|tree|read|render|new|edit|
section|append|file|mv|rm|restore|links|pin|wanted|history|diff|revert`, plus
`slipdock wiki` and `slipdock folder ls|new|mv|rm [--purge]`.

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

**The wiki keeps the board's bar.** The view selector, the search box, the
filter menu and the display options sit above the wiki the way they sit above
every card view — because a page answers the same filters now that it carries
the same facets. Narrow by priority, flag, tag or due date and the page tree
narrows with it; a page whose parent was filtered out stands at the root
rather than vanishing with it. The display menu is the wiki's own: whether to
list drafts, templates and archived pages at all.

The full specification, and the decisions behind it, is in `docs/wiki.md`.

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

Every board has an owner, fixed when it is made: the board settings form and
`PATCH /api/boards/:board` cannot change it, and a board somehow left with no
owner is open to nobody rather than to everybody. Ownership moves only when an
account is deleted and its boards are handed over.

**Your own four pages**, under the avatar menu and tabbed across the top of
each other, because one long scroll had the display name, the AI key and a
board importer on it and nothing told you which was which:

- **Account** (`/account`) — your display name, how many cards you have used
  against the limit if there is one, every time an admin has been let into
  your boards and why, signing out, and the licence.
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
An account with no date in the future is a free one.

**Admins.** One role, and the oldest account has it after an upgrade. Admins
change all of the above, see everybody, grant and remove admin rights, disable
accounts, set per-person item limits and record who has paid. Three things are
deliberately refused: mail settings will not save without a test message that
arrived, the last admin cannot be demoted or disabled, and the admin address
only changes once the new address confirms a code. There is no delete —
disabling is reversible and immediate, and deleting somebody would take their
cards, comments and page history with them.

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
(`/tmp/slipdock-agentic-login-<random>.txt` by default) and shows that filename
on the page. An agent with shell access to the server then reads the file and
opens the link it contains. The link works once and expires in 15 minutes, as
usual; the file is left behind for the agent to delete.

It is on in `dev` and `test`. In production it is off unless the server runs
with `SLIPDOCK_AGENTIC_LOGIN=true` (and optionally `SLIPDOCK_AGENTIC_LOGIN_DIR`
to change the directory). Anyone who can reach the sign-in page can create these
files, so only enable it on machines used for automated testing.

**Groups** (`/groups`) are named sets of people you can share with at once.
Members are added by email; the group's creator manages it.

**Sharing** — a board belongs to the user who created it. From the board's
settings the owner can grant *read only* or *can edit* access to a person or
a group; board access covers every card on it and the sub-boards inside
them. A single card can be shared the same way from its modal (by the owner
or anyone who can edit it): the recipient sees that card, listed under
"Cards shared with you" on the home page, and nothing else on the board. A
card grant can also raise a board reader to an editor on that one card. A
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
SLIPDOCK_PUBLISH=4000             # the host port to publish
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
| Embedding model | Only if the endpoint serves one, and only read for the account that indexes (`SLIPDOCK_AI_SYSTEM_USER`). Changing it invalidates every stored vector: run `mix slipdock.reindex --all` |

An endpoint of your own is enough on its own — with one set, the AI features
turn on whether or not you have a key, because a box on your own network has
nothing to bill. A model id matters, though: an OpenRouter id (`google/…`)
means nothing to a local server and the other way round, which is what the
picker is for. A server running several models at once will say so rather than
guess, if you have picked none.

To make a whole instance local, set `SLIPDOCK_AI_BASE_URL` (and
`SLIPDOCK_AI_MODEL`) instead: everybody who has not chosen for themselves then
uses it, no keys anywhere, and no board content leaves the network.

Unattended work — the search indexer, scheduled automations — has no person
to bill, so it uses a *system* key: `SLIPDOCK_AI_SYSTEM_USER=<email>` names
whose key to spend, and on a one-person install — registration closed, and
the only stored settings an admin's — those are used without being asked for.
Nothing else is guessed: the indexer sends every board through the system
settings, so one person's own endpoint never receives them unless an admin
named that person. `OPENROUTER_API_KEY` still works, but it is now a
**shared** key for everyone on the server, which is rarely what you want.

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
(it falls back to `SLIPDOCK_AI_MODEL`). `SLIPDOCK_AI_EMBED_MODEL` and
`SLIPDOCK_AI_EMBED_DIMENSIONS` pick the embedding model behind deep search;
run `mix slipdock.reindex` after changing either. Restart the server after
changing any of them.

Automation emails link back to the board; set `SLIPDOCK_BASE_URL` when the
address people use isn't the one the endpoint is configured with (behind a
proxy, say). Real mail needs `SLIPDOCK_SMTP_HOST` — without it, sent mail
stays in the in-memory mailbox at `/dev/mailbox`.

## As a service

`deploy/slipdock.service` is a systemd unit template that runs the dev server on
boot. It is a template because five lines are specific to your machine and
everything else is not — the file marks them: `User`/`Group`,
`WorkingDirectory`, `HOME`, the `EnvironmentFile` path, and the full path to
`mix`.

```sh
cp .env.example .env            # then fill in what you want to change
chmod 600 .env
sudo cp deploy/slipdock.service /etc/systemd/system/
sudoedit /etc/systemd/system/slipdock.service   # the five lines above
sudo systemctl daemon-reload
sudo systemctl enable --now slipdock
journalctl -u slipdock -f
```

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
GET    /api/boards                         POST   /api/boards   {name, code, description, color, template}
       ?archived=true|all &sort=manual|name|active|newest|oldest|cards
GET    /api/boards/:board                  PATCH  /api/boards/:board   DELETE /api/boards/:board
POST   /api/boards/:board/archive          POST   /api/boards/:board/restore   (owner only)
POST   /api/boards/order   {boards: [ref, ...]}   your own order for the index; others unaffected
POST   /api/boards/welcome   {force}   build the Getting Started tour board (409 if you have one)
GET    /api/boards/:board/cards            POST   /api/boards/:board/cards
       ?column= &tag= &priority= &flag= &q= &completed= &archived=
       &due=overdue|today|week|month|has|none  &deps=blocked|ready|blocking|violated|free
       &assignee=EMAIL|NAME|me|none            (the board views' own filters; a bad bucket is a 400)
GET    /api/boards/:board/columns          POST   /api/boards/:board/columns
PATCH  /api/boards/:board/columns/:id      DELETE /api/boards/:board/columns/:id
GET    /api/boards/:board/tags             POST   /api/boards/:board/tags
DELETE /api/boards/:board/tags/:id         GET    /api/boards/:board/activity?limit=
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
GET    /api/pages/:id/revisions            GET    /api/pages/:id/revisions/:rev   ?diff=previous
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

`cli/` is a zero-dependency escript that wraps the API. Build and install:

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

It finds the server via `SLIPDOCK_URL`, else `~/.config/slipdock/url`, else this
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
slipdock folder rm qvm-v1-rem Choices          # the folder only; nothing filed in it is deleted
slipdock folder rm qvm-v1-rem Choices --purge  # and the pages in it, history and all (owner only)
slipdock page file W-31 --folder "Design/Decisions"   # where it is kept; --no-folder takes it out
slipdock page ls qvm-v1-rem --folder decisions       # or --no-folder for the unfiled
slipdock page ls qvm-v1-rem --q retry           # the board's wiki; --tree for the shape of it
slipdock page read W-31                        # the Markdown source (--json for the hash and the rest)
slipdock page new qvm-v1-rem Retry policy --body - --summary "How retries work" --message "first draft"
slipdock page edit W-31 --body - --base-hash <hash> --message "log: rolled back at 14:05"
slipdock page history W-31 | slipdock page diff W-31 --rev 12 | slipdock page revert W-31 --rev 12
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
slipdock page place W-31 "In Progress"         # put the doc in a list, beside the work
slipdock page place W-31 Backlog --before 42   # before card #42 (or --before page-7)
slipdock page unplace W-31                     # off the board; it stays in the wiki
slipdock page publish W-31                     # read-only at a public link; --off withdraws it
slipdock page export qvm-v1-rem --dir ~/wiki   # out as .md files, front matter and all
slipdock page import qvm-v1-rem --dir ~/wiki   # and back in; --overwrite replaces rather than skips
slipdock export --out boards.json              # every tree you own as one portable document
slipdock export qvm-v1-rem --archived --out b.json   # one board, archived things included
slipdock import boards.json                    # build the trees in it; always new boards
slipdock import trello.json                    # a Trello board's JSON export works too
slipdock skills | slipdock skills install | slipdock skills check   # the agent instructions this server ships
slipdock favourites                            # what you keep going back to, with the URL of each
slipdock fav list qvm-v1-rem "In Progress"     # also: fav card 42 | fav view <board> <view> | fav board <board>
slipdock unfav list qvm-v1-rem "In Progress"   # or `fav ... --off`
```
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
- `slipdock skills install` (`--dir` for somewhere else), for anyone who has
  the CLI, with `slipdock skills check` to say whether a local copy is behind.
- `GET /api/skills` for the listing — every file, with a sha over each skill —
  and `GET /api/skills/<name>/<file>` for one file, for a client that would
  rather walk it itself.

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
  wrap-up comment and the commit id. Written for `/loop`, a schedule or a
  cron, so the board carries all the state between passes.

Board-specific detail — board codes, list names, tag vocabularies — stays out
of these files on purpose and comes from `GET /api/guide`, which generates it
per caller. A skill that hardcodes them rots; one that sends the agent to the
guide first does not. They are plain Markdown, and the two that an agent
reaches for first — `slipdock` and `slipdock-work` — carry the `curl` form
alongside the CLI one, because the CLI is an escript and the machine the agent
is on usually has no Elixir. Everything else is in the guide, which is `curl`
throughout.
