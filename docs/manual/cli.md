[Slipdock — the manual](../manual.md)

## CLI

`cli/` is a zero-dependency escript that wraps the API.

**Every command, on the web.** Help → Agents → CLI links to the **command
reference** (`/help/agents/cli/reference`, readable signed out): every command
in `slipdock help`, one section per group of the help in its order (Start here,
Find anything, Auth, Admin, Read, … Values, Output), each with an anchor, a
contents list at the top, and a box that filters the commands by name. It is
made when the server is built from `cli/help.txt`, the same file `slipdock help`
prints, so the two can't disagree: a change to the CLI's help is a change to
that file, and the page follows it. On a phone a long command wraps between its
options, and its option list scrolls inside its own box.

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
slipdock guide             # the server's instructions for agents, short: it ends
                         # with its other sections (`guide wiki`, `guide all`)
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
slipdock page file W-31 --also Ideas [--board B]   # also filed there too (or a /wiki/path); --not-in F takes it out
slipdock folder file qvm-v1-rem Design --also Ideas --also /Projects/Notes   # a folder too, all in it; --not-in F
slipdock folder show qvm-v1-rem Design          # its path, and where else it is filed
slipdock wiki                                       # every board's folders and pages
slipdock wiki show                                  # your wiki: its boards, pages, keys, synced folders
slipdock wiki set --shortcut nt --hotkey 2 --recordings-folder "Meeting Recordings"
slipdock wiki locate /Projects/Acme.md              # which board a path lands in, and the rest
slipdock wiki resolve X/Dup | slipdock wiki wanted  # links across your whole wiki
slipdock wiki changes [--since 812]            # what changed after a cursor: what sync polls
slipdock wiki tree [--short-names]             # every folder and file by name
slipdock wiki import ~/Obsidian [--dry-run]    # an Obsidian vault in, once
slipdock names [full|short]                    # Names in trees and lists: says or sets it
slipdock page tags brain | slipdock page ls brain --note-tag area   # notes' own #tags
slipdock page props W-31 [--file F | --clear] [--message M]  # the front matter its file came with, kept exactly
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
slipdock page edit W-31 --tag ops --tag urgent   # the board's tags (--tag T --off, --set-tag T replaces, --no-tags clears)
slipdock comment W-31 "needs a worked example"  # comment, check, status, vote, weblink and
slipdock check W-31 "worked example"           # unweblink all take a page code as readily
slipdock move-check 13 --before 11              # checklist item 13 before item 11 (no --before: last)
slipdock status W-31 at_risk "stalled on SRE"  # as a card number
slipdock handoff 12 --next "Write the test" --body "State: …"   # where a card was left
slipdock comment 12 --body - < note.md        # a Markdown comment over several lines (or --file F)
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
slipdock tools show job-search                # its board, skills, files and versions
slipdock tools publish ./my-tool              # pack a folder and publish it as a new version
slipdock tools install job-search             # its skills into ~/.claude/skills (--dir D)
slipdock tools check                          # are the installed Tool skills behind?
slipdock tools install-board job-search       # have the server build its board (--name, --version)
slipdock tools request-listing my-tool        # ask an admin to list a version for everyone
slipdock tools file job-search skills/job-search-scan/SKILL.md   # one file of the package, latest version
slipdock tools download job-search            # the whole package as job-search-<version>.tar.gz (--out F|-, --version)
slipdock wiki files jobs --folder Tool        # a board's wiki files that are not pages
slipdock wiki get jobs Tool/cv.docx           # one of them, saved here (--out F, or - for stdout)
slipdock favourites                            # what you keep going back to, with the URL of each
slipdock fav list qvm-v1-rem "In Progress"     # also: fav card 42 | fav view <board> <view> | fav board <board> | fav page W-31
slipdock hotkey slipdock 1                     # Ctrl+Shift+1 opens it in the web app; `slipdock hotkeys` lists yours
slipdock card-views                            # your named card views (--elements: every element and its default)
slipdock card-view set --board slipdock --hide comments,attachments   # a level; --list L for one list, neither for global
slipdock card-view set --board slipdock --apply Calm --show-all off   # apply a named view (none for no view)
slipdock card-view applied --board slipdock --list Done   # what a card there shows, and which level decided it
slipdock unfav list qvm-v1-rem "In Progress"   # or `fav ... --off`
```

---

← [JSON API](json-api.md) · [Contents](../manual.md) · [Tools](tools.md) →
