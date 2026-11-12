[Slipdock — the manual](../manual.md)

## Docker, step by step

The whole of running Slipdock under Docker: installing it, putting it behind a
proxy, upgrading, backing up, and what to do when something is wrong.
[Running](running.md#with-docker) has the short version.

You need **Docker** with the Compose plugin; `docker compose version` should print v2 or newer.

### Linux

**1. Get the two files.**

```sh
mkdir slipdock && cd slipdock
curl -O https://raw.githubusercontent.com/dadamsuk/slipdock/main/compose.yaml
curl -O https://raw.githubusercontent.com/dadamsuk/slipdock/main/setup.sh
```

There is no need to clone the repository: the image is published and
`docker compose up` pulls it. (Cloning works too, and is what you want if you
mean to change something — see *Building it yourself* below.)

**2. Answer five questions.**

```sh
sh setup.sh
```

It asks the address people will use, whether something like Cloudflare or nginx
terminates TLS in front of it, which port to listen on, your email address, and
whether you have a mail server. Then it writes a `.env` you can edit by hand
afterwards if you want to change anything. 

**3. Start it.**

```sh
docker compose up -d
```

Whenever you change `.env` afterwards, run that same command again. **Not
`docker compose restart`** — that reuses the existing container and re-reads
nothing, which makes a setting look as though it did not work.

### On Windows

**1. Get the two files.**

```powershell
curl.exe -O https://raw.githubusercontent.com/dadamsuk/slipdock/main/compose.yaml
curl.exe -O https://raw.githubusercontent.com/dadamsuk/slipdock/main/setup.ps1
```


**2. Run the setup script.**

```powershell
powershell -ExecutionPolicy Bypass -File setup.ps1
```

The `-ExecutionPolicy Bypass` is because Windows refuses
downloaded scripts by default

`setup.sh` from the Linux instructions should work if you have **WSL** or **Git Bash**.

**3. Start it.**

```powershell
docker compose up -d
```

Whenever you change `.env` afterwards, run that same command again. **Not
`docker compose restart`** — that reuses the existing container and re-reads
nothing, which makes a setting look as though it did not work.

### Linux and Windows

**4. Set it up.** Open the address you gave it. A server
nobody has claimed shows a **setup wizard**, which asks for a token printed in
the log the first time it starts:

```sh
docker compose logs slipdock | grep -A4 "has not been set up"
```

The wizard asks three things — who may register, how mail goes out, and
your own email address.  You can change these settings later from the admin menu.

**5. Sign in.** Until a mail server is configured, your sign-in code is written
to the log rather than emailed:

```sh
docker compose logs slipdock | grep "Sign-in"
```

### Doing it without a browser

`setup.sh` asks for your email address and writes `SLIPDOCK_ADMIN_EMAIL`, which
is what skips the wizard. By hand, these do the same:

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
docker compose run --rm slipdock setup --make-admin you@example.com
```

Use the sign-in-link option if emailing a link isn't working.  

### Behind a TLS proxy

The container speaks plain HTTP on port 4000 and assumes something in front of
it terminates TLS.

```sh
SLIPDOCK_URL_SCHEME=https
SLIPDOCK_URL_PORT=443
SLIPDOCK_PUBLISH=127.0.0.1:4000   # only the proxy needs to reach it (the default)
```

The visitor's own address, which the sign-in limits and the API token audit
use, is taken from `X-Forwarded-For` — but only when the request arrives from
a trusted proxy: by default loopback only, which covers a proxy on the same
host. Under compose, `compose.yaml` sets `SLIPDOCK_TRUSTED_PROXIES=local`:
loopback and the container's own network, which covers Caddy and a host proxy
reaching the published port. A proxy elsewhere on your LAN has to be listed.
If yours connects from a public address (Cloudflare proxying straight to the origin, say), list its
ranges in `SLIPDOCK_TRUSTED_PROXIES`, comma-separated; otherwise everybody
appears to come from the proxy and shares one sign-in limit. `none` trusts
nobody.

If people reach the server by more than one name, list the others in
`SLIPDOCK_CHECK_ORIGIN` — live updates are refused for names you did not
mention, which looks like a page that loads but never changes.

To make the app force HTTPS itself, build it with
`--build-arg SLIPDOCK_FORCE_SSL=true`.

### Which build is running

Every **Admin** page shows, under its side nav, when the running build was
compiled and the commit it came from — the first thing worth checking when a
server is not behaving the way the code in front of you says it should.
`slipdock admin build` prints the same line from a terminal.

There is no `.git` inside the image, so a Docker build has to be told the
commit:

```sh
docker build --build-arg SLIPDOCK_GIT_SHA=$(git rev-parse HEAD) .
SLIPDOCK_GIT_SHA=$(git rev-parse HEAD) docker compose build   # the same, via compose
```

The published images are built with it.

Without it the commit reads `unknown`, which is the honest answer rather than
a wrong one.

### Upgrading

```sh
docker compose pull
docker compose up -d
```

Migrations run themselves on boot. Read [UPGRADING.md](../../UPGRADING.md) first — it
says what changed and what, if anything, you have to do.

These commands bring a new image but leave your `compose.yaml` as it was when
you downloaded it, so a setting a newer `compose.yaml` adds doesn't reach you
until you fetch that file again or set it in `.env`. UPGRADING.md names each
one: `SLIPDOCK_TRUSTED_PROXIES=local`, for instance, without which Caddy's
`X-Forwarded-For` is no longer believed.

`latest` follows the main branch. To pin a version instead, set `SLIPDOCK_TAG`
in your `.env` to any published tag.

Tabs left open across an upgrade reconnect by themselves, but they are still
running the old stylesheet and scripts. Each one shows a "Slipdock has been
updated" bar at the top with a Reload link; until it is reloaded, new features
can look broken there.

While the new container starts, which takes a few seconds, nothing is
listening, so a proxy in front answers with a 502. To have those requests wait
instead, put Caddy in front. It is optional and self-contained:

```sh
cp deploy/caddy/compose.override.yaml deploy/caddy/Caddyfile .
docker compose up -d
```

Compose reads `compose.override.yaml` by itself. Caddy takes over the port in
`SLIPDOCK_PUBLISH`, and the app is then reached only over the compose network.
Upgrading is the same two commands as before: only the app is recreated, and
Caddy keeps retrying each request for up to 30 seconds until the new container
answers. Runners waiting for a job are answered before the old container
stops, and ask again a second later. Caddy trusts the private ranges in front of it, so `X-Forwarded-For`
and `X-Forwarded-Proto` from a tunnel or host proxy pass through unchanged.
It needs Docker Compose 2.24 or later.

`deploy/deploy.sh <tag>` is the same upgrade pinned to one image
(`sha-<commit>` or a release version like `1.2.3`): it pulls and recreates the
app alone, leaves Postgres running, records the tag it replaced, and prints the
running digest, so `deploy.sh <previous-tag>` is the rollback. The release
workflow's `deploy` job runs it on the project's own server over Tailscale SSH
after each push to main or a `v*` tag, then waits for `GET /healthz` to report
`ok` on that commit. `/healthz` answers `{"status":"ok","sha":…}`, or 503 when
the database does not answer. Rolling back the image does not roll back the
schema: migrations only go forward.

### Backing up

There are two volumes. `slipdock-db` is the Postgres database; `slipdock-data`
holds uploaded files, each person's AI key and endpoint, and a
`SECRET_KEY_BASE` the container generates for itself on first run. **Those
volumes are the only copy**, and backing them up is the one piece of
maintenance this app asks of you.

The database is backed up with `pg_dump` rather than by copying its files,
because a dump is consistent and restorable into any later Postgres:

```sh
docker compose exec -T postgres pg_dump -U slipdock -Fc slipdock > slipdock-db.dump
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

### Administrative tasks

A release has no `mix`, so the ones worth having are on the entrypoint:

```sh
docker compose run --rm slipdock setup --status   # what this server allows
docker compose run --rm slipdock ai-key           # who has an AI key
docker compose run --rm slipdock reindex          # rebuild the search index
docker compose run --rm slipdock welcome you@example.com   # the Getting Started tour board
docker compose run --rm slipdock migrate          # migrations, by hand
docker compose run --rm slipdock remote           # an IEx shell in the running app
```

### Building it yourself

The image is built for `amd64`. For anything else, or to run your
own changes:

```sh
git clone https://github.com/dadamsuk/slipdock.git
cd slipdock
SLIPDOCK_GIT_SHA=$(git rev-parse HEAD) docker compose build
docker compose up -d
```

The first build takes a few minutes — it compiles the app and its assets — and
later ones reuse most of that. Set `SLIPDOCK_PULL_POLICY=missing` in `.env` so
that `up` stops reaching for the published image.

### If something is wrong

| What you see | What it usually is |
|---|---|
| `/setup` gives a 404 | The server is already set up. `setup --status` says by whom; `setup --sign-in-link` gets you in. |
| "not allowed to sign up here" for your own address | That address has no account and registration is closed. `setup --make-admin you@example.com` makes one (or re-enables it if it was disabled), makes it an admin, and prints a way in. |
| Every page redirects to `/setup` | The opposite: it has never been claimed. Finish the wizard. |
| The wizard will not take the token | It is in the log from the **first** boot: `docker compose logs slipdock \| grep -A4 "has not been set up"`. |
| No sign-in email arrives | Expected until SMTP is configured — the code goes to the log. Set it under **Configuration → Email**, which will not save until a test message actually arrives. |
| The page loads but never updates | `PHX_HOST` is not the name you are reaching it by. The log says so, in a box, naming the value to set. |
| Sign-in links point at `localhost` | Same cause, same fix. |
| Links say `:4000` when you are behind Cloudflare or nginx | `SLIPDOCK_URL_SCHEME` and `SLIPDOCK_URL_PORT` describe how people reach it, not how the container listens — so `https` and `443`. `setup.sh` asks this. |
| Refused from `app.example.com` while `PHX_HOST` is `example.com` | They are different hostnames. Use the one in the address bar, or list the rest in `SLIPDOCK_CHECK_ORIGIN`. |
| You set `PHX_HOST` and nothing changed | Either `docker compose restart` (which re-reads nothing — use `up -d`), or a shell variable that was never exported. `echo $PHX_HOST` lies about that; `env \| grep PHX_HOST` does not. The container prints what it actually got: `docker compose logs slipdock \| grep entrypoint:`. |
| Reached by more than one name | Keep the main one in `PHX_HOST`, list the rest in `SLIPDOCK_CHECK_ORIGIN=a.example,b.example`. |

---

← [Running](running.md) · [Contents](../manual.md) · [Running it for other people](running-it-for-other-people.md) →
