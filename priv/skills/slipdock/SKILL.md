---
name: slipdock
description: Read and write cards on the user's self-hosted Slipdock boards with the `slipdock` CLI. Use whenever the user mentions their kanban or Slipdock board, cards, lists/columns, tags, flags, or asks to add, move, complete, flag, tag, check off, comment on, archive, or look up tasks/cards. Also use to summarise what is on a board, what is overdue, blocked, or in progress, to set up or inspect board automations (rules that email, move, flag or alert by themselves) and the alerts they raise, and to read or write the wiki pages, docs, runbooks, specs and decision notes kept on a board.
---

# Slipdock CLI

The `slipdock` command talks to the user's Slipdock app (Phoenix LiveView, served over Tailscale).
Every write shows up live in the web UI. Run `slipdock --help` for the full reference.

**If you are about to work *from* the board — pick up the next task, work through an epic, keep
cards updated while doing the work — run `slipdock guide` first** (the server's own instructions
for agents: epics and subcards, how to choose the next card, what to write back) and follow it.
This file is the command reference; the guide is the workflow.

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

- `card_limit_reached` (HTTP 402) — the board owner's account has used all the cards it allows.
  A different title will not help; it will fail identically, forever. Suggest archiving
  something finished with. `slipdock whoami --json` and `slipdock guide` both say how much of
  the allowance is left, so you can check before starting a batch rather than discovering the
  wall halfway through.
- `No account here uses that address…` when sharing — this server does not make accounts for
  the people you share things with. An admin has to invite them.

On a server where people see only those they share something with, somebody you expect to find
and cannot has probably not been shared anything. They have not been deleted, and assigning a
card to them will not work until something is.

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
slipdock swimlanes <board> [view options]   # grid of cards grouped on two axes (see below)
slipdock table <board> [view options] [--group A] [--fields id,title,column,priority,flags,tags,start,due,completed,percent,checklist,comments,deps,subcards,created,updated]
slipdock views <board>                      # saved swimlane views
slipdock favourites                         # what this person keeps going back to, with a URL each
slipdock search <words...> [--board B] [--limit N] [--archived] [--full]
slipdock ask <question...>                  # the assistant searches for itself, then answers
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
`--assignee me` your own. They mean the same thing here, in the swimlane views and in the API,
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
slipdock add <board> <title words...> [--column C] [--desc TEXT] [--priority P] [--flag F]... [--tag T]... [--start YYYY-MM-DD] [--due YYYY-MM-DD] [--color C] [--percent N]
slipdock edit <id> [--title T] [--desc TEXT] [--priority P] [--start DATE|--no-start] [--due DATE|--no-due] [--percent N|--no-percent] [--color C|--no-color] [--column C]
slipdock move <id> <column> [--top|--bottom|--index N]
slipdock move <id> <column> --board B    # to another board, with the card's subcards; tags travel
                                       # by name, custom fields only where that board has them;
                                       # the command prints anything that was created or dropped
slipdock done <id>... | slipdock undone <id>...
slipdock flag <id> <flag>... [--off]     # flags: flagged blocked review waiting starred
slipdock tag <id> <tag>... [--off]       # tag must already exist on the board (see new-tag)
slipdock check <id> <text...>            # add checklist item
slipdock tick <item-id>                  # toggle checklist item (ids from `slipdock card`)
slipdock comment <id> <text...>
slipdock weblink <id> <url> [--label TEXT]   # link a card to a web page, shared drive or file (datestamped)
slipdock unweblink <id> <url-id>...          # ids from `slipdock card`
slipdock blocked-by <id> <card-id>... [--off]   # <id> waits for those cards (dependency)
slipdock blocks <id> <card-id>... [--off]       # <id> holds those cards up
slipdock archive <id>... | slipdock restore <id>... | slipdock delete <id>...
slipdock new-board <name> [--code C] [--shortcut K] [--desc TEXT] [--color C]
slipdock set-board <board> [--name N] [--code C] [--shortcut K] [--desc TEXT] [--color C]
slipdock archive-board <board> | slipdock restore-board <board>   # owner only; ask first
slipdock order-boards <board>...        # the order you list boards in (yours alone)
slipdock new-column <board> <name> [--wip N] [--color C]
slipdock new-tag <board> <name> [--color C]
slipdock new-board <name> [--code C] [--shortcut K] [--desc TEXT] [--color C] [--template T]
slipdock templates                                        # sets of lists for new boards / subcards
slipdock new-template <name> [--desc TEXT] --list "Name[:wip[:color]]"... | slipdock delete-template <t>
slipdock subboard <card-id> --template T                  # card becomes a board of subcards (prints its id)
slipdock subboard <card-id> --off                         # remove the subcards
slipdock fav card <id> | fav list <board> <column> | fav view <board> <view> | fav board <board>
slipdock unfav <same args>                                # or `fav ... --off`
```

Favourites are **personal** — the token holder's own, never anyone else's, and favouriting
something changes nothing about it (read access is enough). **Don't favourite on the user's
behalf unless they asked**; it is their shortlist, not a place to file your working set.

Automations — rules the server runs by itself, long after you have gone:
```
slipdock automations <board>                  # every rule, with its trigger and how often it has run
slipdock automation <board> <rule>            # one rule in full, spec included (id or name)
slipdock automation-help                      # the triggers, conditions and actions a spec may use
slipdock new-automation <board> --spec JSON [--name N] [--tree]   # exact; --spec - reads stdin
slipdock new-automation <board> <description...>                  # the server's AI writes the spec
slipdock set-automation <board> <rule> [--on|--off] [--name N] [--spec JSON] [--text "..."]
slipdock run-automation <board> <rule>        # run a timed rule now (forgets what it has done)
slipdock delete-automation <board> <rule>
slipdock alerts                               # what the rules want you to know
slipdock dismiss <alert-id>... | --all        # dismiss yours; other people keep theirs
```

**Run `slipdock automation-help` before writing a `--spec`** — it prints the exact vocabulary
(triggers, condition fields and ops, actions, `{{placeholders}}`) with a worked example.
Prefer `--spec` to a plain-English description: you know the vocabulary, and a spec is stored
exactly as written, while a description goes through a language model that can misread you.
A rule with an unknown trigger or action is refused with the reason, so anything that saves runs.

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
slipdock page history <page> [--limit N] | slipdock page diff <page> [--rev N] | slipdock page revert <page> --rev N
```

Folders are where a page is *kept*, as opposed to `--parent`, which is what it is *part of*:
```
slipdock wiki                                 # every board's wiki at once, folders and all
slipdock folder ls <board>                    # one board's filing, pages and all
slipdock folder new <board> "Design/Decisions"    # a path makes every level
slipdock folder mv <board> <folder> [--name N] [--parent F | --root]
slipdock folder rm <board> <folder>           # the folder only: nothing filed in it is deleted
slipdock page file <page> --folder F | --no-folder
slipdock page new <board> <title...> --folder F   # or file it as you write it
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

## Administering the server

`slipdock admin ...` changes who may use this server: the registration mode, the card limit,
who people can see, whether sharing makes accounts, the allowlist, people's admin rights and
the queue of people waiting to be let in. **Never run any of it unless the user has asked for
that specific change** — these decide who can reach their data.

It needs a token made with the **admin** scope, which is not the ordinary read/write one. If a
command answers `administering the server needs a token made with the admin scope`, say so and
ask for one; do not retry.

```
slipdock admin settings                     what this server allows, and who it tells
slipdock admin set signup_mode=closed       also free_card_limit, user_directory,
                                            invites_create_accounts
slipdock admin allow example.com            let an address or a whole domain register
slipdock admin disallow example.com
slipdock admin users                        who is here, what they use, when last seen
slipdock admin promote|demote <email>       admin rights (never the last admin)
slipdock admin disable|enable <email>       reversible; ends their sessions at once
slipdock admin limit <email> <n|none>       a card limit of their own
slipdock admin signups                      who is waiting to be let in
slipdock admin approve|reject <email>
```

Mail settings and the admin address are deliberately not here. Both have to prove something
first — a test message that arrived, a code sent to the new address — and they live in the web
UI under **Admin**.

## Errors

Non-zero exit with `error: ...` on stderr. `could not reach ...` means the server is down or
`SLIPDOCK_URL` is wrong (default: this machine's Tailscale IP, port 4000).
