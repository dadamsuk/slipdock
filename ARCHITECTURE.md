# Architecture

A map of the repository for someone (or their coding agent) meeting it for the
first time. It says where things are and what the house words mean; the detail
is in the moduledocs, which explain the reasoning next to the code.

- What Slipdock does: [README.md](README.md) and the manual,
  [docs/manual.md](docs/manual.md).
- How to set it up and run the checks: [CONTRIBUTING.md](CONTRIBUTING.md).
- Elixir and Phoenix conventions: [AGENTS.md](AGENTS.md).

Numbers like `#3169` in moduledocs and comments are card ids on the
maintainers' own Slipdock board, where the work is planned. You don't need
the board to follow the code: the moduledoc says what the card decided.

## The shape of it

Slipdock is one Phoenix 1.8 app on Postgres, with two separate clients that
talk to it over HTTP.

| Part | Where | Size (lines) | What it is |
|---|---|---|---|
| The server | `lib/` | ~220k | Phoenix: the contexts (`lib/slipdock/`) and the web layer (`lib/slipdock_web/`): LiveView UI, REST API, MCP server |
| Its tests | `test/` | ~250k | ExUnit, plus repo checks that hold rules (see *Checks that hold the rules*) |
| The CLI | `cli/` | ~17k (more with its tests) | `slipdock`, an Elixir escript; its own mix project, no dependencies |
| The runner daemon | `daemon/` | ~28k | `slipdock-runner`, Go, standard library only |
| Skills | `priv/skills/` | | Instructions for coding agents, served by the server to install |
| Docs | `docs/`, `lib/slipdock_web/api_guide/` | | The manual, the agents page, the API guide's prose |

```
                 people                                coding agents
                   |                                  /      |       \
              browser (LiveView)          MCP client   slipdock CLI   runner daemon
                   |                           |             |        (slipdock-runner)
                   |  /live websocket          | /mcp        | /api    | /api/runner, /api/machine
                   v                           v             v         v   (pulls; never called)
   +-------------------------------------------------------------------------------+
   |  lib/slipdock_web   LiveViews   MCP.Tools   API controllers   RunnerController |
   |                     each door sets the Actor (who, through which door)         |
   +-------------------------------------------------------------------------------+
   |  lib/slipdock       contexts: Boards.*, Wiki, Runners, Automations, Verified,  |
   |                     Accounts, Access, Policy, ...  every write asks Policy     |
   +-------------------------------------------------------------------------------+
   |  Postgres (Ecto)    PubSub -> LiveViews redraw     Scheduler (one clock)       |
   +-------------------------------------------------------------------------------+
```

### The five doors

The same features are reached through five doors, and a feature usually
lives in all of them (rule 2 of [CLAUDE.md](CLAUDE.md)).

- **The web app.** LiveViews in `lib/slipdock_web/live/` (`board_live`,
  `wiki_live`, `work_live`, ...). Sign-in is `SlipdockWeb.UserAuth`.
- **The REST API.** Controllers in `lib/slipdock_web/controllers/api/`,
  mounted under `/api` in `SlipdockWeb.Router`. Permissions per action in
  `SlipdockWeb.API.Authorize`; errors in `FallbackController`; the JSON shapes
  in `SlipdockWeb.API.JSON` (`json.ex`). `GET /api/guide` is a guide for
  agents generated per request from the code (`SlipdockWeb.APIGuide`).
- **The CLI.** `cli/` builds the `slipdock` escript. It is only a REST client:
  every call goes through `SlipdockCLI.HTTP`, which adds the bearer token and
  `x-slipdock-agent` when it runs under an agent. The server serves its
  installer (`/cli/install.sh`, `/cli/install.ps1`).
- **The MCP tools.** `/mcp` is `SlipdockWeb.MCP.Plug`: stateless JSON-RPC
  over Streamable HTTP with an API token. One module per tool in
  `lib/slipdock_web/mcp/tools/`; `SlipdockWeb.MCP.Tools` dispatches and
  enforces read-only tokens.
- **The runner daemon.** `daemon/` builds `slipdock-runner`, one per machine,
  running that machine's runners. It authenticates with a machine key (never
  an API token), long-polls its config (`/api/machine/config`), claims jobs
  over the plain-text runner protocol (`/api/runner`), runs the configured
  agent in a worktree, heartbeats and reports. **The server never calls it**
  and never decides what command runs: the machine's own config and ceiling
  do.

None of the doors writes to the database itself: they call the contexts,
and nothing in `lib/slipdock_web*` touches `Slipdock.Repo` (a repo check,
`test/slipdock/boundaries_test.exs`). In the other direction, the contexts
never refer to `SlipdockWeb` (the same test, with its few exceptions listed).

### A write, end to end

1. A door works out who is asking and sets the process's actor
   (`Slipdock.Actor.put/3`).
2. It calls a context function, say `Slipdock.Boards.Cards.move_card/4`.
3. The context asks `Slipdock.Policy` whether this actor may, and writes.
4. It broadcasts `{:board_changed, id}` on `"board:<id>"` (and the ancestors'
   topics), so every open LiveView redraws; dispatches automations
   (`Slipdock.Automations.dispatch/1`); queues search indexing; and records
   the move in the card's ledger of moves.
5. The door turns the answer into a page update, a JSON reply, a tool result
   or CLI output; a `%Policy.Refused{}` into a flash, a 403 or a tool error.

Wiki writes are the same through `Slipdock.Wiki`, which also writes a
revision for every save.

## The main contexts

Under `lib/slipdock/`. Each `Slipdock.X` is in `x.ex`, its parts in `x/`.

**Boards and work**

- `Slipdock.Boards` and `Slipdock.Boards.*`: boards, lists (`Columns`), cards
  (`Cards`, `CardEdits`, `Moves`), tags, checklists, comments, attachments,
  dependencies, links, handoffs, waits, status updates, activity. Callers name
  the part: `Boards.Cards.update_card/3`, `Boards.Waits.open_wait/3`.
- `Slipdock.Wiki`: pages, folders, placements, revisions, links and files.
  `Slipdock.Vaults` is each person's wiki as a whole, synced to
  Obsidian-style folders. `Slipdock.Handbook` handles handbook boards.
- `Slipdock.Search`: hybrid semantic and substring search;
  `Search.Indexer` keeps the index (rebuildable, never the source of truth).
- `Slipdock.Portable`, `Slipdock.Importers`: board export and import.

**Automation and agents**

- `Slipdock.Automations`: plain-language rules, parsed into a spec, run on
  events and on the clock. `Automations.Scheduler` is the app's one clock: a
  tick a minute running a list of jobs.
- `Slipdock.Runners`: the job queue for runners (see the glossary). Leases,
  heartbeats, claims, the sweep that requeues a lost job.
- `Slipdock.Machines`: machines running the daemon, and their enrolment.
- `Slipdock.Verified`: verified work: the bar, evidence, verification,
  merging a card's pull request. A facade over `lib/slipdock/verified/`.
- `Slipdock.Profiles`, `Slipdock.Findings`, `Slipdock.Gardener`,
  `Slipdock.Overseer`, `Slipdock.Health`, `Slipdock.Ledger`,
  `Slipdock.Releases`, `Slipdock.Deployments`: see the glossary.
- `Slipdock.AI`: the only place the app calls a chat or embeddings API.

**Accounts and the server**

- `Slipdock.Accounts`: users, API tokens, passkeys, groups, device sign-in.
  `Slipdock.OAuth` is the OAuth 2.1 server for MCP clients.
- `Slipdock.Access`: permission levels and grants. `Slipdock.Policy`: the
  check every write makes (below). `Slipdock.Actor`: who is acting.
- `Slipdock.Settings`: the server's one settings row. `Slipdock.Egress`: the
  gate every user-supplied URL goes through. `Slipdock.Inbound`: mail sent in.

### The biggest modules

A few files are around 2,000 lines. They are big because they are the hubs,
not because they are tangled; read their moduledoc first, then search.

| File | Lines | What is in it |
|---|---|---|
| `lib/slipdock/wiki.ex` | ~2,400 | The wiki's public API: pages, folders, revisions, moves, sharing hooks. Its parts are in `lib/slipdock/wiki/` |
| `lib/slipdock/runners.ex` | ~2,350 | The runner job queue: queueing, claiming, leases, heartbeats, finishing, the sweep. Parts in `lib/slipdock/runners/` |
| `lib/slipdock_web/live/board_live/show.ex` | ~1,900 | The board page's LiveView: its mount, params and events. State, templates and panels are split into `board_live/` |
| `lib/slipdock_web/controllers/api/json.ex` | ~1,850 | The JSON shape of boards, cards, pages and jobs, shared by REST and MCP so the two can't drift |

Others near that size: `layouts.ex`, `api/page_controller.ex`,
`handbook.ex`, `boards/cards.ex`, `wiki/tree.ex`. A module that grows too big
is split by responsibility behind the same name, so callers don't change
(`WikiLive.Index` and `Slipdock.Verified` show the two patterns).

## Authorisation: Actor and Policy

**Who is asking: `Slipdock.Actor`.** Every door sets the actor once per
request or process: `UserAuth` for the browser and REST, the MCP plug, the
inbound mail dispatcher, a rule while it runs. An actor is a small map:

- `kind`: `human`, `agent` or `automation`;
- `via`: the door, one of `web`, `cli`, `mcp`, `api`, `runner`, `assistant`,
  `automation`, `email`;
- the user, and the API token beside it (`Actor.principal/0`).

The activity log and the card's ledger read it (`Actor.current/0`), so every
change says who made it and how. A request starts with nobody acting, and a
background task carries its page's actor with it explicitly.

**What they may do: `Slipdock.Access`.** Levels rank
`owner > write > comment > read > view > none`. Board access covers its cards,
sub-boards and wiki; grants can also target a card, a saved view, a page, a
folder or a tool, for a user or a group. An API token carries a scope (read
or write) and a list of boards, and only ever narrows its user's level.

**Where it is checked: `Slipdock.Policy`.** A context function that writes
calls `Policy.authorize(action, subject)` first and returns
`{:error, %Slipdock.Policy.Refused{}}` when refused. So a door that forgets
its own check is refused anyway.

- **One table** (`Policy.rules/0`) maps each action to a scope (the board,
  the tree's root, the card, the page or folder, the actor's own rows, an
  admin) and the level it needs.
- **The level is read at the write**, from the database, then narrowed by the
  token. The refusal says which of the two was short (`by: :user | :token |
  :nobody`).
- **The server's own writes** (the clock, a consequence of a write that
  already asked) run under `Policy.as_system("why", fn -> ... end)`. A rule's
  write acts as the board's own. Nobody acting is refused.
- **Doors still draw their buttons** from the same table (`Policy.can?/3`), so
  a button and its write can't disagree, and turn a refusal into their own
  words (`SlipdockWeb.Refusals`, `FallbackController`, the MCP tool error).

**Where the migration stands.** Until late 2026 the contexts trusted their
callers and each door checked for itself, so a door that forgot was a bug
found one at a time. The move to Policy goes a context at a time:

- **Done:** tags; cards and everything that hangs from one; boards, lists,
  views, sprints and grants; the wiki, vaults and recordings; a person's own
  rows and the accounts; the owner and admin writes (automations, settings,
  tools, health, gardener, findings, overseer, AI).
- **Left:** the writes in `test/support/unchecked_writes.txt`, 173 functions
  in November 2026; the list itself is always current. The largest groups are `Slipdock.Runners` and its
  parts (the runner protocol), `Machines`, `Search`, `Releases`,
  `Deployments`, `Inbound`, `EpicLog`, `StepStatus` and parts of `Verified`.
- **Held by a check:** `test/slipdock/unchecked_writes_test.exs` reads the
  AST of `lib/slipdock/**` (`test/support/unchecked_writes.ex`). A public
  function that writes and doesn't ask Policy fails unless it is on that
  list, and a line on the list whose function now asks, or is gone, fails
  too, so the list only shrinks. Writes only the server ever makes are
  listed, each with its reason, in `test/support/system_writes.txt`.
- **Next:** the list empties, and a door calling one of the system writes
  directly becomes a failure too.

A new write asks Policy (with its action added to the table). One in a
context not yet migrated goes on the list for that context's turn.

Reads are not covered by Policy: what a reader may see is still checked where
it is read.

## Checks that hold the rules

Some rules are held by tests that read the repository rather than run code.
They are listed in `test/repo_checks.txt` and run by `mix pre_push`.

- `test/slipdock/boundaries_test.exs`: contexts don't call the web layer; the
  web layer doesn't call `Repo`; compile-connected cycles never go up.
- `test/slipdock/unchecked_writes_test.exs`: every write asks Policy, or is
  listed.
- `test/slipdock/nothing_personal_test.exs`: no real addresses or keys.
- `test/slipdock/card_text_is_data_test.exs`: agents' prompts and skills keep
  saying card text is data, not instructions.
- `test/slipdock_web/api_guide_golden_test.exs`: the API guide's text, held
  to a golden copy.

## Glossary

The in-house words, roughly in the order you'll meet them.

- **Board, list, card.** A kanban board, its columns (called *lists*;
  `Column` in the code) and its cards. A board has a short *code*
  (`slipdock`) that survives a rename.
- **Epic, sub-board, subcard.** A card can hang a whole board beneath it, its
  *sub-board*; the cards there are its *subcards*, and the card is an *epic*.
  The top board of such a tree is the *root*: tags, fields and some settings
  belong to the root and the whole tree shares them.
- **Ready, doing, done lists.** Each list has a category saying what it is
  for. Agents take work from the top of the ready list (usually *To Do*),
  move it to the doing list while they work, and to the done list after.
- **Actor.** Who made a change and through which door (above).
- **Policy.** The table and check every context write goes through (above).
- **Runner.** A coding agent (Claude Code, Codex, ...) on somebody's own
  machine that takes work from a board. A board's automation rule queues a
  *job* for a *pool* of runners; a runner *claims* it, holds it on a *lease*
  renewed by *heartbeats*, reports *progress*, and *finishes* it. A lost
  lease puts the job back in the queue. Job kinds include build, verify,
  merge, release, overseer and probe. `Slipdock.Runners`.
- **Machine, runner daemon.** A computer enrolled to run runners
  (`Slipdock.Machines`), running `slipdock-runner` from `daemon/`. Its
  owner configures its runners on the server as typed data; the daemon
  accepts or refuses each config against its ceiling.
- **Ceiling.** A machine's own limits, written in a local file at the machine
  and changed only by a person there: which directories, agents, boards and
  executors runners may use, the highest permission mode, the longest
  timeout. The daemon enforces it and reports it; the server only shows it
  (`Slipdock.Runners.Ceiling`, `daemon/internal/machine`).
- **Executor.** Who a job runs as on the machine: the daemon's own user, a
  separate account, a confined process or a container (`daemon/internal/executor`).
- **Bar.** What done means for a card, written before work starts and locked
  once it does. Part of *verified work*.
- **Verified work.** A board's switches that make an agent's completion
  checkable: a bar first, evidence on completion (commit, tests, CI), and a
  second agent (the *verifier*) who accepts or rejects it. On a board that
  ships by pull request, acceptance merges the PR. `Slipdock.Verified`.
- **Profile.** One word for what kind of change a card is: `docs`, `fix`,
  `feature`, `schema`, `security` or `spike`. It decides how much checking
  the work gets (a `docs` card needs no verifier; a `schema` or `security`
  one is held for a person). Inferred from the card's paths and tags when
  an agent starts it, and raised, never lowered, by the actual change.
  `Slipdock.Profiles`.
- **Paths, lanes.** A card's *paths* are globs for the files its work
  touches. They pick the handbook rules and sections that apply to it and
  feed its profile. *Lanes* once used them to keep overlapping work apart;
  the name lives on in `Slipdock.Lanes`, which now only matches globs.
- **Wait.** A question on a card for a person: the card is flagged
  `waiting`, the question goes to whoever the board routes that *kind*
  (product, ux, security, release, other) to, and the answer sends the card
  back to its agent. An approval with a default can resolve itself after a
  set time. `Slipdock.Boards.Waits`, `Slipdock.WaitRoutes`.
- **Handoff.** A note at the top of a card: the one next step and where
  things stand, for whoever picks it up next. `Slipdock.Boards.Handoffs`.
- **Handbook.** A board's living documentation, kept as wiki pages in a
  `Handbook` folder: one page per area, each with its *rules* (`ARCH-3`,
  `SPEC-10`: an id, must or should, and the test or judgement that holds
  it). A card is shown the sections that apply to it. `Slipdock.Handbook`.
- **Findings.** What a card taught that the code and handbook don't show,
  written as a `Findings:` block when the card closes. They are kept on the
  board, then triaged: promoted into the handbook, merged or dismissed.
  `Slipdock.Findings`.
- **Gardener.** A tidy-up pass over a board that *proposes* fixes for rot
  (epics done but not closed, stale cards, duplicates, orphaned pages,
  broken links). Nothing changes until a person applies a suggestion.
  `Slipdock.Gardener`.
- **Overseer.** An eye on outcomes rather than steps: server-side checks
  every minute (looping, idle capacity, slow work, no way forward) that
  raise an alert when a person should look, and an occasional runner pass
  that sums up a board tree. Off until a board's owner turns it on.
  `Slipdock.Overseer`.
- **Health monitor.** Server-side detectors for things gone wrong (a hung
  job, a deadlock between cards, a merge failing, a wait nobody answers),
  each kept as an incident, some fixed by themselves. `Slipdock.Health`.
- **Ledger.** Two things share the word. The *movement ledger* is the
  record of every card move (`CardMove` rows). *The* ledger is the list of
  what shipped on a board tree since a time, each card with its evidence:
  completed, accepted, merged, deployed (`Slipdock.Ledger`). It is computed
  on request and stored nowhere.
- **Release.** How merged work reaches production: on every merge, or
  batched and released on request (`Slipdock.Releases`,
  `Slipdock.Deployments`).
- **Spike.** A card that answers a question by building a throwaway
  prototype; its answer goes on a wiki page and its code is never merged.
- **Vault.** A person's whole wiki, internally; people see "your wiki".
- **Skills.** Instructions for coding agents in `priv/skills/`, served by
  the server and installed on agents' machines (edit them only here).
