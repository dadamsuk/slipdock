---
name: slipdock
description: Read and write cards on the user's self-hosted Slipdock boards with the `slipdock` CLI. Use whenever the user mentions their kanban or Slipdock board, cards, lists/columns, tags, flags, or asks to add, move, complete, flag, tag, check off, comment on, archive, or look up tasks/cards. Also use to summarise what is on a board, what is overdue, blocked, or in progress, to set up or inspect board automations (rules that email, move, flag or alert by themselves) and the alerts they raise, to connect runners (coding agents on the user's own machines that the board sends cards to) and follow or cancel their jobs, to send a meeting's recording or transcript, or a conversation with an AI assistant, for capture, to tidy a board up (the gardener's suggestions: epics done but open, stale or duplicate cards, orphaned pages), and to read or write the wiki pages, docs, runbooks, specs and decision notes kept on a board.
---

# Slipdock CLI

The `slipdock` command talks to the user's Slipdock app — hosted at `app.slipdock.us`, or
self-hosted at whatever address they reach it by. Every write shows up live in the web UI.
Run `slipdock --help` for the full reference.

**Which server.** `$SLIPDOCK_URL`, else `~/.config/slipdock/url` (written by `slipdock url
<address>`, or by the server's own `/install.sh`), else this machine's tailnet address on
:4000. If none of those is the board the user means, ask them for the address — do not guess.

**If you are about to work *from* the board — pick up the next task, work through an epic, keep
cards updated while doing the work — run `slipdock guide` first** (the server's own instructions
for agents: epics and subcards, how to choose the next card, what to write back) and follow it.
This file is the command reference; the guide is the workflow.

## If Slipdock's MCP tools are connected

When this session already has Slipdock tools (`list_boards`, `get_card`, `create_card`,
`complete_card`…, from the server's `/mcp`), they are an alternative to the CLI for the same
work: use whichever is there. The conventions are the same either way — `get_guide` returns
the short form of the guide `slipdock guide` prints, ending with the names of its other
sections; `section: "automations"` (or any of those names, or `"all"`) gives one. `archive_card` puts a card away, and `restore: true` brings
it back; `archive_board` does the same for a board. Prefer those: `delete_card` (needs
`confirm: true`), `delete_list` and `delete_board` (`confirm` is the board's code) cannot be
undone. `create_list`, `create_tag` and `create_board` add structure (a tag must exist before
`create_card`/`update_card` can put it on a card). `list_cards` with `full: true` reads
every card in full (comments, checklist, docs) in one call instead of a `get_card` each. `update_card` also sets dependencies
and works the checklist. `list_pages` lists a board's wiki (`tree: true` nests it, as `page tree`
does), and `read_page` reads one. `page_info` answers what `page links`, `page sections`,
`page wanted` and `page resolve` do — ask it for `sections` before a `write_page` section edit
rather than guessing the heading path. `page_history` is `page history` and `page diff` (`rev`, `rev` + `against` to
compare two versions, or `diff: true` for the latest save), and `revert_page` is `page revert`: it needs the page's current
`content_hash` as `base_hash`. `update_page` is `page edit --title/--summary`, `page mv`, `page file`,
`page rm`/`page restore` (`archived`) and `page pin --card` (`pin_card`/`unpin_card`).
`upload_file` is `attach` for a file of up to 10 MB (`content_base64`, or `text`). Base64 a model
writes out goes wrong above about 1 KB (#1040), so with a shell where the file is, don't use it:
`slipdock attach`, or `curl -F file=@FILE -F sha256=<hex>` to `/api/cards/<id>/attachments`, keeps
the bytes out of the model. A file already in a synced vault is copied by the server with `vault`
and `vault_file` (its vault path or id; no content). `content_base64` must carry `sha256` (hex, of
the bytes before base64), and a `sha256_mismatch` refusal means re-encode and resend. The answer's
`sha256` is of the bytes as stored, and `get_card`/`read_page` list it for every file: compare that
with the source's hash to verify a file, rather than downloading it. Anything over a few KB goes
in chunks of about 4 KB (#1016), since the longer the base64 the likelier it is damaged: the first
with `append: true`, `card`/`page`, `filename` and that chunk's `sha256` returns an `upload_id`;
each next one sends `upload_id`, `append: true`, `offset` (the last answer's `received`) and its
own `sha256`, and a refused chunk is resent on its own; then `upload_id`, `finish: true` and the
whole file's `sha256` makes the attachment. Nothing shows on the card before that. A rebuild
of a file already on the card sends `replace: true` (on the single call, the first chunk or
`finish`): older files of that filename go once the new one is stored, so one current copy is
left. `delete_attachment` (`detach`; `attachment` id and `confirm: true`) removes one outright,
such as a file you uploaded wrong. And `download_file` reads an attached file by its id
(`get_card` and `read_page` list them).
`list_automations` is `automations`/`automation` (`vocabulary: true` adds what `automation-help`
and `automation-presets` give), and `manage_automation` is `new-automation` (`action: create`),
`set-automation` (`update`) and `delete-automation` (`delete`, with `confirm: true`).
`list_tools` is `tools`/`tools show` (each Tool's kind and `installed.board`, the board your
install made), and `install_tool` is `tools install-board`. Anything
the tools don't cover (running a rule now, callbacks and alerts, sprints, files over 10 MB,
fields) is still the CLI or the API.

## If the CLI is not installed here

Everything below is a wrapper around a JSON API, and the API is the fallback: it needs nothing
but `curl`. Do not tell the user to install the CLI (it is an escript and wants Erlang) —
use the API, and mention the CLI only if they ask for something nicer to type, or for vault
sync, which only the CLI does. On Windows that is one line in PowerShell, from their own
server: `irm "$B/cli/install.ps1" | iex`, then `slipdock auth`. Elsewhere it is built from
the repository's `cli/`.

```sh
B="${SLIPDOCK_URL:-$(cat ~/.config/slipdock/url 2>/dev/null)}"
T="$(cat ~/.config/slipdock/token 2>/dev/null)"
H="Authorization: Bearer ${SLIPDOCK_TOKEN:-$T}"

curl -s "$B/api/guide"                 # no token needed; the whole API, with curl for each call
curl -s -H "$H" "$B/api/me"            # who the token is
```

**`GET /api/guide` is the complete reference** — every endpoint, with a `curl` line for it, plus
the user's own boards and lists when a token is passed. Read it rather than inferring paths from
this file.

Signing in needs no CLI either; it is the same device flow, two calls (the guide spells them
out). Ask for a code, show the user the URL and the code, poll until they approve, then write
the token to `~/.config/slipdock/token` with mode 600 so the next session has it:

```sh
curl -s -X POST "$B/api/auth/device" -H 'content-type: application/json' \
     -d '{"label":"claude on this machine","scope":"write"}'
# → user_code, verification_uri, device_code, interval
curl -s -X POST "$B/api/auth/device/token" -H 'content-type: application/json' \
     -d '{"device_code":"…"}'
# → 400 authorization_pending until approved, then {"token":"…"}
```

To install these skills on a machine that has none of them:
`curl -fsSL "$B/install.sh" | sh` (needs only `curl` and `tar`); on Windows, in PowerShell,
`irm "$B/install.ps1" | iex` (into `%USERPROFILE%\.claude\skills`, not WSL's home).
For ChatGPT, which can't run this CLI, `slipdock skills chatgpt` saves them as zips to upload,
each mapping the commands onto the MCP connector's tools (`$B/api/skills/<name>/chatgpt.zip`).

## Signing in

The API needs a token. If a command fails with `not signed in`, **run `slipdock auth`** — it
prints a short code and a URL, the user approves it in a browser they are already signed into,
and you have a token a few seconds later. Tell them the code and the URL; do not ask them to go
and make a token by hand unless they would rather (`slipdock auth <token>` still takes one, and
`SLIPDOCK_TOKEN` still works).

`slipdock whoami` shows the current user. Boards the user can't access are simply not listed;
a `forbidden` error means they can see something but not change it. Two refusals name the
*token* rather than the user, and mean the token you hold is deliberately limited rather than
anything being broken — say so instead of retrying:

- `this API token is read-only` — it was granted read access only. Ask for a read/write one.
- `this API token's scope doesn't allow it` — it is confined to particular boards, or it is
  not an admin token and you tried to administer the server.

Two more refusals are also final. Report them and say what the person can do:

- `card_limit_reached` (HTTP 402) — the board owner's account has used all the **items** it
  allows. An item is a card, a wiki page or an uploaded file: all three count against one
  number, so writing it up as a page instead will not get round it. A different title will not
  help either; it will fail identically, forever. Suggest archiving something finished with.
  `slipdock whoami --json` and `slipdock guide` both say how much of the allowance is left, so
  you can check before starting a batch rather than discovering the wall halfway through.
- `board_limit_reached` (HTTP 402) — they own as many boards as this server allows one person.
  Sub-boards (subcards) do not count towards it. Suggest archiving a board, or asking an admin.
- `storage_limit_reached` (HTTP 402) — their uploaded files fill the space allowed. Only
  deleting attachments frees it; archiving the card the file hangs off does not.
- `trial_expired` (HTTP 402) — a free trial has run out. Nothing new can be added anywhere on
  their boards, however small. Everything already there is still readable and editable. Nothing
  you can do about it: tell the person they need to subscribe, and stop.
  These four answer more than creating: a restore from the archive, `move --board` onto somebody
  else's board (the card and everything under it count against them), an import, and `welcome`.
- `No account here uses that address…` when sharing — this server does not make accounts for
  the people you share things with. An admin has to invite them.

On a server where people see only those they share something with, somebody you expect to find
and cannot has probably not been shared anything. They have not been deleted, and assigning a
card to them will not work until something is.

A card can only be assigned to somebody who can open it. `user … not found` on an assignee
means exactly that, whether or not they have an account — share the board with them first
(the board's Share settings in the browser), or ask the person to.

## Workflow

1. **Find the board and its structure first**: `slipdock boards`, then `slipdock board <board>` or
   `slipdock columns <board>` and `slipdock tags <board>`. Boards and columns accept an id or a
   case-insensitive name, so `slipdock board "product launch"` works.
   Every board also has a **code** — its short name: unique, URL-safe, at most 10 characters,
   taken from the board's name and editable ("QVM V1 Remediation" is `qvm-v1-rem`). It is in
   the CODE column of `slipdock boards` and in the `code` field of `--json`, and `<board>`
   accepts it anywhere: `slipdock board qvm-v1-rem`, `slipdock add qvm-v1-rem "..."`. Prefer it
   over the name — it is unambiguous and survives renames — and use it when naming a board
   back to the user. `slipdock new-board <name> [--code C]` sets one explicitly; left out, one
   is generated from the name.
   A board also has a **shortcut key** — one or two characters that jump to it in the web app
   (press `b`, then the key). It is the KEY column of `slipdock boards` and the `shortcut` field
   of `--json`, and it is set with `--shortcut K` on `new-board` or `set-board`. It is not a
   way to address a board on the command line; the code is.
2. **Read before you write.** `slipdock card <id>` shows everything: description, flags, tags,
   checklist item ids, comments.
3. **Use `--json` when you need to parse output** (ids, filtering, counting). Plain output is for
   showing the user.
4. **Prefer `archive` over `delete`.** Delete is permanent. Ask before deleting anything the user
   did not explicitly ask to delete.
   A whole **board** can be archived too (`slipdock archive-board <board>`), which is not the same
   thing as archiving a card and is much further from your business: it takes the board off the
   user's index, their board switcher and their quick add. Never archive or reorder a board
   unless the user asked for that board by name.
5. **Say what is happening while it happens.** Work that runs longer than a short
   sitting gets `slipdock comment <id> ...` at each milestone — and `slipdock edit <id>
   --percent N` to match — rather than one write-up at the end. A card in progress
   with no comment newer than the move reads as abandoned to whoever is watching.
6. Report ids back to the user (`#42`) so they can find cards in the UI.
   `@handle` (someone's email before the "@") in a comment or description emails that person —
   use it only when the card genuinely needs them, never as a sign-off.
7. **The "Getting Started" board is a tutorial, not work.** The server builds one for a new
   account: its cards are instructions for a person ("drag this card to Done"), so never work
   them, finish them or tidy them. If that is the only board here, say so and ask what the user
   actually wants doing. `slipdock welcome` builds a fresh one for somebody who archived theirs
   and wants the tour back.

## Commands

Read:
```
slipdock guide                          # the server's instructions for agents (GET /api/guide)
slipdock boards [--archived|--all] [--sort manual|name|active|newest|oldest|cards]
slipdock board <board>                  # full board: every column and card
slipdock cards <board> [--column C] [--tag T] [--priority P] [--flag F] [--search Q] [--open|--done] [--archived]
                     [--due overdue|today|week|month|has|none] [--deps blocked|ready|blocking|violated|free]
                     [--assignee NAME|EMAIL|me | --no-assignee]
slipdock card <id>                      # full detail incl. checklist item ids and comments
slipdock columns <board> | slipdock tags <board> | slipdock activity <board> [--limit N]
slipdock pulse <board>                  # flow numbers: in progress, waiting, done this week, time to done, list in/out
slipdock swimlanes <board> [view options]   # grid of cards grouped on two axes (see below)
slipdock table <board> [view options] [--group A] [--fields id,title,column,priority,flags,tags,start,due,completed,percent,time,checklist,comments,deps,subcards,created,updated]
slipdock views <board>                      # saved swimlane views
slipdock favourites                         # what this person keeps going back to, with a URL each
slipdock passkeys                           # your own passkeys; `passkeys remove <id>` revokes one (only when asked)
slipdock search <words...> [--board B] [--limit N] [--archived] [--full]   # a card's #id or link finds it, archived too
slipdock ask <question...> [--board B]      # the assistant searches for itself, then answers
slipdock search-status                      # is the index built, is anything queued
slipdock saved [--ask | --mode search]      # queries this person saved (theirs alone)
slipdock save <words...> [--ask]            # save a search, or with --ask a question
slipdock unsave <words...> [--ask] | slipdock unsave --id N
```

**`slipdock saved` is worth reading alongside `slipdock favourites` at the start of a session.**
Favourites say where the user works; saved queries say what they keep wanting to know. Both are
personal and neither is derivable from the boards.

**`--search Q` on `slipdock cards` and `slipdock search` are not the same thing.** The first
filters one board's cards by substring — right when you know a word in the title. The second
matches by **meaning**, across every board at once, and covers comments and status updates as
well as cards: `slipdock search what did we decide about refunds` finds the card whose comment
said "finance want the rounding fixed", with no word in common. Reach for it when the user
describes a thing rather than naming it, when the answer is likely to be in a comment, or when
you do not know which board to look on. Each result shows the chunk that matched and what kind
it was (`card`, `comment`, `status`) — read that, not just the title, then `slipdock card <id>`
for the whole thing before acting.

**`--due`, `--deps` and `--assignee` are how you ask about state rather than words.**
`--due overdue` is the outstanding work (a completed card is in none of the date buckets),
`--due week` the next seven days, `--deps blocked` what is waiting on an unfinished card,
`--assignee me` your own (a card with several people on it is each of theirs).
Snoozed cards (💤 and the day they wake) are left out of `slipdock cards` unless you pass
`--snoozed include` or `--snoozed only`; the guide's list counts say "snoozed N". They mean the same thing here, in the swimlane views and in the API,
and an unrecognised value is an error rather than a silent list of everything.

`slipdock ask` is the same search with a model in front of it, plus tools of its own: it can
count a board list by list (to any depth, subcards included), describe a board's lists and
tags, list one person's work across every board, and read the activity log for a date range —
so "how many are in To Do?", "what's on Jess's plate?" and "what changed this week?" all get
answers. Prefer `slipdock search` when you want to choose the card yourself, which is nearly
always and *always* before a write — and prefer `slipdock cards <board> --column C` or
`slipdock activity <board>` when *you* want the answer, since those are the same answer without
a model in the way.

**`slipdock favourites` is worth reading at the start of a session.** It is the boards, lists,
cards and saved views the user has marked as theirs — where they actually work, which a list
of boards does not tell you. In the web app it is the phone's Favourites tab, two taps from
anywhere.

Swimlanes (`swimlanes`, `save-view`, `update-view` share these options):
```
--rows A --cols A      axis: none column assignee priority tag flag completed color due_date schedule created updated
                       (schedule = due date rolled up from a card's subcards)
--unit U               day|week|month|quarter|year for date axes      --sort S [--descending]
--view V               start from a saved view (id or name), then apply overrides
--tag T... --priority P... --flag F... --column C... --search Q --due overdue|today|week|month|has|none --open|--done
--show-empty           keep empty groups / fill date gaps
slipdock save-view <board> <name> [options] | slipdock update-view <board> <view> [options] [--name N] | slipdock delete-view <board> <view>
```
A saved view's URL (`/boards/1/swimlanes?view=ID`) opens the same grid in the web UI.

Write:
```
slipdock add <board> <title words...> [--column C] [--desc TEXT] [--priority P] [--flag F]... [--tag T]... [--start YYYY-MM-DD] [--due YYYY-MM-DD] [--color C] [--percent N] [--assignee EMAIL|me]... [--archived]
                                       # --archived: made straight into the archive (a record of finished work)
slipdock edit <id> [--title T] [--desc TEXT] [--priority P] [--start DATE|--no-start] [--due DATE|--no-due] [--percent N|--no-percent] [--color C|--no-color] [--column C]
                   [--assignee EMAIL|me]... | --no-assignee   # replaces who is on it; the first is the lead
                   [--add-assignee EMAIL|me]... [--remove-assignee EMAIL|me]...   # others stay on it
                   [--spent T|--no-spent] [--estimate T|--no-estimate] [--unit minutes|hours|days|weeks|months] [--log T]
                   # time: a bare number is in the card's unit, or 90m 1.5h 2d 1w 1mo "1h 30m" (day 8h, week 5d, month 4w)
slipdock log <id> <time>                 # add time spent (edit --log=-30m takes some off)
slipdock timer <id> start|stop           # stopping adds what the timer ran to time spent
slipdock move <id> <column> [--top|--bottom|--index N]
slipdock move <id> <column> --board B    # to another board, with the card's subcards; tags travel
                                       # by name, custom fields only where that board has them;
                                       # the command prints anything that was created or dropped
slipdock done <id>... | slipdock undone <id>...
slipdock copy <id> [--board B] [--column C] [--title T] [--top|--bottom]
                                       # a copy as it is now (checklist unticked, subcards reopened;
                                       # no comments, dates or files), straight after it by default
slipdock repeat <id> "every mon" [--at 07:00] [--lead 2] [--ends DATE | --count N] [--on-missed bump|skip|stack] [--column C] [--tz Z]
                                       # make it recurring: the next is a copy of it, made in the board's
                                       # ready list in the setter's timezone. Rules: day, weekday, mon,thu,
                                       # 2w mon, month 1, month last fri, month first mon, year, 3d after
                                       # (after the last is done), or FREQ=WEEKLY;BYDAY=MO. Only when asked
slipdock repeat <id>                     # how it repeats and the next three dates
slipdock repeat <id> --skip | --pause | --resume | --off
slipdock recurring <board>               # every card on the board that repeats, soonest first
slipdock snooze <id>... <when> [--note T] [--notify]
                                       # hide cards until a day (2026-11-02, tomorrow, mon, next week,
                                       # in 3 days; midnight in the user's timezone). They leave the lists,
                                       # My work and --deps ready, then wake at the top of their list
                                       # (sooner if someone else comments or assigns them)
slipdock wake <id>...                    # bring snoozed cards back now
slipdock garden <board> [--run] [--check K]   # tidy-up suggestions, grouped, with their fixes;
                                       # --run looks the board (and its sub-boards) over first
slipdock garden apply <id>... [--keep CARD] [--choice NAME]   # apply only what the user approved
slipdock garden dismiss|undo <id>...     # a dismissal is remembered until its subject changes
slipdock garden settings <board> [<check> key=value...]   # checks on/off, thresholds (days=30)
slipdock flag <id> <flag>... [--off]     # flags: flagged blocked review waiting starred
slipdock tag <id> <tag>... [--off]       # tag must already exist on the board (see new-tag)
slipdock check <id> <text...>            # add checklist item
slipdock tick <item-id>                  # toggle checklist item (ids from `slipdock card`)
slipdock comment <id> <text...>
slipdock weblink <id> <url> [--label TEXT]   # link a card to a web page, shared drive or file (datestamped)
slipdock unweblink <id> <url-id>...          # ids from `slipdock card`
slipdock attach <id> <file>... [--name N]    # upload files (a screenshot, a log); prints the Markdown
                                             # that embeds each — paste it into a comment to show it
slipdock attach <id> <file> --replace        # a rebuild: deletes older files of the same name once it is in
slipdock attachments <id>                    # list files; slipdock detach <id> <attachment-id>... removes them
slipdock download <attachment-id> [--out F]  # save a file's bytes (its own name here; --out - to stdout)
slipdock card-front <id> <attachment-id> --off   # keep an image off the card's thumbnail (--hide-on-card on attach)
slipdock transcribe <id> <attachment-id> --wait  # a card's recording to text (needs the admin's transcription server)
slipdock blocked-by <id> <card-id>... [--off]   # <id> waits for those cards (dependency; any board you can read)
slipdock blocks <id> <card-id>... [--off]       # <id> holds those cards up
slipdock archive <id>... | slipdock restore <id>... | slipdock delete <id>...
slipdock new-board <name> [--code C] [--shortcut K] [--desc TEXT] [--color C]
slipdock set-board <board> [--name N] [--code C] [--shortcut K] [--desc TEXT] [--color C]
slipdock archive-board <board> | slipdock restore-board <board>   # owner only; ask first
slipdock order-boards <board>...        # the order you list boards in (yours alone)
slipdock welcome [--force]              # rebuild the "Getting Started" tour board (see below)
slipdock new-column <board> <name> [--wip N] [--color C] [--category C]
slipdock set-column <board> <column> [--name N] [--wip N] [--color C] [--category C]   # category: todo|doing|done|dropped, "" clears
slipdock set-column <board> <column> --sort due_date [--descending] --group flag   # how the web app draws the list; --sort position / --group none undo it
slipdock new-tag <board> <name> [--color C]
slipdock new-board <name> [--code C] [--shortcut K] [--desc TEXT] [--color C] [--template T]
slipdock new-board <name> --list "Name[:wip[:color]]"... [--save-template NAME]   # its own lists; --save-template keeps them as a template too
slipdock templates                                        # sets of lists for new boards / subcards: the built-ins (read-only to all) and your own
slipdock new-template <name> [--desc TEXT] --list "Name[:wip[:color]]"... | slipdock delete-template <t>   # yours only; built-ins refuse (403)
slipdock subboard <card-id> --template T                  # card becomes a board of subcards (prints its id)
slipdock subboard <card-id> --off                         # remove the subcards
slipdock sprint <board> [--name N] [--start DATE] [--days N] [--goal TEXT]   # next sprint on a sprint board
slipdock sprint-add <sprint-id> <card-id>...              # move cards (with subcards) into a sprint; each leaves a stand-in (↪stand-in-for:#N) — never work or edit a stand-in, act on the card it names
slipdock sprint-sources <board> [<board>[:list,list]]... [--clear]   # where a sprint board plans from (no args: show)
slipdock sprint-plan <sprint-id> [--sort score|priority|estimate]   # source lists' open cards: priority, scores, votes, estimates, committed
slipdock burndown <sprint-id>                             # a sprint's work left each day vs the ideal
slipdock velocity <board>                                 # committed / completed per sprint, and the average
slipdock set-board <board> --sprints | --no-sprints       # make a board a sprint board (each card a sprint)
slipdock set-board <board> --simple | --no-simple         # plain to-do list: hides % complete, start, health, time, votes, deps
slipdock set-board <board> --default-view wiki            # what opening the board shows in the web app (board, table, wiki…)
slipdock set-board <board> --no-page-card-features        # the board's wiki pages hide status, checklist, links, fields, votes, comments
slipdock fav card <id> | fav list <board> <column> | fav view <board> <view> | fav board <board>
slipdock unfav <same args>                                # or `fav ... --off`
slipdock hotkeys | slipdock hotkey <board> <0-9|none>     # Ctrl+Shift+digit opens that board in the web app
```

Favourites are **personal** — the token holder's own, never anyone else's, and favouriting
something changes nothing about it (read access is enough). **Don't favourite on the user's
behalf unless they asked**; it is their shortlist, not a place to file your working set. Hotkeys
are personal the same way: set one only when asked.

Automations — rules the server runs by itself, long after you have gone:
```
slipdock automations <board>                  # every rule, with its trigger and how often it has run
slipdock automation <board> <rule>            # one rule in full, spec included (id or name)
slipdock automation-help                      # the triggers, conditions and actions a spec may use
slipdock automation-presets                   # ready-made rules (follow a board/list/card, reminders, tidying)
slipdock new-automation <board> --preset KEY [field=value...] [--name N]   # one of those, filled in
slipdock new-automation <board> --spec JSON [--name N] [--tree]   # exact; --spec - reads stdin
slipdock new-automation <board> <description...>                  # the server's AI writes the spec
slipdock set-automation <board> <rule> [--on|--off] [--name N] [--spec JSON] [--text "..."]
slipdock run-automation <board> <rule>        # run a timed rule now (forgets what it has done)
slipdock delete-automation <board> <rule>
slipdock callbacks <board> [--limit N]        # the calls its rules made, and what came back
slipdock alerts                               # what the rules want you to know
slipdock dismiss <alert-id>... | --all        # dismiss yours; other people keep theirs

# Runners: agents on the user's own machines that rules send cards to (owner only to make)
slipdock runner new <board> [name] --pool P [--scenario server|windows|loop|cloud|chatgpt]
    [--agent claude|codex|custom] [--command CMD] [--kind K] [--cwd DIR] [--permission-mode M]
    [--timeout S] [--service auto|systemd|launchd|none] [--where desktop|cloud] [--repo owner/repo]
    [--column LIST [--top] [--[no-]wait-while-doing]] [--verbosity nothing|quiet|normal|verbose]
    [--instructions TEXT]
    [--before-job CMD] [--after-job CMD] [--hooks prompt|hook]
    [--[no-]in-progress] [--[no-]assign] [--[no-]commit] [--[no-]push] [--[no-]move-done]
    [--[no-]complete] [--[no-]percent-100]    # what a job does to the card: each off unless given
    [--no-slipdock-tools] [--mcp-servers A,B]
                                              # prints exactly what to paste; server/windows make a
                                              # runner and print its token, ONCE; --column adds the rule
                                              # (--top: the list's top card, one at a time,
                                              # waiting while anything is in progress unless
                                              # --no-wait-while-doing)
slipdock runner ls <board>                    # runners: pool, last seen, current job
slipdock runner show <board> <runner>         # one in full: maker, job now, job counts, latest jobs, rules
slipdock runner setup <board> <runner> [opts] # the steps again; with options, saves them + shows the diff
slipdock runner token <board> <runner>        # a new token (the old one stops working)
slipdock runner rm <board> <runner>           # revoke
slipdock jobs <board> [--status open|queued|running|done|failed|cancelled|timeout]
slipdock jobs --card ID                       # one card's jobs
slipdock job <id>                             # status, runner, prompt, the tail of its log
slipdock cancel-job <id>                      # queued: at once; running: on the next heartbeat
slipdock claim-job <board> --pool P           # take the next job as this session ("nothing queued")
slipdock pause <board> [--pool P] --reason "…"   # owner: hold runner work (tree or pool); a person resumes
slipdock resume <board> [--pool P]            # let exactly that pause off (refused under an agent)
slipdock job-progress <id> [--message NOTE]   # renew the lease (20 min for a session); note → card
slipdock finish-job <id> --status done|failed|cancelled|timeout [--summary S]

# Tools: a board blueprint + skills + files that people on this server publish and install.
# The server builds a Tool's board; never build one by hand from its README.
slipdock tools                                # yours, shared with you, listed: kind, board you installed
slipdock tools show <name> [--version V]      # its board, skills (with shas), files, versions
slipdock tools install-board <name> [--name N] [--version V]
                                              # the server builds the board; again = the same board,
                                              # a newer version adds only what is missing
slipdock tools install <name> [--dir D]       # its skills (and local files) into ~/.claude/skills
slipdock tools check [<name>...]              # installed Tool skills current or behind, by sha
slipdock tools publish <dir>                  # tool.json, README.md, board.json, skills/, files/
slipdock tools request-listing <name> [--version V]   # an admin approves before everyone sees it

# Meeting capture, where the admin has turned meeting mode on (`slipdock meetings`).
# The whole workflow, and its two rules, are the slipdock-capture skill.
slipdock capture new <board> --transcript F [--audio F] [--title T] [--attendees A]
slipdock capture show <id>                    # what it found, and the questions — ask the USER
slipdock capture resolve <id> <q> <answer>    # only with the user's own answer
slipdock capture preview <id> | commit <id> --preview D | undo <id>
# Chat capture (on by default; no meeting mode needed): a conversation with
# Claude or ChatGPT, as Name: text turns or an export, into the same review.
slipdock capture-chat <board> chat.txt [--format chat|claude-export|chatgpt-export] [--conversation C] [--drop-transcript]
```

**Run `slipdock automation-help` before writing a `--spec`** — it prints the exact vocabulary
(triggers, condition fields and ops, actions, `{{placeholders}}`) with a worked example.
Prefer `--spec` to a plain-English description: you know the vocabulary, and a spec is stored
exactly as written, while a description goes through a language model that can misread you.
When what is asked for is one of the ready-made rules — "follow this list", "tell me about
comments on my cards", "remind me before things are due" — `--preset` is shorter still and
equally exact: `slipdock new-automation 1 --preset follow_list column=Doing notify=email`.
A rule with an unknown trigger or action is refused with the reason, so anything that saves runs.
An `email` action only reaches people who can read the board (owner and those it is shared
with), at most 10 per action; anyone else is refused at save. Rules are capped at 20 actions
and 50 per board, and what they send is metered (200 emails an hour per owner, 120 callbacks a
minute per board) — a "held back" last error means the allowance ran out, not that the rule is
wrong, so don't rewrite it.

The `runner` action sends the card to a coding agent on the user's own machine:
`{"type": "runner", "pool": "default", "kind": "claude"}` (an optional `prompt`, with
placeholders; by default the card's number, title, link and description). It queues a job
that a runner of that pool takes; at most one open job per card per rule. The rule picks the
*kind*, never a command: what a kind runs lives in the runner's config on that machine, so
don't try to put a command in a rule, and a job failing with exit 127 means that machine has
no function for the kind. With the trigger `list_top` (`{"type": "list_top", "column": "To
Do", "unassigned": true}`, preset `feed_runner`) the rule works a list in order instead: one
open job at a time, always for the top ready card. `"wait_while_doing": true` on the runner
action (the default for `feed_runner`) holds its jobs back while any other open card is in an
in-progress list on the board; `slipdock jobs` shows `queued (waiting: #N is in progress)`.
To set the whole thing up, `slipdock runner new` (or **Automations →
Connect a runner** in the UI) is better than writing the rule by hand. A job's token is shown
once: never paste it into a card, comment or page.

Every runner job's prompt ends by saying it runs unattended (nobody answers questions). A
Claude runner may use the Slipdock MCP tools without asking, for the servers named with
`--mcp-servers` (default `claude_ai_Slipdock,slipdock`; the name on that machine is in
`claude mcp list`); `--no-slipdock-tools` leaves it with no access to the board. When a runner's
agent says it can't use the Slipdock tools, that name is the first thing to check. Give a Claude
runner `--cwd` the project's folder: Claude Code loads the project's own commands, skills and
`.claude/settings.json` only from where it starts, so with none a project command is "not found".

The `webhook` action is the way out to anything else the user runs: it calls a URL of theirs
with the card — id, title, a link to it, list, priority, assignee, start and due dates,
status (`open`/`done`/`archived`), health, per cent complete, blocked, flags and tags — plus
the board, the rule and the event. `"method": "get"` sends those as query parameters
(`card.title`, `card.url`, …) instead of a JSON body; leave it out for a POST. The URL may
carry `{{placeholders}}` of its own in its path and query (they are percent-encoded),
not its host. Only public addresses are called — private, loopback, link-local and tailnet
ones are refused unless the server's admin allows them — and redirects are not followed. Calls go out in the background, so a rule's `last_error`
will not show a refused one — `slipdock callbacks <board>` will: every call, newest first,
with its HTTP status or the reason there was none.

Automations are the board's owner's business, and they outlive the task. **Don't add one to get
a job done** — do the job. Add one only when the user asks for something recurring ("always…",
"whenever…", "remind me when…", "every week…"), and tell them what you added and how to switch
it off. `slipdock alerts` is worth reading at the start of a session: it is the board saying what
it thinks is wrong.

The wiki — Markdown pages kept on a board, for what the cards cannot say:
```
slipdock page ls <board> [--q TEXT] [--archived|--all] [--template] [--draft]
slipdock page tree <board>                    # the page tree, nesting shown by indent
slipdock page read <page>                     # the Markdown source (--json for the metadata too)
slipdock page new <board> <title...> [--body TEXT|--file F|--body -] [--parent P] [--summary S] [--message M] [--draft]
slipdock page edit <page> [--title T] [--summary S] [--body TEXT|--file F|--body -] [--message M] [--base-hash H] [--draft|--publish]
slipdock page mv <page> [--parent P | --root] [--position N|top|bottom]
slipdock page rm <page> [--purge] | slipdock page restore <page>
slipdock page history <page> [--limit N] | slipdock page diff <page> [--rev N] [--against M] | slipdock page revert <page> --rev N
```

Folders are where a page is *kept*, as opposed to `--parent`, which is what it is *part of*:
```
slipdock wiki                                 # every board's wiki at once, folders and all
slipdock folder ls <board>                    # one board's filing, pages and all
slipdock folder open <board> [<folder>]       # one level of it, with counts (big wikis)
slipdock folder new <board> "Design/Decisions"    # a path makes every level
slipdock folder mv <board> <folder> [--name N] [--parent F | --root] [--icon I | --no-icon] [--color C | --no-color]
slipdock folder mv <board> <folder> --board B [--parent F] [--contents] [--dry-run]   # to another board, pages and all
slipdock folder rm <board> <folder>           # the folder only: nothing filed in it is deleted
slipdock page file <page> --folder F | --no-folder
slipdock page file <page> --also F | --not-in F [--board B]   # also filed in more folders
slipdock folder file <board> <folder> --also F | --not-in F [--board B]   # a folder too, all in it (repeatable)
slipdock page share <page> [EMAIL|GROUP] [--comment|--write] [--off]   # share one page (read only by default; --comment = read + comment/status/vote, no edits); no one named lists who has it
slipdock folder share <board> <folder> [EMAIL|GROUP] [--comment|--write] [--off]   # a folder and everything at home in it
slipdock shared                               # what other people have shared with you; `page read`/`page edit` take its codes
slipdock folder show <board> <folder>         # its path, and where else it is filed
slipdock page new <board> <title...> --folder F   # or file it as you write it
```

A vault is a folder tree of Markdown (and other) files (Obsidian's word; Obsidian isn't
required). Vaults lay several boards' wikis out as one such tree (a vault path → a board's wiki
or a folder of it, longest prefix winning; one vault per board):
```
slipdock vault ls | slipdock vault show <vault> | slipdock vault new <name...>
slipdock vault map <vault> <path> --board B [--folder F] [--inside] [--dry-run] | slipdock vault unmap <vault> <path> [--dry-run]
slipdock vault inside <vault> <path> [--off] | slipdock vault new <name...> --with-board
slipdock vault dress <vault> <path> [--icon NAME] [--color NAME]   # what the mount wears in the vault's tree
slipdock vault locate <vault> <path> | slipdock vault rename <vault> <name...> | slipdock vault rm <vault>
```
A board that only holds a vault's pages can be kept inside it (`--inside`, `vault inside`): the
owner's home page names it on the vault's tile instead of among their boards, and `boards` marks it
`in <vault>`; it's still an ordinary board at its address. `vault new --with-board` makes the
vault with such a board at `/`.
`vault ls` also shows how many pages each mapping holds and the folders the vault is synced to
(each sync token's label and last sync); `--dry-run` on map/unmap previews which pages join,
move or leave the vault before changing it. A mapping over pages another mapped board already
has at those paths is refused with the count. The one-step way out:
`slipdock vault split <vault> /Projects --board B [--dry-run]` (or `--new-board NAME`) moves what is
in that folder to B's top and maps `/Projects` onto B; notes keep their vault paths, so synced
folders see no change. Dry-run first and show the person the report. People do the same on the web app's Vaults screen
(`/vaults`, avatar menu › Vaults); each vault also has a view of its own, its pages
at their vault paths (a vault's `url` in `--json`, e.g. `/vaults/Notes/Projects/Roadmap`).

`slipdock sync` mirrors a vault both ways to a local folder that stays a valid Obsidian vault
(notes as `.md`, other files at the same path; a delete archives; changed on both sides, the
local copy is saved as `Name (conflict DATE host).md`):
```
slipdock sync init <dir> --vault V | slipdock sync [<dir>] [--watch] | slipdock sync status [<dir>]
slipdock sync from-server [<dir>] | slipdock sync to-server [<dir>]   # one way only: what it skips waits, listed as held
slipdock sync service install|uninstall|print [<dir>]   # keep --watch running in the background
slipdock vault import <dir> --vault V [--dry-run]       # an existing Obsidian vault, in once
```

`<page>` is the page's **code** (`W-31`), its slug, or `board-code/slug`. The code is stable
across renames and re-slugs, so it is what to write in a commit message or hand back to the
user; the slug is what the URL reads as.

**Send `--base-hash` on every edit you did not write yourself a moment ago.** `slipdock page read
--json` gives the `content_hash`; pass it back and a save that would land on top of someone
else's is refused rather than applied, and the CLI tells you what the page now says. Without it
the last write wins — recoverable from history, but still someone's paragraph gone. Two agents
and a person may all be writing the same runbook.

**Write `--message` every time**: it is the "why" in the page's history, beside who wrote it and
whether it came from the web app, the API or a shell. Nothing is ever lost to a save — every
save keeps a revision, and reverting is itself a save — so the history is only useful if the
messages are.

Judgement, which matters more here than the commands do:
- **Search before writing.** `slipdock search --board B <the thing>` and `slipdock page ls B --q`.
  A fourth page about deployment is the usual mistake; extend what exists unless the subject is
  genuinely new.
- **A page or a comment?** Durable and re-read → a page. About one card and about *now* → a
  comment or status update on the card. Never both.
- **Append to a `## Log` section** for dated notes rather than rewriting the document.
- **Don't rewrite a section you did not author** without saying so in `--message`.
- A `--draft` page is visible only to people who could edit the board — the right home for a
  half-written answer.
- **File it, don't nest it.** A parent page that exists only to hold other pages is a document
  about nothing. Make a folder instead; a folder is a place, and a place costs nothing.

Subcards: `slipdock card <id>` shows `Subcards: board #N · done/total · lists`; then use
`slipdock board N`, `slipdock add N ...` etc. on that board. Sub-boards share tags with their root board
and nest to any depth; `slipdock boards` lists root boards only.

Whose board it is: a board somebody else owns and has shared with you shows their name in the
OWNER column of `slipdock boards` — the column only appears when something in the listing is
shared, so your own boards never grow one. `--json` says it in full: `owner` ({id, email, name},
null on an unclaimed board predating accounts) and `shared` (true when the owner is somebody
other than you). `slipdock board <ref>` names the owner on a line of its own. Name the owner when
you report on a board that is not the user's — "#12 on Nadia's board" is a different sentence from
"#12 on your board".

Archived boards: `slipdock boards` leaves them out — `--archived` lists those alone, `--all` lists
everything, and an archived board shows `archived` in the STATE column. Archiving is not deleting:
every card, tag and comment is still there and every command still works on it. Treat it as a
strong signal all the same — **work on an archived board is work the user has set aside**, so ask
before picking any of it up, and put anything new on a board that is still in play.
The order `slipdock boards` comes back in is the token holder's own (`slipdock order-boards`); it is
per person, so changing it moves nobody else's index. `--sort` reads a different order without
disturbing theirs.

Values: priority `none|low|medium|high|critical`; colours `slate red orange amber lime emerald
teal sky indigo violet fuchsia rose`. Multi-word titles, column names and text need no quoting
(remaining words are joined), but quote them when they contain characters special to the shell.

## Examples

- "What's blocked?" → `slipdock cards 1 --open` and look for `🔒blocked-by:` (a real dependency on an
  open card), or `slipdock cards 1 --flag blocked` for the manual "blocked" flag.
- "#12 can't start until #7 is done" → `slipdock blocked-by 12 7`
- "Remind me to review invoices every Monday" → if the card exists, `slipdock repeat 12 "every mon"`;
  if not, add it first (`slipdock add ops Review invoices --column "To Do"`) and repeat the new id.
  A card still open when the next is due has its due date moved on (`--on-missed bump`) rather than
  a second made — say so if they'd rather have one per week (`--on-missed stack`).
- "#12 can wait until after the audit on 2 Nov" / "park this till next week" → `slipdock snooze 12
  2026-11-02 --note "after the audit"` (or `next week`). Snooze when the wait has a date; flag it
  `waiting` when it doesn't. Never pick a snoozed card to work on — it isn't ready until it wakes.
- "What's snoozed?" → `slipdock cards 1 --snoozed only`; `slipdock wake 12` brings one back.
- "Tidy this board up" / "what's rotting?" → `slipdock garden ops --run`, then show the user the
  suggestions and apply only the ones they say yes to (`slipdock garden apply 41 42`; a duplicate
  needs `--keep <the card that stays>`; `--choice snooze` takes an alternative). Dismiss only when
  they say no — a dismissal is remembered. `slipdock garden undo 41` puts an applied one back.
- "Break #12 into steps" → `slipdock templates`, `slipdock subboard 12 --template Simple`, then
  `slipdock add <sub-board-id> First step`
- "What's overdue?" → `slipdock cards 1 --open --json` and compare `due_date` with today.
- "Add 'Write changelog' to To Do, high priority, tag docs, due Friday" →
  `slipdock add 1 Write changelog --column "To Do" --priority high --tag docs --due 2026-10-03`
- "Move #12 to Done and mark it complete" → `slipdock move 12 Done && slipdock done 12`
- "Tick off the first checklist item on #7" → `slipdock card 7` (find item id) then `slipdock tick <item-id>`
- "Show me open work by tag and due week" → `slipdock swimlanes 1 --rows tag --cols due_date --unit week --open`
- "List everything due this month with its dependencies" → `slipdock table 1 --due month --fields id,title,due,deps`
- "Save that as a view called Roadmap" → `slipdock save-view 1 Roadmap --rows tag --cols due_date --unit week --open`
- "Email me whenever a card lands in Done" → `slipdock automation-help`, then
  `slipdock new-automation 1 --spec '{"trigger":{"type":"card_moved","to":"Done"},"actions":[{"type":"email","to":"me@example.com","subject":"Done: {{card.title}}","body":"{{card.url}}"}]}' --name "Email on done"`
- "Nudge me about anything overdue" →
  `slipdock new-automation 1 --spec '{"trigger":{"type":"card_overdue"},"actions":[{"type":"alert","title":"Overdue: {{card.title}}","severity":"urgent"}]}' --name "Overdue alerts"`
- "Have my laptop work cards that land in Doing" → `slipdock runner new 1 laptop --pool dev
  --agent claude --cwd ~/src/app --column Doing`, then give the user the printed steps (the
  token is in them and shown once)
- "What is the agent doing with #129?" → `slipdock jobs --card 129`, then `slipdock job <id>`
- "Stop that agent" → `slipdock cancel-job <id>`
- "Stop that rule for now" → `slipdock automations 1` (find it), then `slipdock set-automation 1 3 --off`
- "What is the board trying to tell me?" → `slipdock alerts`
- "Write up how retries work" → `slipdock page ls 1 --q retry` first, then
  `slipdock page new 1 Retry policy --body - --summary "How retries work" --message "first draft"`
  with the Markdown on stdin
- "What have we written down about deploys?" → `slipdock page ls 1 --q deploy`, then
  `slipdock page read W-31`
- "Where is everything we've written?" → `slipdock wiki`
- "Put the design notes in a Design folder" → `slipdock folder new 1 Design`, then
  `slipdock page file W-31 --folder Design`
- "Add today's note to the runbook" → `slipdock page read W-31` (note the hash), then
  `slipdock page edit W-31 --body - --base-hash <hash> --message "log: rolled back at 14:05"`
- "Who changed the runbook, and what did they change?" → `slipdock page history W-31`, then
  `slipdock page diff W-31 --rev N`
- "Put the errands board away" → `slipdock archive-board errands` (and `restore-board` to undo)
- "Which boards have I shelved?" → `slipdock boards --archived`

## Moving a board to another server

```
slipdock export --out boards.json             # every board tree you own, as one document
slipdock export qvm-v1-rem ops --out b.json   # just these; --archived includes what is put away
slipdock import boards.json                   # build the trees in it
```

One JSON file holding whole board trees: lists, cards and their subcards, tags, checklists,
comments, status updates, web links, custom fields and their values, dependencies, typed links,
and the wiki.

**Not the same as `page export`.** That writes Markdown, for reading the writing somewhere
else. This moves a board, and only this can be read back into one.

Three things to tell the user before running `import`, because they are surprising:

- **It never merges.** The file always becomes *new* boards, even when a board of that name is
  already there. Importing the same file twice gives two copies. A board code that is taken is
  reissued (`del` → `del-2`) and the output says so.
- **Automation rules do not fire.** An import is history arriving, not things happening.
- **The limits are answered for the whole file first.** A file that holds more cards and pages
  than the person has room for — or more boards, or that arrives after their trial has ended —
  is refused outright; nothing is part-built.

Left out of the file on purpose: attachments, votes, wiki page history, activity, and public
share links. The export prints how much of each it left behind. Page codes (`W-31`) are
reissued on import and `[[W-31]]` in the bodies is rewritten to match — but a bare `#412` typed
inside a page body still points at the old server's card id and cannot be fixed, so say so if
the user's pages do that.

**From Trello.** `slipdock import trello.json` also reads a Trello board's JSON export
(Trello: Menu → Print, export and share → Export as JSON), recognised by its shape;
`--from trello` says so outright. Lists, cards, labels (as tags), checklists, comments (with
who wrote them in the text), dates and attachments (as links) come across. Members do not —
Trello's export has no email addresses — so tell the user the cards arrive unassigned; archived
lists and custom fields stay behind too, and the output lists what did.

`slipdock export` only ever takes boards the user **owns**. A board merely shared with them is
somebody else's to hand on.

## Administering the server

`slipdock admin ...` changes who may use this server: the registration mode, the limits, the
free trial, who people can see, whether sharing makes accounts, the allowlist, people's admin
rights and the queue of people waiting to be let in. **Never run any of it unless the user has asked for
that specific change** — these decide who can reach their data.

It needs a token made with the **admin** scope, which is not the ordinary read/write one. If a
command answers `administering the server needs a token made with the admin scope`, say so and
ask for one; do not retry.

```
slipdock admin settings                     what this server allows, and who it tells
slipdock admin build                        the commit and build time now running
slipdock admin set signup_mode=closed       also free_card_limit, user_directory,
                                            invites_create_accounts, trial_days,
                                            trial_enabled, board_limit, item_limit,
                                            storage_limit_mb, and <name>_enabled=false
                                            to switch a limit off
                                            posthog_key=phc_... posthog_host=URL turn
                                            on PostHog analytics + error tracking;
                                            posthog_key= off
slipdock admin allow example.com            let an address or a whole domain register
slipdock admin disallow example.com
slipdock admin users                        who is here, what they use, when last seen
slipdock admin overview [--sort S]          usage: accounts, active/joined in 7 and 30
                                            days, and per person signed up, last active,
                                            boards, lists, cards, pages, files, storage
                                            (S: storage|cards|boards|lists|pages|files|
                                            last_active|signed_up|email)
slipdock admin add <email>                  a new account; invited by email when there is mail
slipdock admin email <email> <new-email>    change the address they sign in with (the old
                                            one is told)
slipdock admin close <email> --force        delete them and their work for good; prefer disable
slipdock admin promote|demote <email>       admin rights (never the last admin)
slipdock admin disable|enable <email>       reversible; ends their sessions at once
slipdock admin limit <email> <n|none>       an item limit of their own
slipdock admin paid <email> <date|none>     paid up to a date: takes them off the free
                                            allowance and off the trial clock
slipdock admin unlimited <email> on|off     off the free tier for good, with no date:
                                            for a named person, not a payment
slipdock admin signups                      who is waiting to be let in
slipdock admin approve|reject <email>
```

The limits are worth knowing before you set one. Each is counted against whoever **owns** the
root board, not whoever made the thing, so a guest working on somebody's board never costs
themselves anything. `free_card_limit` and `trial_days` are the free tier and apply only to
accounts with no paid-up date, that are not admins and not marked unlimited; `board_limit`,
`item_limit` and `storage_limit_mb` are ceilings on every account on every install — admins and
unlimited accounts included — and default to 1,000 boards, 250,000
items and 10 GB. Where two limits both apply, the lower wins.

Mail settings and the admin address are deliberately not here. Both have to prove something
first — a test message that arrived, a code sent to the new address — and they live in the web
UI under **Configuration**.

## Errors

Non-zero exit with `error: ...` on stderr. `could not reach ...` means the server is down, or
the address is wrong: check `slipdock url`, which says where it is pointing and why.
