# Slipdock

A self-hosted kanban board for people who want their work tracker to be theirs:
one small Elixir app, one SQLite file, no accounts anywhere else. Boards and
cards are the easy part — what makes it worth running is everything stacked on
top of them. Any card can become a board of its own, so an epic and its tasks
live in one place and roll up. The same cards can be read as a board, a
swimlane grid, a table, a Gantt timeline, a calendar, an outline or a ranked
backlog. Each board carries a wiki, so the reasons live beside the work.
Automations are written in plain English. And the whole thing is available over
a JSON API and a CLI, so an agent can work the board the way a person does.

![A board](docs/screenshots/board.png)

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

Briefly, with the detail in [the manual](docs/manual.md):

- **Boards, lists and cards** — drag and drop, priorities, five flags, due
  dates, tags, checklists, comments, attachments, cover colours, archive and
  restore. Each board has a short code (`qvm-v1-rem`) that addresses it
  everywhere.
- **Subcards** — [any card becomes a board of its own](docs/manual.md#subcards-and-templates),
  nesting as deep as the work does, and
  [rolls up](docs/manual.md#roll-ups-the-outline-and-my-work): leaves done,
  effective dates, slip, blocked-anywhere-below, health.
- **Seven views** of the same cards —
  [board](docs/manual.md#features), [swimlanes](docs/manual.md#swimlanes),
  [table](docs/manual.md#table), [timeline](docs/manual.md#timeline),
  [calendar](docs/manual.md#calendar),
  [outline](docs/manual.md#roll-ups-the-outline-and-my-work) and
  [prioritise](docs/manual.md#prioritise) — each with filters, display
  options and saved views that can be shared or published.
- **Planning** — [dependencies with cycle detection, list categories and
  horizons, milestones, custom and formula fields (RICE, ICE, value/effort),
  budget voting, typed links and goals](docs/manual.md#roadmapping).
- **A wiki per board** — [Markdown pages in a tree of folders](docs/manual.md#wiki),
  `[[links]]`, live card chips, live query blocks, backlinks, revisions,
  templates, export and public links. Plus a
  [Narrative view](docs/manual.md#narrative) that tells you what happened to a
  set of cards over a date range.
- **Automations** — ["when a card lands in Done, email ops@example.com"](docs/manual.md#automations-and-alerts),
  parsed once by a model and then run by the app, with alerts in the header.
- **AI, on your own key** — [chat about a board, ask questions in prose over
  every board at once, search by meaning rather than substring, and an edit
  mode you approve before it applies](docs/manual.md#ai-assistant). No key, no
  AI features; nothing is sent anywhere without one.
- **Built for the keyboard and the phone** — [a command palette, a key for
  every board, card labels you can jump to](docs/manual.md#keyboard), and
  [a layout below 640px that is a pager rather than a sideways
  scroll](docs/manual.md#on-a-phone).
- **Accounts and sharing** — [passwordless sign-in, groups, and read-only or
  editable grants on a board, a single card, a wiki page or a saved
  view](docs/manual.md#accounts-and-sharing).
- **A JSON API and a CLI** — [everything the UI can do](docs/manual.md#json-api),
  [from the shell](docs/manual.md#cli), plus
  [agent skills](docs/manual.md#skills) the server ships and a
  `/api/guide` that describes *your* boards to whatever is driving them.

## Running it

### With Docker

Nothing but Docker needed — no Elixir, no Node, no database server:

```sh
docker compose up -d
docker compose logs -f          # the sign-in link is in here
```

Open <http://localhost:4000>, enter your email address, and follow the link
from the log (no mail is configured yet, so that is where it goes). **The first
address to sign in claims the instance**; after that nobody else can sign up
unless you say so.

Everything that must survive an upgrade is on one volume, `slipdock-data`: the
database, uploaded files, each person's OpenRouter key, and a `SECRET_KEY_BASE`
the container generates for itself on first run. **That volume is the thing to
back up.**

Settings go in a `.env` beside `compose.yaml` — copy `.env.example`, which
lists every variable the app reads with its default, so an empty `.env` is
already a working configuration. The ones that matter first:

```sh
PHX_HOST=kanban.example.com     # the address people use; sign-in links are built from it
KANBAN_PUBLISH=4000             # the host port to publish
KANBAN_SIGNUP_ALLOW=you@example.com,example.org   # who else may sign up
KANBAN_SMTP_HOST=smtp.example.com                 # so links are emailed rather than logged
```

Behind a TLS proxy, set `KANBAN_URL_SCHEME=https` and `KANBAN_URL_PORT=443`.
If people reach the server by more than one name, list the others in
`KANBAN_CHECK_ORIGIN` or live updates are refused for the names you did not
mention. [The manual](docs/manual.md#with-docker) covers the administrative
tasks on the entrypoint (`ai-key`, `reindex`, `migrate`, `remote`).

### From a checkout

```sh
mix setup          # deps, database, seeds, assets
mix phx.server     # the address it binds to is printed on start-up
```

`mix setup` seeds a demo workspace on an empty database, which is the same one
the screenshots come from (`mix slipdock.demo` builds it on demand). In
development the server binds to this machine's Tailscale address if it has one,
otherwise loopback; `KANBAN_BIND_IP` and `PORT` override that, and
`DATABASE_PATH` points it at another database.
[`deploy/kanban.service`](deploy/kanban.service) is a systemd unit template for
running it on boot — see [the manual](docs/manual.md#as-a-service).

## Security notes

This is a self-hosted app that holds everything you are working on, and some of
these are decisions only you can make.

- **Sign-up is closed by default.** The first address to sign in claims an
  empty instance; after that only people who already have an account can get
  in. `KANBAN_SIGNUP_ALLOW` lets named addresses or whole domains in;
  `KANBAN_OPEN_SIGNUP=true` lets anybody in, which is sensible only when the
  server is already behind a boundary of your own.
- **Sign-in is passwordless and rate limited** — a one-time link valid for 15
  minutes, a session that lasts 30 days, five attempts an hour per address and
  twenty per IP, so nobody can use your server to mail strangers. A refused
  address is told exactly what an accepted one is told.
- **Responses carry a Content-Security-Policy** that allows script from this
  origin only.
- **Agentic Login is an authentication bypass, by design.** With
  `KANBAN_AGENTIC_LOGIN=true` the sign-in page will write a working link for
  *any* address to a file on the server, so an automated test can sign itself
  in. It is off unless you set it, and a server with it on says so in the log
  on every boot. Only ever enable it on a machine used for testing.
- **AI runs on each person's own OpenRouter key**, kept in a `0600` JSON file
  outside the database. Somebody without a key gets no AI features at all, and
  no board content leaves the server on their behalf. Back that file up like a
  `.env`, because it holds secrets in the clear.
- **Attachments are served with permission checks**, but they are whatever
  people upload: the app does not scan them.
- **Put TLS in front of it.** The Docker image does not force HTTPS, on the
  assumption that something in front terminates it; build with
  `--build-arg KANBAN_FORCE_SSL=true` if the app itself should.
- **Back up the database** — the `slipdock-data` volume under Docker, or the
  SQLite file, uploads and `ai_keys.json` from a checkout. There is no other
  copy.

To report a vulnerability, see [SECURITY.md](SECURITY.md); it also says what is
in scope and what is a deployment choice rather than a bug.

## Licence

Free software under the [GNU Affero General Public License v3](LICENSE).
Copyright © 2026 David Adams.

The AGPL's point, and the reason it was chosen here: if you run a modified copy
as a network service, the people using it are entitled to your changes. The
Account page links to the source for exactly that reason — point
`KANBAN_SOURCE_URL` at your own repository if you run a fork.

## Everything else

- **[docs/manual.md](docs/manual.md)** — the full reference: every view, the
  wiki, automations, the keyboard, the JSON API, the CLI and the agent skills.
- **[CONTRIBUTING.md](CONTRIBUTING.md)** — how to work on it.
- **[SECURITY.md](SECURITY.md)** — reporting a vulnerability.
- **[AGENTS.md](AGENTS.md)** — the house rules an agent working in this
  codebase should read first.
