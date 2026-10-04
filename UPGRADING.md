# Upgrading

## Deployment defaults got stricter

- **`deploy/slipdock.service` runs a production release now**, not
  `mix phx.server` in dev mode. An installed copy of the old unit keeps
  working, but it is running the development server — `/dev/mailbox`, debug
  error pages, a published `secret_key_base`. To move over: build the release
  (`MIX_ENV=prod mix assets.deploy && MIX_ENV=prod mix release --overwrite`),
  put `DATABASE_URL`, `SECRET_KEY_BASE` and `PHX_HOST` in `.env`, copy uploaded
  files from `priv/uploads` to `/var/lib/slipdock/uploads` (or set
  `SLIPDOCK_UPLOADS_DIR`), then install the new unit — see
  [the manual](docs/manual.md#as-a-service). Signing in again is expected: the
  new secret invalidates old sessions. Until then, `SLIPDOCK_DEV_TOOLS=false`
  in the old unit's environment turns off the mailbox and the debug pages.
- **`compose.yaml` publishes on `127.0.0.1:4000`** unless `SLIPDOCK_PUBLISH`
  says otherwise. A server reached directly from other machines needs
  `SLIPDOCK_PUBLISH=4000` in `.env`.
- **The SMTP relay's certificate is verified**, as is the database's when
  `DATABASE_SSL=true` (its name now included). A relay with a self-signed
  certificate needs `SLIPDOCK_SMTP_TLS_VERIFY=false`;
  `DATABASE_SSL_VERIFY=false` still turns off the database check.
- **Agentic Login files** go to a private `slipdock-agentic-login` directory
  under the system temp dir, mode 0600, rather than straight into `/tmp`.

## The database is Postgres now, and this one is not an upgrade

SQLite is gone. Slipdock runs on Postgres only, `compose.yaml` brings up a
`postgres` service alongside the app, and the 45 migrations that built the
SQLite schema have been replaced by a single Postgres baseline.

**There is no automatic migration of an existing SQLite database, and there
will not be one.** Pulling this version against an old `slipdock-data` volume
gives you an empty Postgres and leaves the `kanban.db` file sitting there
untouched — nothing is destroyed, but nothing is carried across either.

To bring boards over, export them from the old version and import them into
the new one. Do the export *before* upgrading, while the old container can
still read its database:

```sh
# On the old version, for each board tree you want to keep:
docker compose exec slipdock /app/bin/slipdock rpc \
  'IO.puts(Slipdock.Portable.export_json!("BOARDCODE"))' > board.json
```

Then upgrade, sign in, and import each file under **Boards → Import**, or
`POST /api/import`. What a portable document does and does not carry is
documented in `Slipdock.Portable` — attachments, votes, activity history and
page revisions stay behind, which is a decision rather than an oversight.

What changes in configuration:

- `DATABASE_PATH` is gone. Under compose you need set nothing; the app builds
  its `DATABASE_URL` from `POSTGRES_USER` / `POSTGRES_PASSWORD` /
  `POSTGRES_DB`, which the bundled `postgres` service reads too. Set
  `DATABASE_URL` yourself to use a Postgres you run elsewhere, and
  `DATABASE_SSL=true` if it wants TLS.
- **Set `POSTGRES_PASSWORD` in `.env` before the first start.** It defaults to
  `slipdock`, and Postgres only reads it when it initialises its data
  directory — changing it later does nothing until that volume is recreated.
- There are now two volumes to back up: `slipdock-db` (the database) and
  `slipdock-data` (uploads, AI keys, the generated secret). Back the database
  up with `pg_dump`, not by copying files.
- Working from a checkout now needs a Postgres. `docker compose -f
  compose.dev.yaml up -d` runs one on `127.0.0.1:5434`, which is what
  `config/dev.exs` and `config/test.exs` default to.

## There is a published image now

`compose.yaml` pulls `ghcr.io/dadamsuk/slipdock` instead of building from the
checkout, so upgrading is `docker compose pull && docker compose up -d` and no
longer takes an Elixir build. `docker compose build` still works for running
your own changes; set `SLIPDOCK_PULL_POLICY=missing` so that `up` stops
reaching for the published one.

**If your directory is not called `slipdock`, read this before upgrading.**
`compose.yaml` now pins the compose project name, which is what prefixes the
data volume. Previously the project name came from whatever the directory
happened to be called, so a clone into `kanban/` kept its data in
`kanban_slipdock-data`. Pinning it means an upgraded `docker compose up` would
look for `slipdock_slipdock-data`, find nothing, and cheerfully start with an
empty database beside your real one.

Check first:

```sh
docker volume ls | grep slipdock-data
```

If it is already `slipdock_slipdock-data`, which it is for anybody who cloned
into `slipdock/`, there is nothing to do. Otherwise copy it across before
starting:

```sh
docker compose stop
docker volume create slipdock_slipdock-data
docker run --rm -v OLD_slipdock-data:/from -v slipdock_slipdock-data:/to alpine \
  sh -c 'cd /from && cp -a . /to'
```

...with `OLD` replaced by your old project name. Keep the old volume until you
are satisfied.

## Registration, admins and limits

This release is the one where Slipdock learned to be run for people who are not
you. Nothing changes for an existing install — the defaults are what you had —
but the pieces are worth knowing about:

- **A setup wizard** for new installs, gated by a token printed in the log.
  Existing installs never see it (see below).
- **Admins.** Your oldest account becomes one. Only an admin can change who may
  register, how mail is sent, or anybody's standing.
- **Sign-in codes** beside the magic link, so a server with no mail can be used
  by reading a code out of the log rather than a sixty-character URL.
- **Registration modes**: closed, allowlist, approval, open.
- **A card limit** (off by default), counted against boards somebody owns.
- **`user_directory`** (`instance` by default, so nothing changes): on
  `shared_only`, people only see those they share something with.
- **`invites_create_accounts`** (on by default, which is what happened before):
  whether sharing with an unknown address creates an account for it. Turn it
  off to share only with people who already have one.

Two behaviour changes worth reading:

- Sharing a board or card with an address that has no account used to create one
  silently. It now goes through one path which **emails them** to say so, and
  which an admin can switch off entirely.
- An account can be **disabled**, which ends its sessions and tokens at once.
  There is still no delete, because somebody's cards, comments and page history
  would go with them.

## Settings moved into the database

Who may register, how mail is sent, and the rest of this server's own
behaviour used to be environment variables read at boot. They are rows now, so
they can be changed from a browser.

**Nothing to do, and nothing changes for an existing install.** The first time
the upgraded server starts it seeds the new settings from your existing
environment, so it keeps behaving exactly as it did: `SLIPDOCK_OPEN_SIGNUP`
becomes the *open* registration mode, `SLIPDOCK_SIGNUP_ALLOW` becomes
*allowlist* plus one row per entry, and `SLIPDOCK_SMTP_*` is carried across.
Nobody is signed out and no data moves.

Two consequences worth knowing:

### Your existing environment variables stop having any effect

They seeded the settings **once**. Editing `SLIPDOCK_SIGNUP_ALLOW` after that
first boot does nothing at all — the database is the authority now, and the
value in your `.env` is ignored. Change it in the app instead, or clear the
settings row if you really want to re-seed from the environment.

This is the one thing about this release likely to look like a bug. It is not:
a settings page that could be silently overruled by a stale `.env` would be
worse.

### Your server is already claimed, and your oldest account is the admin

New installs get a setup wizard, which an existing install must never be
offered — otherwise the first stranger to find `/setup` after an upgrade could
take over the server. So seeding marks any instance that already has users as
set up, closes `/setup` for good, and makes the **oldest account** the admin.

If that is not the right person, promote the right one and demote the first
(an admin may do both, except to the last remaining admin). Set
`SLIPDOCK_ADMIN_EMAIL` before the first start to name them directly instead.

## Kanban → Slipdock

The project was called **Kanban** until October 2026. The rename touched the
OTP application, the environment variables, the CLI, the agent skills and the
database filename. Most of it is handled for you; three things are not.

Nothing about your data changes. No migration runs, no schema moves, and the
SQLite file is byte-for-byte the one you had.

### 1. Move the database file (from a checkout)

Development used to read `kanban_dev.db` and now reads `slipdock_dev.db`:

```sh
sudo systemctl stop kanban          # or however you run it
cp kanban_dev.db kanban_dev.db.backup   # somewhere OUTSIDE the repository
for f in kanban_dev.db*; do mv "$f" "slipdock_dev${f#kanban_dev}"; done
```

Move the `-wal` and `-shm` files with it if they are there, which the loop
above does. Or skip the rename entirely and set `DATABASE_PATH=kanban_dev.db`.

**Under Docker there is nothing to do.** The database lives on the
`kanban-data` volume at a path that has not changed. If you want the volume
renamed to `slipdock-data` to match `compose.yaml`, copy it across rather than
renaming in place:

```sh
docker volume create slipdock-data
docker run --rm -v kanban-data:/from -v slipdock-data:/to alpine \
  sh -c 'cd /from && cp -a . /to'
```

### 2. Everyone is signed out

The session cookie is `_slipdock_key` rather than `_kanban_key`, so every
existing browser session ends at the upgrade. People sign in again with the
usual emailed link. API tokens are **not** affected and keep working.

### 3. The systemd unit

`deploy/kanban.service` is `deploy/slipdock.service`. If you installed the old
one, replace it rather than editing in place so the service name matches the
project:

```sh
sudo systemctl stop kanban && sudo systemctl disable kanban
sudo cp deploy/slipdock.service /etc/systemd/system/
sudoedit /etc/systemd/system/slipdock.service   # the five machine-specific lines
sudo systemctl daemon-reload
sudo systemctl enable --now slipdock
sudo rm /etc/systemd/system/kanban.service
```

## What keeps working, and for how long

| Old | New | How long the old one works |
|---|---|---|
| `KANBAN_*` variables | `SLIPDOCK_*` | **One release.** Each is read as its `SLIPDOCK_*` equivalent and the server warns once on boot. |
| `$KANBAN_TOKEN`, `~/.config/kanban/token` | `$SLIPDOCK_TOKEN`, `~/.config/slipdock/token` | **One release.** Nobody has to re-authenticate. |
| ```` ```kanban ```` and ```` ```kanban-query ```` wiki blocks | ```` ```slipdock ```` | **Permanently.** These are written into pages people have already saved; a rename of ours is no reason to break somebody's document. |
| `kanban` CLI binary | `slipdock` | Not aliased. Install the new escript (`cd cli && mix escript.build`) and delete the old one. |
| `mix kanban.demo`, `kanban.reindex`, `kanban.ai_key` | `mix slipdock.*` | Not aliased. |

Rename your variables when you upgrade. The fallback is there so a server
boots, not so you can leave it.

**One edge to the fallback.** `config/dev.exs` is compile-time configuration
and runs before `config/runtime.exs`, where the fallback lives, so the three
variables that file reads are *not* covered: `SLIPDOCK_BIND_IP`, `PORT` and
`DATABASE_PATH`. `PORT` and `DATABASE_PATH` never had a prefix, so only
`KANBAN_BIND_IP` actually changes, it only affects running from a checkout in
development, and the symptom is harmless — the server binds to its default
(this machine's Tailscale address, else loopback) instead of the address you
asked for, and says which on start-up. Rename that one by hand.

## Checking it worked

```sh
slipdock whoami                 # the CLI reaches the server and knows you
mix test                        # if you run from a checkout
journalctl -u slipdock | grep -i "KANBAN_"   # any variables still on old names
```

The last one is the useful one: it prints the single warning naming every
`KANBAN_*` variable the server fell back on, which is your rename checklist.
