[Slipdock — the manual](../manual.md)

## Running

### With Docker

Nothing but Docker needed — no Elixir, no Node, no database server, and nothing
to compile: the image is published to `ghcr.io/dadamsuk/slipdock`.
[Docker, step by step](docker-step-by-step.md) has the step-by-step version,
including upgrades, backups and what to do when something is wrong.

```sh
docker compose up -d
docker compose logs -f          # the setup token and sign-in codes are in here
```

Open <http://localhost:4000>. A server nobody has claimed shows a **setup
wizard**, which asks for a token printed in the log on first boot — so that
finding the page first is not enough to claim somebody else's server. It asks
who may register, how mail goes out and who the admin is, then disappears for
good. `SLIPDOCK_ADMIN_EMAIL` skips it entirely.

Everything that must survive an upgrade is on two volumes: `slipdock-db` is
the Postgres database, and `slipdock-data` holds uploaded files, each person's
OpenRouter key, and a `SECRET_KEY_BASE` the container generates for itself on
first run. Those volumes are the thing to back up — the database with
`pg_dump`, which is consistent and restorable into a later Postgres.

Settings go in a `.env` beside `compose.yaml` — copy `.env.example`, which lists
every variable with its default. The ones that matter first:

```sh
PHX_HOST=slipdock.example.com     # the address people use; sign-in links are built from it
SLIPDOCK_PUBLISH=4000             # every address; unset, 127.0.0.1:4000 only
SLIPDOCK_ADMIN_EMAIL=you@example.com               # skips the setup wizard
SLIPDOCK_SMTP_HOST=smtp.example.com               # so codes are emailed rather than logged
```

Behind a TLS proxy, set `SLIPDOCK_URL_SCHEME=https` and `SLIPDOCK_URL_PORT=443` so
the links the app builds point at the proxy. If people reach the server by more
than one name, list the others in `SLIPDOCK_CHECK_ORIGIN` or live updates will be
refused for the names you did not mention.

A release has no `mix`, so the two administrative tasks are on the entrypoint:

```sh
docker compose run --rm slipdock setup --status              # what this server allows
docker compose run --rm slipdock setup --admin you@example.com
docker compose run --rm slipdock setup --sign-in-link you@example.com
docker compose run --rm slipdock setup --make-admin you@example.com   # no admin can get in
docker compose run --rm slipdock ai-key                      # who has an OpenRouter key
docker compose run --rm slipdock ai-key you@example.com sk-or-…
docker compose run --rm slipdock welcome you@example.com     # the Getting Started tour board
docker compose run --rm slipdock reindex                     # rebuild the search index
docker compose run --rm slipdock migrate                     # migrations, by hand
docker compose run --rm slipdock remote                      # an IEx shell in the app
```

`docker run` on its own works too
(`docker run -p 4000:4000 -v slipdock-data:/data ghcr.io/dadamsuk/slipdock`).
The image does not force HTTPS, on the assumption that something in front of it
terminates TLS; build with `--build-arg SLIPDOCK_FORCE_SSL=true` if the app
itself should.

### From a checkout

```sh
mix setup          # deps, database, seeds, assets
mix phx.server     # http://<tailscale-ip>:4000
```

In development the server binds to this machine's Tailscale IPv4 (found via
`tailscale ip -4`). Override with `SLIPDOCK_BIND_IP=0.0.0.0` (all interfaces) or
`SLIPDOCK_BIND_IP=127.0.0.1` (loopback), and `PORT` to change the port.

The AI features run on **each person's own key, or their own endpoint**, set
under **Account → Preferences → AI model** in the web UI (`slipdock ai-key <key>`
and `slipdock ai-endpoint <url>` from the CLI, `mix slipdock.ai_key <email>
<key>` on the server). Both are kept in one JSON file, `ai_keys.json` in the
app's directory, `0600`, outside the database — `SLIPDOCK_AI_KEY_FILE` moves
it, and it holds secrets in the clear, so back it up like a `.env`. Somebody
with neither gets no AI features: the chat drawer, the narrative generator and
the rest stay hidden, and `/api/ask` says what is missing.

### A local model instead

Everything here speaks the OpenAI-compatible `/chat/completions` API, which is
what OpenRouter speaks and so does every local model server — **LM Studio**,
**Ollama**, **llama.cpp**'s server, **vLLM** — as well as most company
gateways. Point *Account → Preferences → AI model* at one:

| Field | What it is |
| --- | --- |
| Endpoint | The API root, the part before `/chat/completions`: `http://llm.local:1234/v1` (LM Studio), `http://llm.local:11434/v1` (Ollama). A trailing slash, or a pasted `/chat/completions`, is trimmed for you. Empty means this server's default |
| API key | Optional. Most local servers want none, and none is sent if you leave it empty. The server's shared OpenRouter key is **never** sent to an endpoint of yours |
| Model | *List models* asks the endpoint what it has (its `/models`, the same list `slipdock ai-models` prints) and offers them in a picker. Save the endpoint first — the list comes from what is stored |
| Embedding model | Only if the endpoint serves one, and only read for the account that indexes (Configuration → AI for search and automations). Changing it invalidates every stored vector: reindex (`docker compose run --rm slipdock reindex`, or `mix slipdock.reindex --force` from a checkout) |

An endpoint of your own is enough on its own — with one set, the AI features
turn on whether or not you have a key, because a box on your own network has
nothing to bill. A model id matters, though: an OpenRouter id (`google/…`)
means nothing to a local server and the other way round, which is what the
picker is for. A server running several models at once will say so rather than
guess, if you have picked none.

To make a whole instance local, set `SLIPDOCK_AI_BASE_URL` (and
`SLIPDOCK_AI_MODEL`) instead: everybody who has not chosen for themselves then
uses it, no keys anywhere, and no board content leaves the network.

### The server's models, and fallbacks

Somebody who hasn't picked a model of their own asks the **server's**.
An admin sets those under **Configuration → AI** (`/config/ai`, or
`slipdock admin set ai_model=… ai_quick_model=… ai_organise_model=…
ai_fallback_models=a,b`):

| Setting | What it is |
| --- | --- |
| Default model | Chat, AI edits, the narrative generator and everything else |
| Quick model | The header's quick add. Empty: the default model |
| Organise model | A folder's *Organise… → AI suggestions*. Empty: the quick model |
| Fallback models | OpenRouter models tried in turn when the model is rate-limited or down, separated by commas |

Each field shows the value in force and where it came from: set here, the
environment (`SLIPDOCK_AI_MODEL`, `SLIPDOCK_AI_QUICK_MODEL`,
`SLIPDOCK_AI_ORGANISE_MODEL`, `SLIPDOCK_AI_FALLBACK_MODELS`) or the built-in
default. Clearing a field goes back to the environment, then the default.
*List models* asks the server's endpoint for its list and offers the ids as
you type. Per call the order is: **a person's own model**, then the admin's,
then the environment, then the built-in default.

At the top of this section, and of Account → AI model, a warning reads
**Choose cheaper models where possible**: every call is billed to whoever's
key it runs on, and the cheap models do most jobs.

The fallbacks go to OpenRouter in its `models` array, primary first, so a
rate-limited model is replaced by the next without the person noticing. They
are sent only to OpenRouter and only with the server's own model. Somebody who
picked their own model or endpoint gets exactly that, with no fallbacks to a
model they didn't choose. Whichever model answered is the one logged,
shown under a narrative. A `429` is also asked
once more after a second, or after the endpoint's `Retry-After` when that is
5 seconds or less. A second `429` reaches the person as *The model is
rate-limited right now; try again in a moment.*

### AI for search and automations

Unattended work — the search indexer, every search query, scheduled
automations — has no person to bill, so it uses a *system* key: one admin's
AI settings. Choose whose under **Configuration → AI for search and
automations** (or `slipdock admin set ai_system_user=<email>`; empty clears
it). The page says what is in effect now and why. Only admins can be chosen,
and someone demoted or disabled since stops being used at once.

With nobody chosen, the older rules decide, in order:
`SLIPDOCK_AI_SYSTEM_USER=<email>` names whose key to spend; and on a
one-person install — registration closed, and the only stored settings an
enabled admin's — those are used without being asked for. That last one
switches itself off the moment registration opens or a second person saves
a key, which is the usual reason search suddenly says it isn't set up.
Nothing else is guessed: the indexer sends every board through the system
settings, so one person's own endpoint never receives them unless an admin
named that person. `OPENROUTER_API_KEY` still works and beats all of these,
but it is now a **shared** key for everyone on the server, which is rarely
what you want.

Other settings come from the environment or a `.env` file (`KEY=value` lines)
in the project directory or its parent — `SLIPDOCK_ENV_FILE` names another
location, and the systemd unit reads the same file. **`.env.example` lists every
variable the app reads, with its default**, so an empty `.env` is already a
working configuration and nothing in the repo assumes a particular machine.
`SLIPDOCK_AI_BASE_URL` moves the default endpoint for everyone (default
`https://openrouter.ai/api/v1`; a local endpoint needs no key, so this is how
an instance becomes local-first). `SLIPDOCK_AI_MODEL` picks another model
(default `google/gemini-2.5-flash-lite`, chosen for price — change it with the
endpoint, since the ids do not carry over) and `SLIPDOCK_AI_QUICK_MODEL`
one for the header's quick add alone, where latency matters more than depth
(it falls back to `SLIPDOCK_AI_MODEL`). `SLIPDOCK_AI_ORGANISE_MODEL` is the
one a folder's **Organise… → AI suggestions** asks (default
`anthropic/claude-haiku-5.5`; with `SLIPDOCK_AI_BASE_URL` set and this unset,
it falls back to the quick model). `SLIPDOCK_AI_FALLBACK_MODELS` lists
OpenRouter models to fall back to when that one is rate-limited
(comma-separated, none by default). An admin's choice under Configuration → AI
wins over all four. `SLIPDOCK_AI_EMBED_MODEL` and
`SLIPDOCK_AI_EMBED_DIMENSIONS` pick the embedding model behind deep search;
reindex after changing either (`docker compose run --rm slipdock reindex` on a
release, `mix slipdock.reindex` from a checkout). Restart the server after
changing any of them.

Automation emails link back to the board; set `SLIPDOCK_BASE_URL` when the
address people use isn't the one the endpoint is configured with (behind a
proxy, say). Real mail needs `SLIPDOCK_SMTP_HOST` — without it, sent mail
stays in the in-memory mailbox at `/dev/mailbox`. The relay's TLS certificate
is verified against the system CA store and the relay's name; a relay with a
self-signed certificate needs `SLIPDOCK_SMTP_TLS_VERIFY=false`.

---

← [Roadmap features in the API and CLI](roadmap-features-in-the-api-and-cli.md) · [Contents](../manual.md) · [Docker, step by step](docker-step-by-step.md) →
