[Slipdock — the manual](../manual.md)

## Features

- Multiple boards, each with its own colour, description, tags and a short
  **code** — a unique, URL-safe handle of up to 10 characters ("QVM V1
  Remediation" becomes `qvm-v1-rem`), taken from the name and editable in
  board settings, that addresses the board in the API and the CLI
- Lists (columns) with drag-and-drop reordering, inline rename, colour and WIP limits,
  and an order of their own: sorted by date or priority, grouped by flag, tag or
  date — see [A list's order and groups](a-lists-order-and-groups.md)
- Cards with drag-and-drop between and within lists (let go anywhere in a
  list's column — its header, its footer, the board below it — and the card
  goes to the bottom of that list; a card that has moved since your tab drew
  it, say while a phone slept, stays where it is now, and the board tells you
  and redraws), description, priority
  (low → critical), six flags (flagged, blocked, needs review, waiting, starred, stuck;
  each says who clears it: filled when a person has to act, outline only when
  the board clears it by itself, see [Who clears a flag](#who-clears-a-flag)),
  due dates with overdue/soon states, completion toggle, cover colours, tags,
  checklists (drag an item by its handle to put it in a new order; a placed
  wiki page's checklist too), comments, archive/restore and delete — one at a time, or several
  at once from the board's select mode (see [Changing several cards at once](calendar.md#changing-several-cards-at-once)).
  The board's **Archived cards** panel has a search box: a piece of a title,
  or a card's id (`#123`) or link, finds the archived card to restore. An
  archived card's own link opens that panel on it rather than a dead end.
- Card views: choose what you see of a card, on its front and opened, for
  every board, one board or one list; yours alone, and the same in every
  browser — see [Card views](card-views.md)
- Handoffs: one short note on a card saying where it was left — the next
  step, the state, the gotchas — read first by whoever picks it up next. See
  [Where it was left](where-it-was-left-handoffs.md)
- Verified work: optional per-board checks on what an agent says it
  finished — a bar written before work starts that then locks, evidence
  when it completes, and a second agent accepting or rejecting it — see
  [Verified work](verified-work.md)
- Recurring cards: a series on the card that copies the current instance when
  the next is due, in your timezone, without stacking up missed ones —
  [Recurring cards](recurring-cards.md)
- Snooze: hide a card that isn't actionable yet until a day, and have it come
  back at the top of its list — [Snoozing cards](snoozing-cards.md)
- Visualise: one page of a board's flow, velocity, burndown, cycle time,
  runners and DORA numbers —
  [Visualise](visualise-flow-velocity-runners-and-delivery.md)
- Delivery metrics: deploys recorded from CI, the DORA numbers and idea to
  production, and a *Shipped* line on the cards a deploy names —
  [Delivery metrics](delivery-metrics-deploys-and-dora.md)
- Tidy up: the board looks itself over for rot — epics done but open, cards
  stuck in progress, duplicates, orphaned pages, mistyped links — and
  proposes each fix for you to apply or dismiss — [Tidying up](tidying-up.md)
- A health monitor: every few minutes the server looks for work stuck in ways
  only a person would otherwise notice (jobs nobody takes, deadlocks, merges
  that stall, cards nobody is moving), tries a safe fix, and flags what it
  can't fix — [The health monitor](the-health-monitor.md)
- What is happening right now: which runners are doing what, and the cards in
  progress and where they are — [Right now](right-now.md)
- Findings: what each card taught that the code doesn't show, written by the
  pass in its closing comment or recorded by the server when work goes wrong,
  kept on the board to triage into the handbook — [Findings](findings.md)
- The ledger: what shipped since yesterday, a line per card with who accepted
  it, its evidence, the `should` rules it missed and where its time went, to
  read in ten minutes instead of approving each card — [The ledger](the-ledger.md)
- Incidents: a card that broke after something shipped names the card that
  shipped it and the check that should have caught it — [Incidents](incidents.md)
- Time tracking: a start/stop timer on each card, time spent and an estimate
  shown in a unit of its own, and a colour-coded bar between them — see
  [Time tracking](time-tracking.md)
- Attachments: files up to 250 MB on any card, and images (up to 50 MB) pasted
  or dropped into the description or a comment are uploaded and shown inline (stored under
  `priv/uploads/`, `SLIPDOCK_UPLOADS_DIR` to move it; served with access checks).
  The API and CLI upload them too — see [Attachments over the API](links-and-goals.md#attachments-over-the-api).
  A card's first image is a thumbnail on its front — see [Images on the card front](links-and-goals.md#images-on-the-card-front).
  A recording plays in place, and can be transcribed — see [Recordings](links-and-goals.md#recordings).
  PDFs and images are read for text, so search finds what is in them — see
  [Reading text from files](links-and-goals.md#reading-text-from-files)
- Email: forward or send a message to your board's own address and it is a
  card, attachments included, or to its page address and it is a wiki page
  (`+ Title` adds to one) — see [Emailing your board](emailing-your-board.md)
- @mentions: `@someone` in a card's description or a comment — the part of
  their email before the "@", or a one-word name — names a person who can see
  the board. Typing `@` offers the board's members; a mention shows as a chip,
  and the person gets an email saying who mentioned them and where, linking to
  the card. A comment emails everyone it mentions; a description only those an
  edit newly mentions, so re-saving it does not mention everybody again. Nobody
  is told about mentioning themselves, `@` anybody without access to the board
  stays plain text, and comments on wiki pages notify nobody. The email goes
  through the configured mail transport, so without SMTP nobody hears.
- Desktop notifications: the things that email a person (a wait opened on
  them or routed to them, an @mention of them) can also show as a toast from
  their computer, through any Slipdock tab they have open — see [Desktop
  notifications](waiting-on-a-person-waits.md#desktop-notifications)
- Dependencies between cards ("blocked by" / "blocks"), with cycle detection,
  a blocked badge on cards, and a swimlane axis/filter for blocked work
- Subcards: any card can become a board of its own, with lists chosen from a
  board template; sub-boards nest to any depth
- Sprints: a sprint board whose every card is a sprint, a **New sprint**
  button that dates the next one, and **Add cards…** to tick work from any
  board into it, and **Charts** for each sprint's burndown and the board's
  velocity — see [Sprints](sprints.md)
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
- The **loop chip**: while a runner job is claimed or running on a card, a
  chip with a CPU icon, the runner's name and the job's kind ("Mac Studio ·
  build", or verify, merge) sits beside its assignees — on the board tile, in
  the outline row, the table's assignee cell and the card's Assignees — linked
  to the job in the card's Runner jobs. It shows with the assignee field and
  goes when the job ends; the loop is never an assignee, so assignee filters
  and My work still mean people
- **Multiboard** (`/multiboard`, from the home page's toolbar): pick lists
  from any of your boards under **Lists** and see the top N cards of each
  (5 unless you say, up to 50), in the list's own order, archived and
  snoozed cards left out. **By board** gives a section per board, each row
  naming its list; **By list** a section per list; **Grid** every card as
  a tile saying which board and list it is from. Your view is remembered,
  and is in the URL (`?lists=12,14&top=5&by=grid`) to bookmark or share.
  `slipdock multiboard --list 12 --list "ops/To Do" --limit 3 --by list`
  and `GET /api/multiboard` (`lists`, `top`, `by`) give the same; with no
  lists they show your remembered view
- **Saved multiboards**: press **Save** on the Multiboard page to keep the
  view under a name and a colour. It becomes a tile on your home page among
  your boards, which you drag (or **Move up**/**Move down** from
  its menu) like a board, recolour from that menu, or delete there; deleting
  it leaves the boards alone. It opens at `/multiboard/<id>`, where changing
  the lists, the number of cards or the layout changes the saved one, and
  **Rename** changes its name and colour. From the command line:
  `slipdock multiboards`, `slipdock multiboard <saved>` (id or name),
  `slipdock save-multiboard <name> [--list L]... [--limit N] [--by B]
  [--color C]`, `slipdock set-multiboard <saved> [--name N] [--color C] ...`
  and `slipdock delete-multiboard <saved>`; over the API, `GET/POST
  /api/multiboards` and `GET/PATCH/DELETE /api/multiboards/:id`
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
  with its own folders and pages inside (see [Wiki](wiki.md))
- Cards move between boards, subcards and all, from the same menu that moves
  them between lists — tags travel by name, custom fields where the other
  board has them (see below)
- Favourites (`/favourites`): the handful of things you keep going back to —
  a saved view, a list on a board, a card, a whole board, a wiki page — kept per person and
  two taps from anywhere: the heart in the header, the phone's fifth tab
  (see below)
- Archivable boards: a whole board can be put away without deleting anything
  on it, and brought back from the Archived section of the board index
- Two layouts for the board index, and an order of your own: cards or a
  compact table, sorted your way (see [Your boards](your-boards.md))
- Board templates (named sets of lists) for new boards and sub-boards, with
  an editor at `/templates`
- A phone-specific layout below 640px: a floating navigation button with
  quick add in the thumb zone, the board as a one-list pager, and the calendar, swimlanes,
  timeline, table and Prioritise rendered for a narrow screen rather than
  scrolled sideways (see [On a phone](on-a-phone.md))
- Filter bar: full-text search, kind (cards / documents / wiki pages), tag,
  priority, flag, due date, hide completed. On the board, a search or filter
  shows its matches as one list down the page, grouped by the list each card
  is in, in board order: each heading gives the list's name and how many
  match, and a click folds or unfolds it (Done, and any list with more than
  10 matches, starts folded). The lists with no matches are named on one line
  at the end. Each match is one row that opens the card, with the move menu
  to send it to another list. **Board** in the banner puts the columns back
  for that search, and **Clear** ends it. A phone gets the same list in place
  of the pager
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
  dropped, triage for work nothing feeds to the loop, or scheduled for
  recurring agent work its feed rules work) and a **horizon** (a date range such as Q1 2027) that schedules
  cards dropped into them; cards can be scheduled by day, week, month,
  quarter, half-year or year; **milestones** are drawn on the timeline and
  calendar; the timeline draws **dependency lines**, red where the dates
  contradict the dependency; any view can be **coloured by** list, priority,
  health, reported health, assignee or tag, with a legend
- **Status updates**: on track / at risk / off track with a note, shown
  beside the health the roll-up computes. Their times ("18 min ago"), the
  status line at the top of the card and the comments' times keep up with
  the clock in the browser, without a reload
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
  set under Account › Preferences
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
  other MCP clients get the boards and the wiki as 56 tools, signing in
  through the browser or with an API token (see [MCP server](mcp-server.md))
- Groups of users; boards, single cards and saved views can be shared with
  people or groups as read-only or editable
- **A Getting Started board** built on a first sign-in: a tour of all of the
  above, made of cards, subcards, a live automation and wiki pages (see below)

---

[Contents](../manual.md) · [Getting Started](getting-started.md) →

## Who clears a flag

A flag on a card is drawn one of two ways, so a glance says whether you need
to do anything about it:

- **Filled**, with a solid icon (and a raised hand on the open card): nothing
  on the board will clear it by itself, so a person has to act.
- **Outline only**, and *clears itself* on the open card: something already in
  motion takes it off.

Hover a flag (or read it with a screen reader) for who clears it. Which way a
flag goes depends on the card:

| Flag | Filled: a person acts | Outline: clears itself |
|---|---|---|
| Waiting | always: a question waits on someone's answer | |
| Flagged | always: put on by hand, taken off by hand | |
| Stuck | always: the health monitor's own fixes ran out | |
| Blocked | blocked on nothing the board tracks | while a blocker card is still open: the board takes it off when that card is done |
| Needs review | flagged by hand; awaiting verification with no verify pool; or accepted and held for a person to merge | awaiting verification on a board with a verify pool (a verifier agent decides), or being merged |
| Starred | neither: a bookmark that asks nothing | |

The API's and MCP's card carries the same answer as `flag_attention`, one
entry per flag (`attention` `person`, `auto` or `none`, and `why`), and
`slipdock card` prints it beside each flag.
