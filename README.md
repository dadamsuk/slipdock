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

A self-hosted kanban board for people who want their work tracker to be theirs and to really help get their job done: you can easily self-host for free or use the hosted version. Functionality of the two is identical. It's different (better?) than most Kanban boards though, because it incorporates features built on real world experience of hundreds of projects, none of the fluff you don't need and everything that you do. This system was built for a real use case: replacing Jira Tickets, Jira Product Discovery, Jira Atlas (particularly sharing updates with stakeholders) and Confluence. And with the optional AI integrations, it's better than all of them. 

Any card can become a board of its own, so an epic and its tasks
live in one place and roll up. The same cards can be read as a board, a
swimlane grid, a table, a Gantt timeline, a calendar, an outline or a ranked
backlog. Each board carries a wiki, so the documentation/reasoning sits beside the work.
Automations are written in plain English ("flag any card which is more than 3 days overdue to urgent and send an email to john@example.com"). You can give it plain English commands too: "Split this card into 3 sub-cards", interrogate it: "Across all my boards, what tasks do I have that are slated to take less than 1 day?".  And it has semantic search: "Where's the card about the invoicing bug that came in last week" (that doesn't even mention the word invoice).  

And best of all the whole thing is available over
a JSON API and a CLI, so an agent can work the board the way a person does.  Chat with Claude or ChatGPT about your work, get it to create your cards, run loops off the back of them.  Whatever you need.

## A word on AI coding...

Of course it was built using AI. But it wasn't vibe coded in an hour. First it was born of 30+ years of experience of managing projects and writing software. Second it was planned out and carefully constructed with robust testing and verification.  And third it has been security reviewed by multiple different coding agents. 

![A board](docs/screenshots/board.png)

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
- **Semantic Search** - find what you're looking for even when you can't remember exactly what it is.
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
  view](docs/manual.md#accounts-and-sharing) — plus
  [a device flow for signing an agent in](docs/manual.md#signing-an-agent-in)
  from anywhere, with scoped, expiring, revocable tokens.
- **A JSON API and a CLI** — [everything the UI can do](docs/manual.md#json-api),
  [from the shell](docs/manual.md#cli), plus
  [agent skills](docs/manual.md#skills) the server ships and a
  `/api/guide` that describes *your* boards to whatever is driving them.

## Running it

### With Docker

The quickest way, and the one to use on a server. You need **Docker** with the
Compose plugin — `docker compose version` should print v2 or newer — and
nothing else: no Elixir, no Node, no database server.

**1. Get the compose file.**

```sh
mkdir slipdock && cd slipdock
curl -O https://raw.githubusercontent.com/dadamsuk/slipdock/main/compose.yaml
curl -o .env https://raw.githubusercontent.com/dadamsuk/slipdock/main/.env.example
```

There is no need to clone the repository: the image is published and
`docker compose up` pulls it. (Cloning works too, and is what you want if you
mean to change something — see *Building it yourself* below.)

**2. Tell it the address people will use.** Sign-in links are built from it, so
`localhost` only works while you are sitting at that machine. Edit `.env`:

```sh
PHX_HOST=slipdock.example.com
```

Every other line in `.env.example` is already its default, so that one line is
genuinely all that is needed. Skip even that if you are only trying it on your
own machine.

**3. Start it.**

```sh
docker compose up -d
```

Whenever you change `.env` afterwards, run that same command again. **Not
`docker compose restart`** — that reuses the existing container and never
re-reads `.env`, which makes a setting look as though it did not work.

**4. Set it up.** Open `http://localhost:4000`, or your `PHX_HOST`. A server
nobody has claimed shows a **setup wizard**, which asks for a token printed in
the log the first time it starts:

```sh
docker compose logs slipdock | grep -A4 "has not been set up"
```

That token is why finding the page first is not enough to claim somebody else's
server. The wizard asks three things — who may register, how mail goes out, and
your own email address — and is gone for good once you finish. Everything on it
lives under **Admin** from then on.

**5. Sign in.** Until a mail server is configured, your sign-in code is written
to the log rather than emailed:

```sh
docker compose logs slipdock | grep "Sign-in"
```

#### Doing it without a browser

Put these in `.env` before step 3 and the wizard never appears at all:

```sh
SLIPDOCK_ADMIN_EMAIL=you@example.com     # becomes the admin; skips the wizard
SLIPDOCK_SIGNUP_MODE=closed              # open | allowlist | approval | closed
SLIPDOCK_SMTP_HOST=smtp.example.com      # and _PORT, _USER, _PASSWORD, _FROM
```

Or afterwards, from the command line:

```sh
docker compose run --rm slipdock setup --admin you@example.com
docker compose run --rm slipdock setup --status
docker compose run --rm slipdock setup --sign-in-link you@example.com
```

That last one is the way back in on the day mail stops working.

#### Behind a TLS proxy

The container speaks plain HTTP on port 4000 and assumes something in front of
it terminates TLS. Tell it so, or the links it emails will point at the wrong
scheme and port:

```sh
SLIPDOCK_URL_SCHEME=https
SLIPDOCK_URL_PORT=443
SLIPDOCK_PUBLISH=127.0.0.1:4000   # only the proxy needs to reach it
```

If people reach the server by more than one name, list the others in
`SLIPDOCK_CHECK_ORIGIN` — live updates are refused for names you did not
mention, which looks like a page that loads but never changes.

To make the app force HTTPS itself, build it with
`--build-arg SLIPDOCK_FORCE_SSL=true`.

#### Upgrading

```sh
docker compose pull
docker compose up -d
```

Migrations run themselves on boot. Read [UPGRADING.md](UPGRADING.md) first — it
says what changed and what, if anything, you have to do.

`latest` follows the main branch. To pin a version instead, set `SLIPDOCK_TAG`
in your `.env` to any published tag.

#### Backing up

Everything that must survive is on one volume: the SQLite database, uploaded
files, each person's OpenRouter key, and a `SECRET_KEY_BASE` the container
generates for itself on first run. **That volume is the only copy**, and
backing it up is the one piece of maintenance this app asks of you.

```sh
docker compose stop
docker run --rm -v slipdock_slipdock-data:/data -v "$PWD":/backup alpine \
  tar czf /backup/slipdock-backup.tar.gz -C /data .
docker compose start
```

The volume is named after the compose project, which `compose.yaml` pins to
`slipdock` — so it is `slipdock_slipdock-data` wherever you put the directory.
Check with `docker volume ls` if in doubt; backing up a volume name that does
not exist produces a cheerful, empty archive.

To restore, stop the app, then untar into the same volume with
`tar xzf /backup/slipdock-backup.tar.gz -C /data`.

#### Administrative tasks

A release has no `mix`, so the ones worth having are on the entrypoint:

```sh
docker compose run --rm slipdock setup --status   # what this server allows
docker compose run --rm slipdock ai-key           # who has an OpenRouter key
docker compose run --rm slipdock reindex          # rebuild the search index
docker compose run --rm slipdock migrate          # migrations, by hand
docker compose run --rm slipdock remote           # an IEx shell in the running app
```

#### Building it yourself

The image is built for `amd64` and `arm64`. For anything else, or to run your
own changes:

```sh
git clone https://github.com/dadamsuk/slipdock.git
cd slipdock
docker compose build
docker compose up -d
```

The first build takes a few minutes — it compiles the app and its assets — and
later ones reuse most of that. Set `SLIPDOCK_PULL_POLICY=missing` in `.env` so
that `up` stops reaching for the published image.

#### If something is wrong

| What you see | What it usually is |
|---|---|
| `/setup` gives a 404 | The server is already set up. `setup --status` says by whom; `setup --sign-in-link` gets you in. |
| Every page redirects to `/setup` | The opposite: it has never been claimed. Finish the wizard. |
| The wizard will not take the token | It is in the log from the **first** boot: `docker compose logs slipdock \| grep -A4 "has not been set up"`. |
| No sign-in email arrives | Expected until SMTP is configured — the code goes to the log. Set it under **Admin → Email**, which will not save until a test message actually arrives. |
| The page loads but never updates | `PHX_HOST` is not the name you are reaching it by. The log says so, in a box, naming the value to set. |
| Sign-in links point at `localhost` | Same cause, same fix. |
| You set `PHX_HOST` and nothing changed | `docker compose restart` reuses the container and never re-reads `.env`. Use `docker compose up -d`. |
| Reached by more than one name | Keep the main one in `PHX_HOST`, list the rest in `SLIPDOCK_CHECK_ORIGIN=a.example,b.example`. |

### Running it for other people

Slipdock is built for one person or a team who trust each other, and it will
also run as a small shared service. Four things make that difference, all under
**Admin**:

- **Who may register** — closed, an allowlist, approval one at a time, or open.
- **A card limit**, counted against the boards somebody *owns*, so a guest
  working on your board costs them nothing.
- **Who people can see** — everyone on the server, or only the people they
  actually share a board, card or page with. The second is what stops two
  customers of one server learning that the other exists; it also keeps their
  addresses out of the prompts sent to a language model.
- **Whether sharing with a stranger makes them an account**, which is how
  somebody arrives on a hosted instance and is usually wrong on a private one.

### Settings: the environment seeds them once

Everything about *how this server behaves* — who may register, the free card
limit, who shows up in people pickers, whether sharing something with a
stranger makes them an account, and how mail is sent — lives in the database
now, so it can be changed from a browser without a redeploy.

The environment still configures it, but only as a **seed**: the variables
below are written into the settings the first time the server starts, and are
ignored from then on.

```sh
SLIPDOCK_ADMIN_EMAIL=you@example.com   # setting this skips the setup wizard entirely
SLIPDOCK_SIGNUP_MODE=allowlist         # open | allowlist | approval | closed
SLIPDOCK_SIGNUP_ALLOW=you@example.com,example.org   # seeds the allowlist
SLIPDOCK_FREE_CARD_LIMIT=20            # cards allowed on one person's own boards
SLIPDOCK_USER_DIRECTORY=shared_only    # instance | shared_only
SLIPDOCK_INVITES_CREATE_ACCOUNTS=false # whether sharing with a stranger makes an account
SLIPDOCK_SMTP_HOST=smtp.example.com    # and SLIPDOCK_SMTP_PORT / _USER / _PASSWORD / _FROM
SLIPDOCK_LOGIN_FALLBACK=false          # never write sign-in codes to a file (set this when public)
```

There is a command-line equivalent for an install that was not configured that
way, and a `--status` that says what the server currently thinks:

```sh
mix slipdock.setup --admin you@example.com --mode allowlist --allow example.com
mix slipdock.setup --status
mix slipdock.setup --sign-in-link you@example.com   # when mail has broken
```

It refuses to run on a server that is already set up — that server is already
somebody's.

**Changing one of these on a server that has already started does nothing.**
That is deliberate — a browser has to be able to win, or the settings page
would be a lie — but it does mean a variable edited after the fact looks
ignored, because it is. Change it in the app instead.

Two exceptions, which are overrides rather than seeds and win every time:
`SLIPDOCK_LOGIN_FALLBACK=false`, so a public host can forbid writing sign-in
codes to a file whatever the settings say, and `SLIPDOCK_AGENTIC_LOGIN`.

### From a checkout

You need Elixir 1.19 or newer on Erlang/OTP 27, and nothing else — SQLite is
embedded and the asset tools install themselves.

```sh
git clone https://github.com/dadamsuk/slipdock.git
cd slipdock
mix setup          # deps, database, seeds, assets
mix phx.server     # the address it binds to is printed on start-up
```

`mix setup` seeds a demo workspace on an empty database, which is the same one
the screenshots come from (`mix slipdock.demo` builds it on demand). In
development the server binds to this machine's Tailscale address if it has one,
otherwise loopback; `SLIPDOCK_BIND_IP` and `PORT` override that, and
`DATABASE_PATH` points it at another database.
[`deploy/slipdock.service`](deploy/slipdock.service) is a systemd unit template for
running it on boot — see [the manual](docs/manual.md#as-a-service).

## Security notes

This is a self-hosted app that holds everything you are working on, and some of
these are decisions only you can make.

- **Sign-up is closed by default.** A server nobody has set up yet lets the
  first address in, which is how an instance gets claimed; after that
  registration follows whichever mode you chose — *closed* (accounts exist only
  because you made them), *allowlist* (named addresses and whole domains),
  *approval* (people ask, you say yes) or *open* (anybody), which is sensible
  only when the server is already behind a boundary of your own. The mode and
  the allowlist are editable in the app; `SLIPDOCK_SIGNUP_MODE` and
  `SLIPDOCK_SIGNUP_ALLOW` seed them on first boot.
- **Sign-in is passwordless and rate limited** — a one-time link valid for 15
  minutes, a session that lasts 30 days, five attempts an hour per address and
  twenty per IP, so nobody can use your server to mail strangers. A refused
  address is told exactly what an accepted one is told.
- **Responses carry a Content-Security-Policy** that allows script from this
  origin only.
- **Administering the server needs its own token scope.** The admin area
  (registration, mail, people, the signup queue) is behind an admin account, and
  over HTTP it also needs a token deliberately made with the `admin` scope. API
  tokens live in agents and CI; an ordinary read/write one leaking should not be
  a key to who may register.
- **Agents get scoped tokens, not your account.** `slipdock auth` shows a code,
  you approve it in a browser you are already signed into, and the agent is
  given a token you can see and revoke. A token can be read-only, confined to
  named boards, and made to expire; the Account page shows when each was last
  used and from where. A read-only token is refused anything that would change
  something, and a board-scoped one cannot even list boards outside its scope.
- **Agentic Login is an authentication bypass, by design**, and is *not* how to
  sign an agent in — the device flow above is. With
  `SLIPDOCK_AGENTIC_LOGIN=true` the sign-in page will write a working link for
  *any* address to a file on the server, so a test running on that server can
  sign itself in. It is off unless you set it, and a server with it on says so
  in the log on every boot. Only ever enable it on a machine used for testing.
- **AI runs on each person's own OpenRouter key**, kept in a `0600` JSON file
  outside the database. Somebody without a key gets no AI features at all, and
  no board content leaves the server on their behalf. Back that file up like a
  `.env`, because it holds secrets in the clear.
- **Attachments are served with permission checks**, but they are whatever
  people upload: the app does not scan them.
- **Put TLS in front of it.** The Docker image does not force HTTPS, on the
  assumption that something in front terminates it; build with
  `--build-arg SLIPDOCK_FORCE_SSL=true` if the app itself should.
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
`SLIPDOCK_SOURCE_URL` at your own repository if you run a fork.

## Everything else

- **[docs/manual.md](docs/manual.md)** — the full reference: every view, the
  wiki, automations, the keyboard, the JSON API, the CLI and the agent skills.
- **[UPGRADING.md](UPGRADING.md)** — moving an existing install across the
  Kanban → Slipdock rename.
- **[CONTRIBUTING.md](CONTRIBUTING.md)** — how to work on it.
- **[SECURITY.md](SECURITY.md)** — reporting a vulnerability.
- **[AGENTS.md](AGENTS.md)** — the house rules an agent working in this
  codebase should read first.
