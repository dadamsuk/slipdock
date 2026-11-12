
## The model

- **Board** — the root of a tree. `GET /api/boards` lists root boards only.
  Every board has a `code` as well as a name: a short, unique, URL-safe
  handle of at most 10 characters, taken from the name ("QVM V1
  Remediation" is `qvm-v1-rem`) and editable in board settings. It
  addresses the board anywhere `:board` appears, and unlike a name it is
  unambiguous — use it when you have no id, and say it back to the user as
  the short name of the board. A `shortcut` sits alongside it: one or two
  characters that jump to the board in the web app (the user presses `b`,
  then that key). It is settable, but it does not address anything — do
  not use it in a URL. A board belongs to one person: `owner` names them
  (`{"id", "email", "name"}`; it is fixed when the board is made and no
  request changes it), and `shared` is true when that person is somebody other than
  you — a board you reach through a grant rather than your own. Say whose
  board it is when you name one that is not theirs.
- **List** (a column) — ordered, and carrying a `category`: `todo`,
  `doing`, `done`, `dropped`, or null for "no particular meaning". The
  *names* differ from board to board (To Do / Now / Ready; Done / Shipped);
  the categories do not. **Decide what a list means from its category, not
  its name.** A list with none can be given one:
  `PATCH /api/boards/:board/columns/:id {"category": "todo"}`
  (`slipdock set-column B "To Do" --category todo`). A list may also carry a `horizon` (the date range it stands
  for) and a `wip_limit`. Deleting a list never takes its cards unless asked to
  outright (see *What not to do*). How the web app draws a list's cards is
  the list's own setting: `sort_by` (null for the order they were dragged
  into, or `created`, `updated`, `start_date`, `due_date`, `priority`),
  `sort_dir` (`asc`, `desc`) and `group_by` (null, `flag`, `tag`,
  `start_date`, `due_date`) — `slipdock set-column B "To Do" --sort due_date
  --group flag`. It only changes the drawing: a card's `position` is still
  where it was put, and *top of the list* still means lowest `position`.
  `show_age: false` leaves the age chip off the list's cards (`--no-show-age`),
  and `show_images: false` their front image (`--no-show-images`),
  whatever anyone's card views say.
- **Card** — one unit of work: title, description, `priority`, `flags`,
  `tags`, `start_date`, `due_date`, `completed`, `percent_complete` (0–100,
  or null when nobody has said), `assignees` (everybody it is assigned to,
  lead first) and `assignee` (the lead alone), `position` within its list.
  `archived_at` is set on archived cards. `flag_attention` says who clears
  each of its flags (#2624): `{"review": {"attention": "auto", "why": "A
  verifier agent checks it and decides."}}`, where `person` means somebody
  has to act, `auto` that the board's own processes clear it (a blocker
  still open, a verify pool's verifier) and `none` a mark that asks
  nothing (`starred`). The board draws a `person` flag filled and an
  `auto` one outline only.
- **Time** — a card's `time` says how long has gone on it against its
  estimate: `unit` (`minutes`, `hours`, `days`, `weeks`, `months`), `spent`
  and `estimate` in that unit, the same as `spent_minutes` and
  `estimate_minutes`, `percent` of the estimate (past 100 when it has
  overrun; null without one) and `timer_running` / `timer_started_at`.
  `spent` includes a running timer. Write `time_spent`, `time_estimate`
  and `time_unit` on the card — a bare number is in the card's unit,
  `"90m"`, `"1.5h"`, `"2d"`, `"1w"`, `"1mo"` say their own, and a day is 8
  hours, a week 5 days, a month 4 weeks — or `log_time` to add to what is
  spent (`"-30m"` takes off). `POST /api/cards/57/timer
  {"action": "start"}` runs the card's timer and `"stop"` adds what it ran.
  Log the time your own work took when the person asks you to; do not
  leave a timer running across sessions.
- **Subcards** — any card can own a board of its own. On the card that is
  `sub_board`; the subcards are that board's cards. Sub-boards nest to any
  depth. This is the hierarchy you will do most of your thinking in.
- **Checklist** — ticked steps inside a card. No dates, no comments, no
  status: the cheapest possible unit.
- **Comments** — the card's narrative, and where you explain yourself.
  `@handle` (the part of someone's email before the "@") in a comment or
  a description mentions a person who can see the board, and emails them
  a link to the card — so mention somebody when you need their attention,
  not as a signature, and never yourself.
- **Flags** — `flagged`, `blocked`, `review`, `waiting`, `starred`, `stuck`.
  Hand-set labels, independent of the computed `blocked` — except that a
  card flagged `blocked` loses the flag when the last card it depends on is
  completed or archived. `stuck` is the health monitor's (see *Health
  monitor*).
- **Dependencies** — `blocked_by` / `blocks` between cards, with cycle
  detection. `blocked: true` is computed: something it waits on is still
  open. The two cards may be on different boards — a subcard waiting on
  another epic's subcard, or on a card on another board altogether —
  which needs write access to the blocked card and read access to the
  blocker. A stub on another board carries that board's `board` code; one
  on a board you can't read says `"hidden": true` and "A card you can't
  see" in place of its title, but still counts towards `blocked`.
  Distinct from **links** (`relates`, `contributes`, `duplicates`),
  which are cross-references and carry no scheduling meaning.
- **Rollup** — a read-only summary of everything beneath a card: `done` and
  `total` leaves, effective `start`/`due` (its own or its subcards'),
  `start_slip_days` and `due_slip_days` (how far the subcards begin and end
   past the card's *own* start and due dates — `slip_days` is the old name
   for the due one), `blocked`, `overdue`, `health`, `depth`. Trust it instead of
  walking the tree to count.
- **Web links** (`urls`) — references out of the system: a page, a shared
  drive, a file elsewhere. Each is datestamped with `added_at`. Add one
  with `POST /api/cards/:id/urls {"url": "…", "title": "…"}`, remove it
  with `DELETE /api/cards/:id/urls/:url_id`. Use these for anything that
  lives outside the board; `attachments` are files the board itself holds.
- **Attachments** (`attachments`) — files the board holds, up to 250 MB
  each (a proxy in front of the server may refuse one request well before
  that: Cloudflare's free and pro plans stop at 100 MB, with a 413 that
  never reaches Slipdock — a person can still upload it in the browser,
  which sends it in chunks). Upload one as the multipart field `file`:
  `curl -H "$H" -F file=@shot.png B/api/cards/:id/attachments` (an optional
  `filename` field renames it, and an optional `sha256` field, the hex
  SHA-256 of the file, makes a file that arrives different a 422
  `sha256_mismatch` with nothing stored; `slipdock attach` always sends it;
  `replace=true` deletes the card's older files of the same name once it
  is stored, their ids in `replaced`, so a rebuild leaves one copy). The 201 carries the `attachment` with its
  `url`, its `size` and `sha256` as stored (every attachment listing has
  them, so checking a file needs no download) and a ready-made `markdown` — `![shot.png](/attachments/5/shot.png)`
  for an image, a plain link otherwise — to put in the description or a
  comment, where an image shows inline. `GET /api/cards/:id/attachments`
  lists them; `DELETE /api/cards/:id/attachments/:attachment_id` removes
  one (over MCP, `delete_attachment`). `GET /api/attachments/:attachment_id` is one file's details (with
  the `card` or `page` it is on), and `GET /api/attachments/:attachment_id/file`
  its bytes, with a token — the `url` is the web app's, which needs a
  browser session. A screenshot of what you changed is worth attaching. Pages take the
  same three at `/api/pages/:id/attachments`. With MCP but no token to hand,
  `upload_file` or `download_file` with `link: true` gives a single-use,
  ten-minute `/api/upload/:secret` or `/api/download/:secret` URL that
  needs none (#1147). A card's first image is the
  thumbnail on its front; `hide_on_card: true` (on the upload, or
  `PATCH /api/cards/:id/attachments/:attachment_id`) keeps one off it — do
  that for a log or a diagram nobody needs to see at a glance. A recording
  (`audio/…`) can be transcribed, when the server has a transcription server
  set up and an admin has given you *Transcription* (else 403): `POST /api/cards/:id/attachments/:attachment_id/transcribe` answers
  202 and works in the background; the attachment's `transcript_status`
  goes `running` → `done` (with `transcript`) or `failed` (with
  `transcript_error`). Read the transcript before summarising a call.
  PDFs and images are read for text by themselves, and search finds it:
  the attachment's `text_status` says how far that has got,
  `GET /api/attachments/:id/text` (MCP `download_file` with `text: true`)
  is the words, and `POST .../attachments/:attachment_id/read-text` tries
  again.
- **Moving a card to another board** —
  `POST /api/cards/:id/move {"board": "errands", "column": "To Do"}`. The
  card's subcards, comments, history and links go with it, its tags travel
  by name (made on the destination where they are new), and its custom
  field values survive only where that board has a field with the same key
  and kind. The reply's `moved` says what that cost:
  `{"tags_created": 1, "fields_dropped": 0, "milestones_unpinned": 0}` —
  repeat it back to the user rather than letting them find out later. Write
  access is needed on both sides, a card cannot be moved into its own
  subcards, and an archived card must be restored first. Leave `board` out
  and this is the ordinary within-board move, where `index` still applies.
- **Favourites** — the handful of things the person keeps going back to: a
  board, a list, a card, a saved view or a wiki page. They are *personal*, so
  `GET /api/favourites` is the token holder's own set and nobody else's,
  and it is worth reading at the start of a session: it says where this
  person actually works, which a list of boards does not. Each entry gives
  a `kind`, a `name`, its `board` and the `url` that opens it. Add one with
  `POST /api/favourites {"kind": "card", "id": 42}` (`kind` is `board`,
  `column`, `card`, `view` or `page`) and remove it with
  `DELETE /api/favourites/:kind/:id`. Favouriting changes nothing about the
  thing itself, so read access is enough — and never favourite on someone's
  behalf unless they asked.
- **Hotkeys** — `Ctrl+Shift` and a digit opens a board in the web app.
  The digits are the token holder's own, like favourites:
  `GET /api/hotkeys` lists them, and
  `PUT /api/boards/:board/hotkey {"digit": 1}` gives a board one (taking
  it off any other board) or `{"digit": null}` takes it away. Read access
  is enough. Set one only when the person asks. The wiki takes a digit
  too, and a switcher key: `PATCH /api/wiki {"hotkey": 2, "shortcut": "nt"}`.
- **Header links** — boards and the wiki pinned as icons left of quick
  add, the token holder's own: `GET /api/header-links` (with the `icons`),
  `POST /api/header-links {"board": "ops", "icon": "star"}` (or
  `{"wiki": true, "icon": …}`),
  `PATCH /api/header-links/:id {"move": "left"}`, `DELETE` to unpin.
  Pin only when asked.
- **Card views** — what the token holder sees of a card in the web app:
  each element of its front (`tags`, `due_date`, `handoff_note`…), of the
  opened card (`open.*`) and of its sidebar, properties included
  (`side.*`: `side.assignees`, `side.due`…), by global, board
  and list, each level stating only what it changes. They are personal,
  and your own output never follows them. `GET /api/card-views` lists the
  named ones and every element; `POST` and `PATCH /api/card-views/:id`
  take `name` and `show`, `hide`, `inherit` (lists) or `elements`
  (`{"comments": false}`, `null` to inherit); `DELETE` answers with
  `levels_now_inheriting`, the levels that applied it. A level is `GET`, `PUT` or
  `DELETE /api/card-views/level?board=ops&list=Done` (no `list` for the
  board's, neither for global); `PUT` also takes `card_view` (a named
  view to apply, `null` for none) and, on a board, `show_all`. `GET
  /api/card-views/applied?board=ops&list=Done&view=Sprint` is what a card
  there shows, each element with the level that decided it. Change them
  only when the person asks. CLI: `slipdock card-views`, `slipdock
  card-view set --board B --hide comments`; MCP: `card_views`.
- **Skills registry** — skills fetched from outside Slipdock (#2059): the
  token holder's sources and the seeds. `GET /api/skill-sources` lists them
  with each skill's metadata and `content_hash`; `POST /api/skill-sources
  {"url": "https://github.com/owner/repo"}` fetches one (a refusal, such as
  an address that isn't public or a file over the cap, is a 422 with its
  sentence), and `"seed": true` makes it everyone's (admins only, else a
  403; a new server seeds `mattpocock/skills`); `GET /api/skill-sources/:id`, `POST
  /api/skill-sources/:id/refresh` (answers with `changes`: added, changed,
  removed) and `DELETE` are for its owner, an admin for a seed. `GET
  /api/skill-entries/:id` is one skill in full (`body`), where it is
  enabled (`enabled_on`, each with its `status` and, when it changed
  upstream, the `diff`) and the Playbook stages naming it. A board writer
  enables one with `POST /api/boards/:board/skills {"entry": 12, "hash":
  "<content_hash>"}`, pinned to that text (any other hash is refused),
  re-pins it with `PATCH /api/boards/:board/skills/:name {"hash": …}` and
  takes it off with `DELETE`. `GET /api/skill-stages` lists every Playbook
  stage you can read that names a skill and what it gets (`flagged` when
  nothing does). Only when the person asks. CLI: `slipdock registry`; MCP:
  `skill_registry`. What the board's agents get is `GET
  /api/boards/:board/skills` (a reader is enough; a board you can't read
  is a 404): each enabled skill's `name`, `source_name`, `licence`,
  `pinned_hash`, `status` (`current`, `changed`, `removed`) and its pinned
  `text`, never newer. CLI: `slipdock skills board <board> [<name>]`; MCP:
  `get_guide` with `board`, whose answer adds the same list as `skills`.
  `slipdock-plan` uses it for a Playbook stage that names a skill: enabled
  on the board, else installed, else its own text.
- **Passkeys** — `GET /api/me/passkeys` lists the token holder's own
  passkeys (`id`, `name`, `created_at`, `last_used_at`; never the key), and
  `DELETE /api/me/passkeys/:id` removes one so it can no longer sign in.
  Adding one needs the person's device, so it happens only in a browser,
  on their account page. Remove one only when the person asks: it is a way
  into their account, not clutter.
- **Inbound email** — when the server receives mail (W-1933),
  `GET /api/inbound/log` lists the token holder's last 50 messages to its
  inbound addresses, newest first: `kind`, `subject`, `outcome`
  (`accepted`, `rejected` = bounced, `dropped` = automatic, ignored), the
  `reason`, and a `link` to what it made. 404 while inbound mail is off.
  Look here when someone says they emailed something and nothing happened.
  `GET /api/boards/:board/inbound` is the holder's own `card` address for
  a board they can write to (`?folder=` a wiki folder's own `page`
  address), `GET /api/me/inbound` their personal `add`
  (Quick Add) address and `ack`; mail to `add` reads its subject as Quick
  Add does, `title; description;; comment` (after one `;` the card's
  description, ahead of the mail's body; after two a comment), with
  `#high`, `due:`, `@name` and `#list`; `POST …/rotate` replaces one, and the old
  bounces; `POST /api/me/inbound {"ack": true}` mails a link back per card.
  A board's `card` address also takes mail from its permitted senders
  (`senders` in that answer; the owner sets them with `PATCH
  /api/boards/:board {"inbound_senders": [...]}`, `[]` clears): added as
  the address's owner, opening "Sent by …", never answering a wait.
  Emails about a card (mentions, waits, rule emails) can be replied to: the
  reply is a comment by that person, or answers a wait on them; so is mail
  to a board's `card` address whose subject starts `[#42]`, on card 42.
- **Recurring cards** — a card can repeat ("every Monday: review
  invoices"). Its `recurrence` says how (`rule`, `summary`, `next_on`,
  `next_at`, the next three in `upcoming`); `null` when it doesn't.
  `series_id` marks every instance a series made, and a single card's
  read (`GET /api/cards/:id`, `get_card`) names the one it was copied
  from as `copied_from` (`{id, title}`). The next instance is a copy of
  the current one made on the server's clock, in the board's ready
  list, starting clean: no assignees, flags, percent, handoff, waits,
  evidence or bar lock from the last one; one still open when the next is due has its due date moved
  on rather than a second made. Set it with
  `PUT /api/cards/:id/recurrence` (Recipes, below) or `update_card`'s
  `recurrence`, and never on a card the person didn't ask to repeat.
- **Snoozed cards** — a card can be hidden until a day (W-1803). Until
  `snoozed_until` it is left out of the board's lists, `list_cards`,
  My work and the runners' picks; then it wakes at the top of its list,
  or sooner when someone else comments on it or assigns it. `snooze`
  says until when and why (`null` when it isn't snoozed). `GET
  /api/cards/:id` and search still find it, an epic still counts it as
  open, and `?snoozed=include` (or `only`) lists them. Snooze rather than
  flag `waiting` when the wait has a date (Recipes, below).
- **Copying a card** — `POST /api/cards/:id/copy` makes a copy as it is
  now (checklist unticked, subcards reopened; no comments, dates or
  files), straight after it unless `board`, `column` or `at` say otherwise.
- Also on a card, and safe to ignore until you need them: `status_updates`
  (a stated `on_track` / `at_risk` / `off_track` with a note), custom
  `fields` and formula `scores`, `votes`, `attachments`, `milestones` on the
  board, and saved views.

The parts of a card's JSON that matter while you are working:

```json
{
  "id": 42, "board_id": 1, "column_id": 4, "column": "To Do", "position": 0,
  "title": "Query parser", "description": "…",
  "handoff": {"next_step": "Wire the parser into search", "body": "State: …",
              "via": "mcp", "by": {"id": 1, "name": "You"}, "at": "…"},
  "recurrence": null, "series_id": null, "snoozed_until": null, "snooze": null,
  "priority": "high", "flags": ["review"], "tags": ["api"],
  "start_date": null, "due_date": "2026-10-03", "completed": false,
  "percent_complete": 40,
  "archived_at": null, "assignee": {"id": 1, "email": "you@example.com"},
  "blocked": true,
  "blocked_by": [{"id": 7, "title": "Schema", "completed": false, "archived": false,
                  "board_id": 3, "board": "platform", "hidden": false}],
  "blocks": [],
  "sub_board": {"id": 9, "name": "Query parser", "completed": 2, "total": 5},
  "rollup": {"done": 2, "total": 5, "due": "2026-10-10", "start_slip_days": 0, "due_slip_days": 0,
             "blocked": true, "overdue": false, "health": "at_risk", "depth": 2},
  "checklist": {"done": 1, "total": 3,
                "items": [{"id": 11, "text": "empty state", "done": false}]},
  "comments": [{"id": 5, "body": "…", "inserted_at": "…"}]
}
```

`sub_board` and `rollup` are `null` on a leaf card — that is how you tell a
task from an epic. `handoff` is where the card was left (`null` if
nobody left one): read it before the comments. A finished card read on
its own (`GET /api/cards/:id`, `get_card`) carries `outcome` instead:
its `text` (*Done 6 Nov 14:32 · accepted by runner verifier · merged PR
#215 (def5678)*, in your time zone), `done_at`, `accepted_by`, `pr`,
`merge_sha` and `commit`. The handoff written before it finished is
history then: it moves to `last_handoff` (`before_finish: true`) and
`handoff` is `null`. One left after it finished, for what is still to
do, stays the `handoff`.
