# Upgrading

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
