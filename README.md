<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="brand/lockup-reversed.svg">
    <img src="brand/lockup-horizontal.svg" alt="Slipdock" width="340">
  </picture>
</p>

<p align="center">
  <a href="https://github.com/dadamsuk/slipdock/actions/workflows/ci.yml"><img src="https://github.com/dadamsuk/slipdock/actions/workflows/ci.yml/badge.svg" alt="Tests"></a>
  <a href="https://github.com/dadamsuk/slipdock/actions/workflows/release.yml"><img src="https://github.com/dadamsuk/slipdock/actions/workflows/release.yml/badge.svg" alt="Image"></a>
  <a href="https://github.com/dadamsuk/slipdock/pkgs/container/slipdock"><img src="https://img.shields.io/badge/ghcr.io-dadamsuk%2Fslipdock-blue?logo=docker&logoColor=white" alt="ghcr.io/dadamsuk/slipdock"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/licence-AGPL--3.0-green" alt="AGPL-3.0"></a>
</p>

Slipdock is one place for all of a team's work. For anyone, it's a kanban
board, a wiki and a roadmap. For a software team, it's also where people and
coding agents work side by side: agents take cards, prove what they did and
check each other's work, and what each card teaches is written down where the
next card will read it. Self-host it for free or use the
[hosted version](https://slipdock.us). Both do the same things.

![A board](docs/screenshots/board.png)

### A good board, whatever the work

You don't need to write software, or use AI, to get a lot out of it. It was
built from experience of hundreds of projects to replace Jira, Jira Product
Discovery, Atlas's stakeholder updates and Confluence, with none of the fluff.

- **Any card can become a board of its own**, so an epic and its tasks live
  in one place and roll up. The same cards can be read as a board, a swimlane
  grid, a table, a Gantt timeline, a calendar, an outline or a ranked backlog,
  and [one setting](docs/manual/simple-boards.md) turns a board into a plain
  to-do list.
- **A wiki on every board**, so the documentation and the reasoning sit
  beside the work.
- **Automations in plain English**: "flag any card that is more than 3 days
  overdue as urgent and email John". You can give it commands ("split this
  card into 3 subcards") and ask it questions ("across all my boards, which
  of my tasks will take less than a day?"). Its semantic search finds "the
  card about the invoicing bug that came in last week" even when the card
  never says *invoice*.
- **Sprints, roadmaps, recurring cards, time tracking, email in, a phone
  layout** and the rest are in [the full list](#what-it-does).

### For a software team, one place for all the work

The cards a runner is building sit on the same boards as the reviews the team
owes, a design question for the product owner and last night's incident.

- **[Waiting on you](docs/manual/waiting-on-a-person-waits.md)** shows each
  person what needs them across every board: the questions agents asked, cards
  to review, runner trouble, and work in progress that nobody is on.
- **Questions go to the person whose call it is.** An agent that needs a
  decision opens a wait and stops. The board routes it by kind (product, UX,
  security, release) and suggests an answer, so replying can take one click.
- **[Where it was left](docs/manual/where-it-was-left-handoffs.md):** every
  card carries its next step and a short note, so whoever picks it up next,
  person or agent, reads that instead of the whole comment thread.
- **Every door is open.** Anything you can do in the browser you can also do
  over the [JSON API](docs/manual/json-api.md), the
  [CLI](docs/manual/cli.md) and the [MCP server](docs/manual/mcp-server.md).
  That means you can talk to Claude, Claude Code or ChatGPT about your work,
  and they can work the board the same way a person does.

### A dev harness that learns

Each part is optional, and a board turns on only the ones it wants.
Together, they make a loop:

1. **Plan.** Ask an agent to plan something and it sizes the request, writes
   the decisions and principles into the board's
   [handbook](#tools), and makes cards, each with a bar that says what done
   means.
2. **Build.** [Runners](#run-an-agent-against-a-board) on your own machines
   pull jobs, so there are no ports to open. They work a list from the top,
   and each job gets its own [lane](docs/manual/lanes.md) and worktree so
   parallel agents stay out of each other's files. A question parks the job
   and the next card runs.
3. **Prove.** The agent completes the card with
   [evidence](docs/manual/verified-work.md), and a second agent accepts or
   rejects it. Work can ship by pull request. A card's
   [profile](docs/manual/profiles.md) (security, schema, feature, fix, docs or
   spike) decides which changes wait for a person before they merge.
4. **Record.** Merging completes the card. Deploys feed
   [DORA metrics](docs/manual/delivery-metrics-deploys-and-dora.md), and the
   [ledger](docs/manual/the-ledger.md) shows what shipped since yesterday,
   who accepted it and what it cost. An
   [incident](docs/manual/incidents.md) names the card that caused it and the
   check that should have caught it.
5. **Learn.** Each pass leaves [findings](docs/manual/findings.md), and the
   server records rejections, timeouts and failed merges by itself. A daily
   triage promotes findings into the handbook or drafts them into rules when
   they recur. Before the next card starts, it's given the handbook sections
   and rules that cover its files. The memory lives on the board, not in one
   agent's head, so every runner, verifier and machine learns it.
6. **Watch.** The [health monitor](docs/manual/the-health-monitor.md) fixes
   stuck work where a safe fix exists. The [overseer](docs/manual/the-overseer.md)
   checks outcomes, such as work going round in circles, idle runners beside
   a full list or a board waiting only on you, and tells you why and what to
   do. [Right now](docs/manual/right-now.md) shows every runner and what it is
   doing.

Slipdock is built this way itself, on its own board.

## A word on AI coding...

Of course it was built using AI. But it wasn't vibe coded in an hour. First it was born of 30+ years of experience of managing projects and writing software. Second it was planned out and carefully constructed with robust testing and verification.  And third it has been security reviewed by multiple different coding agents. 

> A plan is falsework: the structure that holds the thing up while it is being built, and comes away when it stands on its own. This is somewhere to put it.

Built with Phoenix LiveView, so every browser looking at a board updates the
moment anything changes.

## A look around

| | |
|---|---|
| ![A card](docs/screenshots/card.png) **A card** — flags, tags, checklist, dependencies, roll-up health, status updates | ![The outline](docs/screenshots/outline.png) **Outline** — the board as a tree, subcards and all |
| ![Swimlanes](docs/screenshots/swimlanes.png) **Swimlanes** — any attribute on either axis | ![Timeline](docs/screenshots/timeline.png) **Timeline** — Gantt bars, dependency lines, draggable |
| ![Prioritise](docs/screenshots/prioritise.png) **Prioritise** — RICE, ICE and votes, edited in place | ![The wiki](docs/screenshots/wiki.png) **Wiki** — Markdown pages on the board, with revisions |
| ![Automations](docs/screenshots/automations.png) **Automations** — a sentence becomes a rule | ![My work](docs/screenshots/work.png) **My work** — everything assigned to you, across every board |

There are more in [docs/screenshots](docs/screenshots), the phone layout
included. They are taken from a demo workspace anybody can rebuild —
`tools/screenshots.sh` makes a throwaway database, fills it with
`mix slipdock.demo`, runs a server of its own and photographs it.

## What it does

Each line is a page of [the manual](docs/manual.md), which has the detail.
[Every feature in brief](docs/manual/every-feature-in-brief.md) is the long
list, a paragraph for each.

**Boards and cards**

- [Boards, lists and cards](docs/manual/features.md): drag and drop,
  priorities, flags, due dates, tags, checklists, comments with `@mentions`,
  attachments and recordings.
- [Subcards](docs/manual/subcards-and-templates.md): any card becomes a board
  of its own, as deep as the work goes, and
  [rolls up](docs/manual/roll-ups-the-outline-and-my-work.md) to its parent.
- Seven views of the same cards: board,
  [swimlanes](docs/manual/swimlanes.md), [table](docs/manual/table.md),
  [timeline](docs/manual/timeline.md), [calendar](docs/manual/calendar.md),
  [outline](docs/manual/roll-ups-the-outline-and-my-work.md) and
  [prioritise](docs/manual/prioritise.md), with filters and saved views.
- [Card views](docs/manual/card-views.md) choose what you see of a card, and
  [simple boards](docs/manual/simple-boards.md) hide everything but a to-do
  list.
- [Recurring cards](docs/manual/recurring-cards.md),
  [snoozing](docs/manual/snoozing-cards.md),
  [time tracking](docs/manual/time-tracking.md) and
  [dependencies](docs/manual/dependencies.md).
- [Quick add](docs/manual/quick-add.md) in plain English, and
  [email in](docs/manual/emailing-your-board.md): forward a message and it is
  a card or a wiki page.

**Planning**

- [Sprints](docs/manual/sprints.md) with a planning view, burndown and
  velocity.
- [Roadmapping](docs/manual/roadmapping.md): horizons, milestones and goals,
  with [custom fields, RICE and ICE scores and
  votes](docs/manual/custom-fields-scoring-and-votes.md).
- [The pulse](docs/manual/flow-the-pulse-a-cards-state-and-its-age.md) and
  [Visualise](docs/manual/visualise-flow-velocity-runners-and-delivery.md):
  cumulative flow, cycle time, aging work and how the runners are doing.
- [Narrative](docs/manual/narrative.md) tells you what happened to a set of
  cards over a date range.

**The wiki**

- [Markdown pages in folders](docs/manual/wiki.md) on every board, with
  `[[links]]`, backlinks, live card chips and queries, revisions, templates
  and public links.
- [Your wiki](docs/manual/wiki.md#your-wiki) gathers every board's pages
  beside a Knowledge Base of your own, and
  [syncs both ways to a folder](docs/manual/wiki.md#syncing-your-wiki-to-a-folder)
  that Obsidian can open.
- [Drawings](docs/manual/wiki.md#drawings),
  [encrypted notes](docs/manual/wiki.md#encrypted-notes),
  [quick notes](docs/manual/quick-notes.md) and
  [meeting pages](docs/manual/wiki.md#meeting-recordings-from-google-drive)
  that play a recording in step with its transcript.

**Automations and AI**

- [Automations](docs/manual/automations-and-alerts.md): a sentence becomes a
  rule that the app then runs, with alerts and webhooks.
- [Search by meaning, and Ask](docs/manual/deep-search-and-ask.md): questions
  in prose over every board at once.
- [The AI assistant](docs/manual/ai-assistant.md) chats about a board and
  proposes edits you approve. It runs on your own key or on
  [a model on your own hardware](docs/manual/running.md#a-local-model-instead).
  With neither there are no AI features, and nothing is sent anywhere.

**Working with agents**

- [Handoffs](docs/manual/where-it-was-left-handoffs.md) and
  [waits](docs/manual/waiting-on-a-person-waits.md): where each card was
  left, and what it needs from a person.
- [Runners](docs/manual/runners.md) on your own
  [machines](docs/manual/machines.md) take cards from a list, each in its own
  [lane](docs/manual/lanes.md).
- [Verified work](docs/manual/verified-work.md): a bar, evidence, a second
  agent's verdict, shipping by pull request and
  [releases in batches](docs/manual/batched-releases.md), with
  [profiles](docs/manual/profiles.md) deciding what waits for a person.
- [Findings](docs/manual/findings.md), [the ledger](docs/manual/the-ledger.md),
  [incidents](docs/manual/incidents.md) and
  [DORA metrics](docs/manual/delivery-metrics-deploys-and-dora.md) record what
  shipped and what it taught.
- [The health monitor](docs/manual/the-health-monitor.md),
  [the overseer](docs/manual/the-overseer.md),
  [Right now](docs/manual/right-now.md) and
  [tidying up](docs/manual/tidying-up.md) keep the board honest.

**Everywhere, for everyone**

- [A keyboard shortcut for most things](docs/manual/keyboard.md), and
  [a phone layout](docs/manual/on-a-phone.md) that pages rather than scrolls
  sideways.
- [Accounts and sharing](docs/manual/accounts-and-sharing.md): passwordless
  sign-in, groups, and read-only, comment-only or editable access to a board,
  a card, a page or a view.
- [Boards that can leave](docs/manual/moving-boards-between-servers.md): a
  whole board as one JSON file another Slipdock reads back, and Trello boards
  in.
- A [JSON API](docs/manual/json-api.md), a [CLI](docs/manual/cli.md), an
  [MCP server](docs/manual/mcp-server.md) and
  [agent skills](docs/manual/skills.md) the server ships.
- A **Getting Started** board [explains the app](docs/manual/getting-started.md)
  with cards of its own, and `/help` in the app is readable without an
  account.

## Running it

### With Docker

You need Docker with the Compose plugin (`docker compose version` prints v2 or
newer). There is nothing to clone or compile: the image is published.

```sh
mkdir slipdock && cd slipdock
curl -O https://raw.githubusercontent.com/dadamsuk/slipdock/main/compose.yaml
curl -O https://raw.githubusercontent.com/dadamsuk/slipdock/main/setup.sh
sh setup.sh              # five questions, then it writes a .env
docker compose up -d
```

On Windows, fetch `setup.ps1` instead and run it with
`powershell -ExecutionPolicy Bypass -File setup.ps1`.

Open the address you gave it. A server nobody has claimed shows a setup
wizard, which asks for a token printed in the log on first boot:

```sh
docker compose logs slipdock | grep -A4 "has not been set up"
```

Until a mail server is configured, sign-in codes go to the log too
(`docker compose logs slipdock | grep "Sign-in"`).

After changing `.env`, run `docker compose up -d` again, not
`docker compose restart`, which re-reads nothing. To upgrade, read
[UPGRADING.md](UPGRADING.md), then `docker compose pull && docker compose up -d`.
The `slipdock-db` and `slipdock-data` volumes are the only copy of your data,
so back them up.

The manual has the rest:

- [Docker, step by step](docs/manual/docker-step-by-step.md): Windows, setup
  without a browser, a TLS proxy, upgrading, backups, admin tasks, building
  the image and a table of what usually goes wrong.
- [Running it for other people](docs/manual/running-it-for-other-people.md):
  who may register, limits and trials, and the settings the environment seeds.
- [Receiving email](docs/manual/receiving-email.md) and
  [Google Drive for meeting recordings](docs/manual/google-drive-for-meeting-recordings.md).
- [Models and AI keys](docs/manual/running.md#the-servers-models-and-fallbacks),
  and [running it as a service](docs/manual/as-a-service.md) without Docker.

### From a checkout

You need Elixir 1.19 or newer on Erlang/OTP 27, and a Postgres.

```sh
git clone https://github.com/dadamsuk/slipdock.git
cd slipdock
docker compose -f compose.dev.yaml up -d   # Postgres on 127.0.0.1:5434
mix setup          # deps, database, seeds, assets
mix phx.server     # the address it binds to is printed on start-up
```

`mix setup` seeds the demo workspace the screenshots come from. Don't leave
the dev server reachable by other people: its `/dev/mailbox` shows every
sign-in link it has sent. [The manual](docs/manual/running.md#from-a-checkout)
has the details, and [CONTRIBUTING.md](CONTRIBUTING.md) says how to work on it.

## Run an agent against a board

A board can hand cards to a coding agent on your own machine. A rule sends a
list's cards to a job queue, a runner takes each job, runs Claude Code (or
whatever you configure) on the card and reports back. The card shows its jobs
and their live log.

- **Pull, not push.** Runners dial out to Slipdock, so there are no ports to
  open, and it works the same against the hosted service.
- **Slipdock never decides what runs.** A job carries data: its kind, the card
  and the prompt. What each kind runs is set on the runner's machine.
- **One queue for everything.** A Claude session in a `/loop`, a scheduled
  task or ChatGPT's connector takes jobs from the same queue as the runners.
- **A question parks the job.** The agent opens a wait and stops, the next
  card runs, and the answer sends the card back.

Set one up on the board under **Automations → Connect a runner**, which gives
you exactly what to paste. [docs/agents.md](docs/agents.md) is the guide to
pointing an agent at a board, and the manual covers
[runners](docs/manual/runners.md) and [machines](docs/manual/machines.md).

## Tools

A **Tool** is a ready-made way of working that somebody publishes on a server
for the other people on it: a board blueprint, the agent skills that use that
board, files and a README. Installing one has the server build the board, the
same way every time.

One Tool is built in. `handbook` puts a `Handbook/` folder on a board: the
specification, architecture, decisions and rules of the project, which each
card is handed the relevant sections of before it is built. The
`slipdock-plan` skill turns an idea into decisions in the handbook and cards
on the board.

See [Tools in the manual](docs/manual/tools.md) and the
[package reference](docs/tool-packages.md).

## Connecting an MCP client

Every install is an MCP server at `https://your-server/mcp`. In claude.ai or
the Claude apps: **Settings → Connectors → Add custom connector**, give it
that address, and approve it in the browser. In Claude Code:

```sh
claude mcp add --transport http slipdock https://your-server/mcp   # then /mcp to sign in
```

The client gets 56 tools, each checked exactly as the API checks the same
token, so a read-only or board-scoped token stays that way:

| For | Tools |
|---|---|
| Finding your way | `whoami`, `get_guide`, `list_boards`, `get_board`, `list_cards`, `get_card`, `search`, `ask`, `activity` |
| Cards | `create_card`, `update_card`, `move_card`, `comment`, `leave_handoff`, `complete_card`, `verify_card`, `status_update`, `archive_card`, `delete_card`, `card_views` |
| Boards | `create_board`, `update_board`, `archive_board`, `delete_board`, `create_list`, `delete_list`, `create_tag`, `garden`, `garden_decide` |
| The wiki | `read_page`, `list_pages`, `page_info`, `page_history`, `wiki_info`, `write_page`, `update_page`, `revert_page`, `quick_note`, `page_tool`, `file_folder`, `share`, `manage_wiki` |
| Files | `download_file`, `upload_file`, `delete_attachment` |
| Automations and Tools | `list_automations`, `manage_automation`, `list_tools`, `install_tool`, `skill_registry` |
| Runner jobs and releases | `claim_job`, `job_progress`, `finish_job`, `job_log`, `keep_job_log`, `release_now` |

It also offers 6 prompts, ready-made workflows in the client's own menu:
`plan-my-day`, `weekly-review`, `triage`, `resume`, `leave-handoff` and
`tidy-board`. And it offers resources you attach to a conversation yourself:
`slipdock://board/{code}`, `slipdock://card/{id}`, `slipdock://page/{code}`,
`slipdock://view/{board}/{view}` and `slipdock://work`.

What each tool, [prompt](docs/manual/mcp-server.md#the-prompts) and
[resource](docs/manual/mcp-server.md#the-resources) does is in
[the manual](docs/manual/mcp-server.md), and setting up a particular client is
in [docs/agents.md](docs/agents.md#over-mcp).

## Security

This is a self-hosted app that holds everything you are working on. The short
version:

- Sign-up is closed by default, and sign-in is passwordless and rate limited.
- Agents and runner machines get scoped, revocable tokens and keys of their
  own, never your account.
- AI runs on each person's own key or endpoint. Without one, no board content
  leaves the server.
- Outbound calls go only to public addresses.
- Put TLS in front of it, and back up the two volumes.

[Security notes](docs/manual/security-notes.md) in the manual explains each of
these and the decisions that are yours to make. To report a vulnerability,
see [SECURITY.md](SECURITY.md).

## Licence

Free software under the [GNU Affero General Public License v3](LICENSE).
Copyright © 2026 David Adams.

The AGPL's point, and the reason it was chosen here: if you run a modified copy
as a network service, the people using it are entitled to your changes. The
Account page links to the source for exactly that reason — point
`SLIPDOCK_SOURCE_URL` at your own repository if you run a fork.

## Everything else

- **[docs/manual.md](docs/manual.md)** — the full reference: every view, the
  wiki, automations, the keyboard, the JSON API, the CLI, the MCP server and
  the agent skills.
- **[docs/agents.md](docs/agents.md)** — pointing Claude, ChatGPT or anything
  else at your boards: the address, the approval, the skills, and what to do
  when it will not connect.
- **[UPGRADING.md](UPGRADING.md)** — moving an existing install across the
  Kanban → Slipdock rename.
- **[CONTRIBUTING.md](CONTRIBUTING.md)** — how to work on it.
- **[SECURITY.md](SECURITY.md)** — reporting a vulnerability.
- **[AGENTS.md](AGENTS.md)** — the house rules an agent working in this
  codebase should read first.
