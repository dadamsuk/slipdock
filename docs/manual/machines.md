[Slipdock — the manual](../manual.md)

## Machines

A **machine** is a computer of yours that runs Slipdock's
[runners](runners.md) through one program, the **runner daemon**
(`slipdock-runner`). You enrol the machine once; after that its runners are
added and changed from the board, not from a shell on the machine, and the
machine's own **ceiling** limits what the board may set.

The daemon is being built in steps (epic #2569). What is here today:
enrolling a machine, its ceiling (and `boards`, which changes the boards in
it), `show`, `doctor`, `status`, `log` and
`config` (the machine read from its own files), the service, signed
releases that it updates itself from, running its runners' jobs, and the
Machines page where its runners are set, taking changes made there while
it runs. It replaced the shell and PowerShell runners, which this server no
longer serves (#2582, [Runners](runners.md)): a machine still running one
moves over as the runbook *Moving a machine's runners onto the daemon* (in the
maintainers' handbook) says.

A board's **Automations → Connect a runner** offers *A machine with the
daemon* first: its steps make a one-time enrolment key for the board and
give you the `init` line with it.

### Getting the daemon

On Linux (WSL included) or macOS:

```sh
curl -fsSL https://github.com/dadamsuk/slipdock/releases/latest/download/install.sh | sh
```

On Windows, in PowerShell:

```powershell
irm https://github.com/dadamsuk/slipdock/releases/latest/download/install.ps1 | iex
```

Each fetches the latest release's `release.json` (every platform's binary
with its SHA-256) and its signature, checks the signature against the
project's release key written into the installer, and only then downloads
the binary for your machine, checks its SHA-256 against the signed list, and
puts it in `~/.local/bin` (on Windows, `%LOCALAPPDATA%\Programs\slipdock-runner`).
`SLIPDOCK_RUNNER_BIN` puts it elsewhere, and `SLIPDOCK_RUNNER_SOURCE` takes
the release from another host. That host must be `https://`: a plain
`http://` one is refused unless you say so, with `--allow-http`
(`curl -fsSL <url> | sh -s -- --allow-http`) or, on Windows, `-AllowHttp`
(`& ([scriptblock]::Create((irm <url>))) -AllowHttp`). Anything that doesn't verify is
refused, and nothing is installed. The check is `ssh-keygen -Y verify`, so
the installers need OpenSSH 8.1 or later, which macOS, current Linux
distributions and Windows 10 and 11 have (on Windows, the *OpenSSH Client*
optional feature).

**First-install trust is download trust.** The key the installer checks
against comes inside the installer, so the first install is only as
trustworthy as the download of the installer itself, from GitHub over
HTTPS. Nothing can do better than that for a first download. From then on
it is better: the daemon checks every update against the key built into
it, whichever host serves the update.

To build it yourself instead, with Go 1.24 or newer (a build of your own
has no release key, so it never updates itself):

```sh
cd daemon && go build -o ~/.local/bin/slipdock-runner ./cmd/slipdock-runner
```

It is one file with no dependencies, for Linux (WSL included), macOS and
Windows, on amd64 and arm64.

### Updates

The daemon keeps itself current. When it starts, and every six hours after,
it fetches the latest release's `release.json` and its signature and checks
the signature against the **project's release key, which is built into the
binary**. Only a release signed with that key, and newer than the one
running, counts. The binary for the machine is then checked against the
SHA-256 in the signed list before it replaces the running one.

- **`auto`** (the default): the update is installed, and the daemon exits so
  the service starts the new version. Found at start, that is before any
  runner takes a job. Found by a later check, the runners take no more
  jobs, each one finishes the job it holds, and the daemon exits once they
  are all idle: an update never cuts a job short. The log says
  `restarting once the jobs they hold have finished`, then `the runners are
  idle`. A config change that comes meanwhile waits for the new version.
- **`manual`**: the daemon only logs that a newer version exists, and
  `slipdock-runner update` installs it when you choose.

```sh
slipdock-runner update --check        # is there a newer release?
slipdock-runner update                # install it now
slipdock-runner update --mode manual  # or auto
slipdock-runner update --source URL   # where releases come from; default puts back GitHub's
```

Releases can come from anywhere, a mirror or a self-hosted server, because
what is checked is the signature, not the host. A host can hand out a
release, but it can't make one. A **refused** update, whether its signature
doesn't verify, its binary has been changed or its manifest isn't the
project's, leaves the running binary as it was. The refusal is logged
(`REFUSED an update from …`) and kept in `update.json` in the daemon's
directory, and `show` and `doctor` report it until a check succeeds
(`doctor` as a `FAIL`). An older release is never installed over a newer
one.

The release key is in the repository, `daemon/internal/release/release_key.pub`.
The private half is held by GitHub Actions in a protected environment, and
only a release tag can use it. A signature is an OpenSSH one, so you can
check a release by hand:

```sh
printf 'slipdock-release namespaces="slipdock-runner" %s\n' "$(grep '^ssh-ed25519' release_key.pub)" > allowed_signers
ssh-keygen -Y verify -f allowed_signers -I slipdock-release -n slipdock-runner \
  -s release.json.sig < release.json
```

### Enrolling a machine

```sh
slipdock-runner init
```

`init` asks for the server's address (`--server URL` skips the question),
then prints a short code and a link to the approval page, and opens it in
your browser when it can (`--no-browser` doesn't). The address must be
`https://`: the machine key comes back over it, so a plain `http://` one is
refused, even on this machine, unless you pass `--allow-http` (a development
server). It also prints the
machine's **fingerprint**: check the approval page shows the same one before
you approve, so you know it is this machine you are letting in. On the page
you choose the boards the machine may serve, from the boards you own or can
write to.

When you approve, the daemon receives the machine's key and keeps it in its
directory, readable only by you. The key lets the machine claim and report
on its own runners' jobs and nothing else: it is not an API token. Revoking
the machine on the Machines page ends it at once.

On a machine with no browser to hand, make a one-time **enrolment key** on
the Machines page (`slipdock machine enrol-key <board>… --label NAME`) and give it to `init`.
The name you give the key is the name the machine enrols under; without one it
takes its hostname. The page shows the key once, as the whole `init` line with
a **Copy** button beside it:

```sh
slipdock-runner init --server https://slipdock.example.com --key sdk_…
```

Rename a machine on its page (the Name field), or with `slipdock machine rename
<id> <name>`. Its hostname, as the daemon reported it, stays as it was. The
boards it serves can change later too: see
[Changing the boards a machine serves](#changing-the-boards-a-machine-serves).

A machine that is already enrolled refuses a second `init`; `--replace`
enrols it again (revoke the old one on the Machines page).

`init` also asks who jobs run as (below): a dedicated account, or you.
`--user NAME` and `--as-me` answer it on the command line.

### Set up this machine with Claude

At its end `init` asks whether to set the machine up with Claude now. Say
yes and it starts Claude Code as the account the machine's jobs run as
(with a dedicated account, `sudo -u <account> -i claude …`, in place of the
plain shell as the account; otherwise as you), with a prompt from the server that reads each board's **machine-setup
page**: the handbook's Testing & tooling page, section Local setup, where
`### A runner machine` says what a machine needs. Claude checks what the
machine has, installs what's missing (asking before anything that needs
`sudo`), proves it by cloning the repository and running its suite from
the clean checkout, then corrects the page where it was wrong and tells
you what it did. A board whose handbook has no such section gets one
written.

`slipdock-runner setup` does it later (`--print` shows the prompt alone),
`init --no-setup` doesn't ask (nor open the shell), and the machine's page has the same prompt
under **Set up this machine with Claude**, to paste into Claude Code there
(`slipdock machine setup-prompt <id>`). It needs Claude Code (`claude`) on
the machine; without it, install it and run `slipdock-runner setup`.

The daemon's directory is `slipdock-runner/machine` under your config
directory (`~/.config` on Linux, `~/Library/Application Support` on macOS,
`%AppData%` on Windows), or `$SLIPDOCK_RUNNER_HOME`, or `--home DIR` on any
command. It holds `machine.json` (the server and the machine's id),
`machine-key`, `identity` (the key pair the fingerprint comes from),
`ceiling.json`, `local.json` (below), `jobs/` (each runner's log of its
current job), `config-cache.json` (the settings last accepted),
`changes.log` (every change to them) and `update.json` (how updates go,
and the last check).

### The ceiling

The ceiling is the machine's own limits on what the board may configure. It
is a file on the machine, `ceiling.json`, which the server never reads or
writes; only someone at the machine changes it.

| Field | What it limits | `init` proposes |
|---|---|---|
| `roots` | the directories a runner may work in | your source folder (`~/src`, `~/dev`, `~/code`, `~/projects` or `~/repos`, whichever is there) |
| `agents` | the agents a runner may run: `claude`, `codex`, or a custom command defined on the machine | `claude` |
| `max_permission_mode` | the highest permission mode (`plan`, `default`, `acceptEdits`, `bypassPermissions`) | `acceptEdits` |
| `max_timeout_minutes` | the longest a job may run | 60 |
| `boards` | the boards the machine serves | the ones chosen on the approval page; `slipdock-runner boards add\|remove` changes them later |
| `executors` | who a runner's jobs may run as (below) | `user` with a dedicated account; `me` and `confined` without one (`me` only on Windows) |
| `container_images` | the images a `container` runner may run (below) | none: no image runs until you list one |
| `tiers` | what a job may do by who wrote its card: its executor, permission mode and network, `allowlist` included (below) | none: every job runs as its runner says |
| `owner_keys` | the board owners' passkeys pinned here: with any, only a card its owner signed runs at the `owner` tier (below) | none; `init` offers to pin them, `slipdock-runner trust-owner` does it later |
| `owner_signature_max_age_days` | how old an owner's signature may be | 30 when left out |

`init --root DIR --agent NAME --max-mode MODE --max-timeout MINUTES` sets
them as it writes the file (`--root` and `--agent` repeat). `init --replace`
keeps a ceiling already there unless one of those flags is given. A setting
from the board outside the ceiling is refused on the machine, and the runner
keeps its last accepted settings.

A running daemon reads `ceiling.json` again within a minute of it changing,
with no restart: a runner the new ceiling allows starts, one it leaves out
takes no more jobs once the one it holds has finished, and the change goes
into `changes.log` (`ceiling changed at this machine: boards [3] → [3 5]`).
An edit that isn't a valid ceiling is logged and ignored, and the one in use
stays.

#### Trust tiers

Anyone who can write or comment on a board a runner serves puts words in
front of its agent. So each job carries a **trust tier**: the least-trusted
author of the text in its prompt (the card's title, description and bar,
the rule that queued it, a rejection, a wait's answer, a handoff).

| Tier | Who wrote all of it |
|---|---|
| `owner` | the owner of the card's board, or the server itself |
| `member` | someone else who may write or comment on the card |
| `anyone` | anyone else: a permitted email sender, someone whose access has gone |

Text an agent writes counts at its job's tier, not its login's: an agent
using the owner's login, in a `member` job, leaves the card it rewrites at
`member`. An agent that names no live job of that person's (the CLI sends
it when it runs under a runner job) counts as a `member` at most. A
person's own edit, in the web or the CLI, counts as theirs. Their own
integrations other than the plain CLI (a script calling the REST API with
their token, an MCP client) count as agents, so what they write is
`member` at most.

The server only reports the tier; `tiers` in `ceiling.json` decides what
each gets. Each entry may set the `executor` the job runs under (one the
ceiling's `executors` offers), the `max_permission_mode` it is held to (at
most the ceiling's own) and the job's `network`: `on`, `off` (only under
`container`) or `allowlist` (below). A field left out keeps the runner's
own.

```json
"tiers": {
  "owner":  {"executor": "me", "max_permission_mode": "acceptEdits"},
  "member": {"executor": "container", "network": "on"},
  "anyone": {"executor": "container", "network": "off", "max_permission_mode": "plan"}
}
```

With `tiers` set, a job whose tier has no entry is refused before
anything runs, and one from a server that doesn't say its tier counts as
`anyone`. A tier's `container` executor runs the runner's own `image`,
which must be on `container_images`. A ceiling without `tiers` runs every
job as its runner says, but for its after hook (below).

**Where the after hook runs** (#3518). The after hook runs what the
agent wrote (a test suite, a build), so it is held by the job's tier,
with or without `tiers` in the ceiling:

- an `owner` job's after hook runs as the runner says, as before;
- a `member` or `anyone` job's runs in a container of its own, from the
  runner's `image` (on `container_images`), with the job's network: under
  an allowlist, behind the job's proxy (Linux only). The agent still runs
  under the job's executor; a `container` job's hook runs in its own
  container, as ever;
- where that can't be (the ceiling offers no `container`, the runner has
  no allowed `image`, or the runtime isn't there), a `member` or `anyone`
  job of a runner with an after hook is refused before anything runs, and
  its log says why.

The hook's program is then the image's or the repository's, as under
`container` (below); its exit code and output are reported as before.
On a machine that can't run a container, keep after hooks to runners
that only the owner's cards reach, or pin the owners' keys so a card's
tier is checked on the machine (*Cards signed by their owner*, below).

**What an `anyone` job's agent sees** (#3531). A build job at the `anyone`
tier never gets its card's text. At claim, the server has a model with no
tools read the text (title, description, bar, paths, a rejection, a wait's
question and answer, the handoff) and quote from it into fixed fields: the
requirement, the files it names, the expected behaviour, the bar's items,
the context and the open questions. The server checks every value: each
must be copied word for word from the text, a file must stay inside the
repository (no `..`, no `~`, no leading `/`), a link may appear only in the
context, and each field has a length cap. A value that fails is dropped.
The agent's prompt holds only these fields, under a header saying they are
quoted from an untrusted author, with the server's own paragraphs (how the
card ships, its list, the rules for working unattended).

The agent can't reach the text another way either. Reading its own card
under the job (`slipdock card`, MCP `get_card`) gives the same quoted
fields and none of the card's title, description, bar or comments. A view
of the job itself (`slipdock job`, `slipdock jobs`, the job lists in the
API) leaves its prompt and its card's title out, marked `text_withheld`,
for everyone but the board's owner, and for the owner too when the read is
made under a runner job. Owner and member jobs show as ever.

The job waits for a person instead of running, as a `security` wait on its
card, when the read speaks to an agent (a hidden comment, a note to AI
agents, an item telling the agent to run something), fails, comes back in
the wrong form, or finds no AI key on the server. It never falls back to
the text itself. Take out what was aimed at an agent and answer the wait,
and the card is sent again and read afresh. The read uses the server's
quick model and the key unattended work spends, once per version of the
text. It stops notes aimed at agents and smuggled paths; it does not stop a
hostile request written as the card's requirement, which the tier's
ceiling and a person reviewing the change still must.

##### A network allowlist

`"network": "allowlist"` lets a tier's jobs reach only what they need,
so a job can't send what it reads anywhere else. The daemon runs a small
proxy for each such job, on a random port of `127.0.0.1`, which lets
through only:

- the agent's model API: `api.anthropic.com` and `console.anthropic.com`
  for `claude`; `api.openai.com`, `auth.openai.com` and `chatgpt.com` for
  `codex` (a custom agent gets none: name its hosts);
- the Slipdock server the machine is enrolled with;
- the repository's `origin` (its host and port, `https` or `ssh`), and
  `api.github.com` when that is `github.com`, for `gh`;
- the tier's own `allow_hosts`: `host` (port 443), `host:port`, `*.host`
  for any name under it, and `localhost:port` for a port of the machine
  itself (a test database, say), which a confined job reaches directly.

```json
"tiers": {
  "owner":  {"executor": "me"},
  "anyone": {"executor": "confined", "network": "allowlist",
             "allow_hosts": ["registry.npmjs.org", "proxy.golang.org", "localhost:5432"]}
}
```

The job's `HTTPS_PROXY`, `HTTP_PROXY` and `ALL_PROXY` (in both cases)
name the proxy and `NO_PROXY` names `localhost`, so the agent, `git`,
`gh`, `curl` and the `slipdock` CLI go through it; git over ssh goes
through it too (`GIT_SSH_COMMAND` with a `ProxyCommand` of the daemon's
own binary). The proxy refuses everything else with `403`, and the job's
log says so once a host (`network allowlist: refused a connection to
example.com:443`); the log's first lines list what was allowed.

The sandbox stops a job going round the proxy:

- `confined` on macOS: `sandbox-exec` denies every outbound connection
  but to the proxy's port (and the `localhost:port`s) and unix sockets.
- `confined` on Linux: Landlock denies every TCP connection but to those
  ports. It needs Landlock ABI 4 (Linux 6.7); an older kernel refuses
  the job. Landlock's rules are by port, not address, and it doesn't
  cover UDP.
- `container` (Linux only): the container has no network
  (`--network=none`). The proxy's unix socket is mounted in, read-only, at
  `/run/slipdock-egress`, with the daemon's own binary at
  `/usr/local/libexec/slipdock-egress`, which runs the job and carries its
  connections to the proxy's port inside the container to the socket.
  The binary must be a static build (the release builds are); Docker
  Desktop and Podman on macOS can't run it, so there a container job under
  an allowlist is refused: use `confined`.

The daemon's own git for the job (its worktree's fetch) and the runner's
hooks are held to the same allowlist, and so is a verify job of the tier,
in its container. The origin is the one first seen
for the runner, kept in the daemon's own directory (`jobs/<runner>/
egress-origin`), because a job can rewrite its repository's
`.git/config`: if the origin changes, the job's log says so, and deleting
that file allows the new one. Name lookups aren't covered, and a job can
still send what it reads to an allowed host. Under any other executor a
tier's allowlist refuses the job.

##### Fake credentials as tripwires

A `container` job under an allowlist (a verify job of the tier too) finds
fake credentials in its home: a `~/.aws/credentials` with an access key
(`AKIA…`) and a secret, and a GitHub token (`ghp_…`) in
`~/.config/gh/hosts.yml`. They are made up for each job, shaped like real
ones, and work nowhere. Its proxy watches for them in what the job sends,
so a job that reads them and sends them on is caught:

- the daemon stops the job and finishes it failed, and its log says which
  value was seen, where and to what host (`tripwire: the job's fake
  credentials were seen leaving`);
- the server pauses the runner's pool (`paused by tripwire`), so none of
  its runners claims another job until a person resumes it, and raises an
  urgent alert on the board naming the job and its card.

This is detection, not prevention. The proxy sees a `CONNECT`'s target
and headers (a value hidden in a host name included), a plain `http://`
request's line, headers and body, and what a job sends through a tunnel
in plain text. It can't see inside TLS, so a value sent over `https` to an
allowed host passes unseen; nor a value the job changes first (encoded,
encrypted, split), nor a name lookup.

They go only where the job's home is its own: a container's home is an
empty, throwaway one. A `confined` job's home is yours, so it gets none
(the daemon never writes in your home), and nor do `me` and `user` jobs,
which have no proxy. A fake file never covers a login the machine mounts
in its place: when `container.login` names `~/.aws` or `~/.config/gh`
(or a file in them), the real one is mounted and that tripwire is left
out. With no `GH_TOKEN`, `gh` in the container reads the fake token and
fails to sign in, as it would have with none.

#### Cards signed by their owner

The server works the tier out, so `owner` is only as good as the server's
word. The owner of a board can make it more than that for a card: **Sign
with passkey** on the card (under the bar, for the owner only) signs its
title, description and bar with one of the owner's passkeys, one tap. The
card then shows *Signed by the owner* and the date; any change to those
three fields, by anyone, shows *Edited since it was signed* until the owner
signs it again. While editing the description or the bar, the owner also
has **Save and sign** beside Done: it saves the text, then asks for the tap
straight away. Comments, answers and handoffs are never signed.

What is signed is the card's text byte for byte, with the server's address,
the card's number and when it was signed, so a signature can't be moved to
another card or another server. A runner holding the card's job fetches the
signed text uncut and the passkey's signature from
`GET /api/runner/jobs/:id/intent`, and `GET /api/runner/owner-keys` lists
the owner's passkeys with a fingerprint each (also in `slipdock passkeys`),
for the person at the machine to compare and pin. A machine that checks
the signature against a key it pinned knows the text is the owner's even
if the server, an agent using the owner's login or a leaked token wrote
otherwise. It doesn't protect against a compromised server, which serves
the page that asks for the tap.

To have a machine check it, pin the owners' keys there:

```sh
slipdock-runner trust-owner         # shows each owner's passkeys and their fingerprints, asks, pins
slipdock-runner trust-owner --yes   # the same without asking, for scripts
```

It asks the server, through each of the machine's runners, for the
passkeys of the owner of that runner's board, shows each one's name,
algorithm and fingerprint (worked out on the machine from the key itself),
and writes the ones you confirm into `ceiling.json` as `owner_keys`, with
the server's origin and relying party id. Compare the fingerprints with the
owner's own list first (their account page, or `slipdock passkeys` signed
in as them): the keys are as good as the server's word at that moment. Run
it again after the owner adds or removes a passkey; it unpins the keys the
owner no longer has. `init` offers the same step at its end (skip it with
`--no-trust-owner`; it needs a runner, so after enrolment it usually waits
for `trust-owner`). The server never writes `owner_keys`.

With keys pinned, a job the server says is `owner` tier fetches the card's
signed text and checks the signature itself: its own SHA-256 of the text as
the challenge, the pinned key's origin and relying party, the owner present
and verified, and signed within `owner_signature_max_age_days` (30 by
default). If anything fails (the card is unsigned or edited since, the key
isn't pinned, the signature is old or doesn't verify, the server doesn't
answer), the job runs under the `member` tier's limits instead, and the
daemon's log and the job's say why. A signature never lifts a job above the
tier the server gives it. With no `owner_keys`, nothing changes. `doctor`
warns about a pinned key the owner's account no longer has, and about keys
pinned with no `tiers` for them to matter.

#### What a job reads while it runs

A job's agent reads more than its prompt: it looks cards up with
`slipdock card` or MCP `get_card` as it works, and a comment may have been
written after the job was claimed. Those reads name the job (the CLI sends
`$SLIPDOCK_JOB_ID`; an MCP server entry can send it as the
`x-slipdock-job` header), and the server holds them to the claim:

- the job's own card comes back as it was when the job was claimed: its
  title, description and bar as the claim saw them, and none of the
  comments written since;
- a card whose text has an author less trusted than the job's tier marks
  the job, for the rest of its run. The job shows `marked_at` and why.

A Claude Code agent gets a `PreToolUse` hook from the daemon,
`slipdock-runner hook pretooluse`, which asks the server whether its job
is marked before each shell (`Bash`, `PowerShell`, `Monitor`), web
(`WebFetch`, `WebSearch`) or MCP call (Slipdock's own MCP aside, so the
agent can still report). Once the job is marked, the hook refuses those
calls, and with the shell goes pushing; when it can't reach the server, it
refuses them too. Reading, editing and writing files carry on. A job that
reads only text as trusted as its own is never marked and never held
back. The hook isn't given to a `container` job (its image hasn't the
daemon), and under `user` the dedicated account has to be able to run the
daemon's binary.

#### Changing the boards a machine serves

A machine's boards can change after it is enrolled, without enrolling it
again or touching its other runners (#3249). Two places say which boards it
serves, and both must list a board before the machine takes its jobs:

- **The server.** On the machine's page, under **Boards**, **Add board**
  offers the boards you could choose at approval (top-level boards you own
  or can write to), and **Remove** takes one off. Or `slipdock machine
  boards <id> --add <board> --remove <board>` (each repeatable, ids or
  codes), or `PATCH /api/machines/:id` with `add_boards` and
  `remove_boards`. Only the machine's owner changes them. A board that still
  has runners on the machine is refused, naming them: remove those first
  (each finishes the job it holds). The last board can't be removed: revoke
  the machine instead. Each change is in the machine's **changes**.
- **The machine.** The ceiling is the machine's own, so the server can't
  add a board to it. A board added on the server is marked *not in the
  ceiling* on the page, with the command to run at the machine, and its
  runners are refused there until someone runs it:

  ```sh
  slipdock-runner boards              # the boards in the ceiling
  slipdock-runner boards add 115      # add one (or several)
  slipdock-runner boards remove 3     # take one out; the last stays
  ```

  It edits `ceiling.json` and keeps every other field as it was. A running
  daemon picks it up within a minute.

Removing a board on the server alone is enough: the server sends nothing
for it. The page notes a board still in the ceiling, with the `remove` line
to tidy it.

### Who steers a runner's agent

Anyone who can write or comment on a board a runner serves can steer its
agent (#3481). The card's text, its bar, its comments and its handoffs go
into the agent's prompt, and the agent follows them as the account its
jobs run as. Every job's prompt tells the agent that card text is data,
not instructions, but telling a model is not a limit. The limits are the
runner's:

- **The executor**: `me` stops nothing, so the agent can read and change
  whatever you can; `user` keeps it out of your home; `confined` stops it
  writing outside the job's directory; `container` stops it reading or
  writing outside what is mounted, and the network when that is off
  ([What each executor stops](#what-each-executor-stops)).
- **The permission mode**: `plan` changes nothing, `default` asks before
  an edit or a command, `acceptEdits` edits files without asking, and
  `bypassPermissions` runs any command without asking.

So share a runner's board only with people you would let use the machine
that way. `slipdock machine add-runner` prints this when it adds a runner,
the Machines page shows it above the runners, and the machine's setup
prompt asks Claude to tell you.

### Who jobs run as: executors

Each runner names an **executor**, and the ceiling's `executors` say which
ones the machine allows. A runner set to one the machine doesn't allow, or
that can't run here, is refused, and its jobs never run under a weaker one
in its place. When a job's executor isn't ready (the account's `sudo` rule
is gone, say), the job fails before anything starts, and its log says why.

| Executor | Jobs run as | What it stops | What it doesn't |
|---|---|---|---|
| `user` | a dedicated account, `slipdock` by default, with its own home, clones and logins | reading your home: a job is refused while your home is open to the account | reading what every account can, writing its own home and `/tmp`, the network |
| `confined` | you, unable to write outside the job's directory | writing anywhere else: your home, other repositories, the system; under a tier's network allowlist, reaching any host off it | reading your files, the network (but for an allowlist). It may also write its own temporary directory, the terminal devices and the agent's own state (`~/.claude` for `claude`) |
| `me` | you, as you are | nothing: an agent can read and change what you can | |
| `container` | you, in a short-lived Docker or Podman container from an image on the machine's allow-list | seeing anything not mounted: your home is an empty one; writing outside the job's directory and repository; the network, when the runner turns it off; any host off a tier's network allowlist (Linux) | the network when it is on; what the mounted logins allow; the image itself, and the runtime (an account in the `docker` group is root on the machine) |

`init` asks which, and says what each does and doesn't stop:

- **A dedicated account** (recommended for an always-on machine: a build
  box, a WSL instance). `init` makes the account if it isn't there and adds
  a `sudoers` rule (`/etc/sudoers.d/slipdock-runner-<account>`) that lets
  you run commands as it without a password, with one `sudo`. If your home
  is open to other accounts it offers to close it (`chmod o-rwx`, and
  `g-rwx` on macOS, where every account shares the home's group). Then it
  opens a shell as the account (`sudo -u slipdock -i`; `--no-setup` skips
  it) where you sign in to the agent and to GitHub and clone your
  repositories: the account's home holds them, and the ceiling's `roots`
  start in it. A job gets the account's own environment, nothing of the
  daemon's. The machine allows `user` only, so the board can't move a
  runner back to running as you.
- **You**, for a laptop that is only yours (`--as-me`). The machine allows
  `me` and, on Linux and macOS, `confined`.

`confined` uses Landlock on Linux (ABI 3, kernel 6.2 or later, which also
refuses truncating a file outside) and `sandbox-exec` on macOS: nothing to
install. A job may write its repository, `.git` included, so the daemon's
own git for the runner (its worktrees, the built-in merge) and the runner's
hooks run confined too, able to write only the repository and its worktrees:
git config or a hook the job planted there runs inside the same walls.
`confined_writable` in the local file lists more paths a confined job may
write.

**A card's paths.** When a confined or container job runs in a worktree
and its card has paths (`slipdock edit <id> --paths`), it may write only
those in the worktree, as they were when the job was claimed: not the
rest of the worktree (CI workflows, say, unless the card names them), not
the worktree's `.git`, and not the main checkout. Of the repository's
`.git` it may write only what a commit needs: its `objects`, `refs` and
`logs` and the worktree's own git directory; never its `config` or its
`hooks`. Landlock and a bind mount grant directories and files, so each
glob grants one: its deepest fixed directory (`lib/foo/**/*.ex` grants all
of `lib/foo`, made if it isn't there), or, with no wildcard, the path
itself when it is there and else the directory it would be in. A glob with
no fixed directory (`*.md`, `**/x.ex`, a new file at the top) grants the
whole worktree. A glob that is absolute, has a `..`, names `.git` or
leads through a link out of the worktree grants nothing, and the job's log
says so, as it says what the job may write. The worktree's pointers to its
repository (its `.git` file, and `commondir`, `gitdir` and
`config.worktree` in its git directory) are put back when the agent ends,
before a hook or the daemon's own git reads them. A card with no paths
writes the whole worktree, as before; the hooks and the daemon's own git
are not kept to the card's paths; and under `me` and `user` the paths are
only what the skills' pre-commit check reads.

**Windows** runs jobs as the current account only (`me`): `init` says so and
doesn't ask, and neither `user`, `confined` nor `container` is offered there yet.

### Container

A `container` runner runs each of a job's processes (the agent, the hooks,
and the daemon's own git and `gh` for it) in a short-lived container:
`docker run --rm` or `podman run --rm`, from the image the runner names.
The image's name is data from the board, so the machine runs it only if it
matches its own allow-list, `container_images` in `ceiling.json`, which the
board can't change. With no list, no image runs. A pattern is an image name
in which `*` stands for any run of characters but `/`: `slipdock-agent:*`
allows every tag of that image, `ghcr.io/me/*` every image directly under
`ghcr.io/me`. Its first part (the registry, or the image's name) is written
out, so no pattern allows everything. An image not on the list is refused
with the reason, which the Machines page shows, and the runner keeps its
last accepted settings. Add `container` to the ceiling's `executors` too:
`init` doesn't offer it.

```json
{
  "executors": ["me", "container"],
  "container_images": ["slipdock-agent:*"]
}
```

What the container sees, each at the path it has on the machine:

- the job's directory (its repository), read-write; in a worktree, the
  worktree and its repository. When the card has paths, the agent's
  worktree and repository are read-only, with only the card's paths and
  what a commit needs read-write over them (see *A card's paths*, above).
  The hooks and the daemon's own git also see the repository's worktrees
  (`<repo>-lanes`).
- the agent's login and the slipdock CLI's, read-only: by default
  `~/.claude/.credentials.json` and `~/.claude/skills` for `claude`,
  `~/.codex/auth.json` for `codex`, and `~/.config/slipdock`, those that are
  there.
- the machine's `slipdock` CLI, read-only, over the image's, so the board's
  drift check reads what runs.
- for the agent alone (not the hooks or the daemon's own git), a fresh,
  empty directory of the job's own at `~/.claude/projects`, where Claude
  Code writes its transcript. It is made outside your home and the
  daemon's directory for each job, and removed when the job ends.
- a home at your home's path that is empty (a `tmpfs`) but for those.

It is refused, and the job fails before anything starts, if what it would
mount is your home, a directory holding it, the daemon's own directory or
the runtime's socket, or if a login isn't inside your home. Jobs run as
your account (`--user`), with every capability dropped and no new
privileges. Only the job's own `SLIPDOCK_*` variables and the agent's key or
token (`CLAUDE_CODE_OAUTH_TOKEN` and `ANTHROPIC_API_KEY`, or
`OPENAI_API_KEY`) pass in; the daemon's own `SLIPDOCK_*` variables never
do. The runner's `network` setting (`on` or `off`, from the board) turns
the network off (`--network none`); an agent that calls its provider's API
needs it on, and so does the built-in merge. A trust tier's `allowlist`
gives it only the hosts it needs instead (see *A network allowlist*).

Under `container` the agent's and hooks' programs are the image's, found
on its `PATH`. The live transcript is sent as it is for any other job, read
only from the job's transcripts directory: the daemon opens nothing but
regular files beneath it (a link, a FIFO or a file over 128 MB the job
put there is passed over), so nothing the job plants can make it read the
machine's files.

The base image, `daemon/images/agent/Dockerfile` in the repository, has
Claude Code, Codex, the slipdock CLI, `git` and `gh`. Build it on the
machine and allow it:

```sh
docker build -t slipdock-agent:1 daemon/images/agent
```

A project's own toolchain goes in an image built `FROM` that one, whose
name then goes on the list. `local.json`'s `container` block (below) says
how the machine runs containers.

### What runs: the local file

The board names an agent and a runner's hooks; only the machine says what
those names run. `local.json`, in the daemon's directory, is where it says
so. Like the ceiling, the server never reads or writes it. Every field is
optional, and with no file at all `claude` and `codex` are found on your
`PATH`:

```json
{
  "agents": {
    "claude": {"path": "/opt/claude/bin/claude", "allowed_tools": ["mcp__slipdock"]},
    "lint": {"path": "/usr/bin/make", "args": ["lint"]}
  },
  "hooks": {
    "fresh-main": {"path": "/usr/local/bin/fresh-main.sh"}
  },
  "models": {"schema": "opus"},
  "runners": {
    "build1": {"env": {"MIX_TEST_PARTITION": "_build1"}},
    "verify": {"env": {"MIX_TEST_PARTITION": "_verify"}}
  }
}
```

- `agents`: `claude` and `codex` need an entry only when they aren't on the
  `PATH`, or when `claude` has tools a job may use without asking
  (`allowed_tools`: in a job nobody is there to approve one). Any other agent
  a runner names must be defined here. It gets the prompt as
  `$SLIPDOCK_PROMPT`, never on its command line.
- `hooks`: what a runner's before, after and probe hooks run, by name. A
  before hook that fails stops the job; the after hook runs however the job
  ended (in a container for a job below `owner` tier: *Trust tiers*,
  above), with `$SLIPDOCK_EXIT` and `$SLIPDOCK_STATUS` (`done`, `failed`,
  `cancelled`, `timeout`, or `requeued` when the agent couldn't run at all
  and the job went back to the queue: see
  [Runners](runners.md)). The probe hook runs at the end of a probe
  (below), and a probe whose hook exits non-zero is red.
- `models`: a model for a card's profile (`docs`, `fix`, `feature`,
  `schema`, `security`, `spike`), over the runner's own.
- `runners`: the machine's own settings for a runner, by the name the
  board gives it, exactly as written there. `env` is the variables that
  runner's jobs get, its agent, its hooks and its probe alike, under every
  executor (a container job gets them too). They come on top of what the
  daemon was started with, and under the daemon's own: `SLIPDOCK_*`, and
  `HOME`, `PATH` and the like, which each executor sets, are refused. Use
  it to keep runners that share the machine apart: with a
  `MIX_TEST_PARTITION` each, a builder's and a verifier's test suites
  never share a database. Runners that share a name share its entry, a
  name no runner has does nothing, and a rename on the board wants the
  same rename here. The file is read when the daemon starts, so restart
  the daemon after a change; `config --effective` shows each runner's
  `env` as the file has it now. It is a plain file anyone on the machine
  can read: not the place for a secret.
- `user`: the dedicated account (`name`, `home`, and the `path` its jobs
  get), which `init` writes. `confined_writable`: what a confined job may
  write besides its directory.
- `container`: how the `container` executor runs here. `runtime`
  (`docker`, `podman` or a path; default `docker`, else `podman`), `pull`
  (`never`, the default: the image must be on the machine; `missing` or
  `always` let the runtime fetch it), `login` (the paths mounted read-only,
  each inside your home, in place of the defaults; add `~/.config/gh` for
  the built-in merge) and `env` (the daemon's variables a job gets, in
  place of the agent's key or token; `SLIPDOCK_*` and the container's own,
  such as `HOME` and `PATH`, are refused). Which images may run is the
  ceiling's `container_images`, not this file's. `verify_image` is the
  image a verify job runs in when its runner isn't a `container` runner
  (#3522; a container runner's verify jobs use its own `image`).

**Verify jobs run in a container** (#3522), whatever the runner's
executor: a machine whose ceiling offers `container` and has an image for
them (`container.verify_image`, on `container_images`) takes them, and
any other machine's runners don't say they take `verify`, so the board's
verify jobs go to one that can. The daemon fetches `origin` with the
machine's git and makes the job its own clone of the repository at the
submitted commit (never the runner's own repository, so nothing the job
writes reaches the daemon's git); on a board that ships by pull request it
reads the pull request's head, base and checks with the machine's `gh`,
waiting up to 30 minutes for running checks, and gives them to the job as
`$SLIPDOCK_PR_STATE` and `$SLIPDOCK_BASE`. The container mounts the
agent's own login alone (no `~/.config/slipdock`, `gh` login, `~/.ssh` or
`login` list) and passes in the agent's key alone; the job's token is
`$SLIPDOCK_TOKEN`, with `$SLIPDOCK_URL`, and a transcript never carries
it. A runner that isn't a container runner runs no hooks for a verify job.
The runner's own `network` and its trust tier's apply: a verify job needs
the network for its agent and its verdict.
- `transcripts`, `skills_dir` and `cli` say where Claude Code's
  transcripts, the slipdock skills and the `slipdock` CLI are, when they
  aren't in the usual places. `no_merge: true` turns off the built-in merge.
  `no_release: true` turns off the built-in release (a batched board's
  release job, which runs `gh workflow run <workflow> --ref <branch>` in
  the runner's repository), and `release_commands` lists, word for word,
  any other release command this machine will run for a board (in a
  detached worktree of the default branch, freshly fetched): a command
  that is neither is refused.
  `no_skills_update: true` stops the daemon putting the server's slipdock
  skills in `skills_dir` before each agent job, and `no_cli_update: true`
  stops it putting the server's `slipdock` CLI in its own `bin` folder (or
  at `cli`, when that is set) (see [Runners](runners.md), *Skill and CLI
  drift*). `cli_checksum_only: true` lets it install a CLI the server
  serves unsigned, checked only against the server's own checksum: by
  default only a CLI signed with the release key is installed.
  `skills_unsigned: true` does the same for the skills: by default only
  a skills archive signed with the release key is installed.
- `log_level`: how much goes in the daemon's log: `debug`, `info` (the
  default), `warn` or `error`. `run --log-level` overrides it.

A job whose agent or hook the file doesn't define fails before anything
runs, and its log on the card says which name was missing. A file with a
field the daemon doesn't know is refused, so a typo can't be ignored.

### How settings from the board arrive

The daemon keeps asking the server for the machine's runners, so a change
made on the board arrives within seconds, with no restart and no shell.
Each runner's settings are checked against the ceiling as they arrive:

- **Inside it**, they are accepted, and the Machines page shows the version
  taken. A runner whose settings changed takes them once the job it holds
  has finished. A new runner starts taking jobs at once.
- **Outside it**, they are refused, and the page shows why. The runner keeps
  the settings it last accepted, or doesn't run if it never had any. A pause
  is still taken, since it only narrows.
- **Paused or removed** on the board, a runner takes no more jobs. The job it
  holds finishes first.

What was accepted is kept in `config-cache.json`. A daemon that starts
while the server can't be reached runs from it, then takes the server's
settings once it answers. A runner that a narrower ceiling now leaves out
isn't started from the cache. Every change is written to `changes.log`,
one line each, with the time, the runner, the version, whether it was
accepted or refused (and why), and each field that changed, old and new:

```
2026-11-09T12:00:00Z runner builder (#21) v3 changed and accepted: permission_mode "default" → "acceptEdits"
2026-11-09T12:05:00Z runner builder (#21) v4 rejected, it keeps v3: directory "/etc" is not inside ~/src (directory "~/src/app" → "/etc")
```

### How the daemon runs a job

Each runner takes one job at a time. Its claims say
which kinds it takes (its agent's, `verify`, the built-in `merge` and the
built-in `probe`), and
which skills and CLI are installed, so the board shows drift. Before an
agent job (not a merge or a probe) it puts the server's skills and, when the
server's `/cli/SHA256SUMS` differs from the installed CLI, the server's
`slipdock` CLI in place, so a deploy needs no step on the machine: the
CLI goes in the daemon's own `bin` folder, beside its `jobs` folder, and
first on the job's PATH, never over a copy you installed elsewhere unless
`cli` in the local file names it. The CLI is installed only when its
signature (`/cli/slipdock.escript.sig`) verifies against the release key
built into the daemon. The release job signs the CLI of each `v*` tag; a
server built from source, or deployed from a commit the release job didn't
sign, serves none, and the machine keeps its own CLI unless the local file
sets `cli_checksum_only: true`. The skills are installed the same way,
only when their archive's signature (`/api/skills.tar.gz.sig`) verifies,
and a server that serves none leaves the installed skills in place unless
the local file sets `skills_unsigned: true`. While a job
runs, its log's tail goes to the board every 20 seconds and Claude Code's
transcript about once a minute, with this machine's keys and tokens taken
out. Cancelling the job on the board, or its timeout, stops it and every
process it started. With `worktree` on (or `auto`, when two runners share a
directory) each job gets a git worktree of its own, on the branch
`card-<id>`: it starts from the origin's default branch, fetched first,
never from whatever the runner's checkout has out. A card branch already
there catches up with it: one with nothing of its own is moved up to it,
and one with commits of its own (a rejected card's, here or only on the
origin) has them rebased onto it. A rejected attempt on the origin
(`origin/card-<id>`, pushed from another machine) wins over a local branch
with nothing of its own, or one it has moved on from; when each has
commits the other lacks, the local one is used and the job's log says the
origin's were not taken. If that rebase conflicts, it is undone,
the branch is left as it was, and the job's log says how far behind it is.
A worktree kept from an earlier job (it had uncommitted changes) is used
as it is. A runner alone in its
directory gets none under `auto`, so set `on` for a checkout people or
other tools also use. A merge job merges the card's pull request only if it is in the
runner's repository, still open, and at the accepted commit, and one that
changes the board's sensitive paths only once a person has approved that
commit (see *Sensitive paths* in the manual's Profiles page). A runner that
crashes is started again, and the machine's other runners carry on.

### The Machines page

**Account → Machines** lists your machines, and the machines of other
people that serve a board you're on. Each opens its own page, which shows:

- whether it is **online** (heard from in the last two minutes), its system,
  and when it was last seen;
- the **boards** it serves, each marked *not in the ceiling* where the
  machine's own ceiling doesn't list it yet, with the command to run there;
- its **ceiling** and the **executors** it offers, as the machine reported
  them: read-only, since only someone at the machine changes them;
- its **runners**: name, board, pool, agent, directory, permission mode,
  timeout, what it runs as, and its state (*ready*, *waiting for the
  machine*, *working* on a card, *paused* or *rejected*);
- each runner's latest **probe**: green with when it passed, or red with
  how it ended and the log it sent;
- a **refusal** in full: the setting the machine refused, its reason, the
  limit it crossed, and the version it still runs;
- a **warning** on a runner that lets its agent run any command as you
  (permission mode `bypassPermissions` with the `me` executor) on a board
  someone else can write or comment on, or mail: anyone who can do that can
  then have it run commands on the machine as you. Nothing is refused, and
  `slipdock machine add-runner`, `set-runner` and `show` print the same
  warning; the daemon logs one whenever it starts such a runner, shared
  board or not (#3482);
- the **changes**: every setting the machine accepted or refused, and each
  board added or removed.

On your own machine you can:

- **Add a runner**: the board (one the machine serves), the pool, and its
  settings: agent, working directory, permission mode, timeout, what it
  runs as, model, a worktree per job, how much it writes, standing
  instructions, and the names of a before, after and probe hook that the
  machine itself defines. A field outside the ceiling is marked with the
  limit as you type. You can still save it, but the machine will refuse it
  and keep the runner's last accepted settings.
- **Edit** a runner. The machine has the change within seconds and applies
  it between jobs.
- **Probe** a runner: it checks its own setup and shows green or red
  (below).
- **Pause** a runner: it is handed no job until you **Resume** it. The job
  it holds finishes.
- **Remove** a runner: the machine finishes the job it holds, then stops
  it.
- **Add** and **Remove** the boards it serves (see
  [Changing the boards a machine serves](#changing-the-boards-a-machine-serves)).
- **Update now**: the machine looks for a newer signed release at once,
  rather than waiting for its next check.
- **Revoke** the machine: its key stops working at once.

Someone who only shares a board with the machine sees the page with the
runners of their boards, and none of the buttons. From the command line:

```sh
slipdock machines
slipdock machine show 4
slipdock machine boards 4 --add my-other-board
slipdock machine add-runner 4 my-board --pool build --dir ~/src/app --timeout-minutes 30
slipdock machine set-runner 4 build-box-build --permission-mode plan
slipdock machine pause-runner 4 build-box-build
slipdock machine resume-runner 4 build-box-build
slipdock machine rm-runner 4 build-box-build
slipdock machine probe 4 build-box-build --wait
slipdock machine update 4
```

### Probing a runner

A **probe** checks that a runner is ready to work, from the board, without
a shell on the machine. Send one with **Probe** on the Machines page, or
`slipdock machine probe <machine> <runner>` (`--wait` follows it, and exits
1 if it is red). It is a job like any other, in the job list and kept as
long as any job's log, but it has no card and goes only to the runner it
was sent to, ahead of its pool's queue. A paused runner takes no probe:
resume it first.

The daemon runs each check, even after one fails, and writes a line for
each, `ok` or `FAIL`, to the probe's log, which reaches the board as it
runs:

- **directory**: the runner's directory is a git repository with an
  `origin`, which the log names, so you can see it is the one you meant;
- **agent**: the agent's program, from `local.json`, answers `--version`;
- **gh**: `gh` is installed and signed in;
- **skills and CLI**: the slipdock skills and CLI are installed and are the
  ones this server serves;
- **executor**: the runner's executor is one the daemon offers, and a
  command runs under it in the runner's directory;
- **probe hook**: the runner's probe hook, if its settings name one, from
  `local.json`, with the same `SLIPDOCK_*` variables a job's hooks get. Use
  it for the project's own checks, such as cloning and running the suite.
  A name the file doesn't define fails the probe.

The probe is **green** when every check passes, with the time it passed,
and **red** otherwise, with its log. Cancelling it or its timeout stops it,
and its hook, like any job.

### What the server can and cannot do

This is the **trust contract**. The same text is on each machine's page,
in Help › Agents, and in the API guide, and on the machine

```sh
slipdock-runner show
```

prints it after that machine's own limits: its ceiling, the executors it
allows and who a job runs as under each.

<!-- trust-contract: a copy of daemon/internal/contract/contract.md; edit that, then this -->
A Slipdock server queues work for the machines that run its runners. This
is what it can and cannot make such a machine do, and what none of this
protects you from. Read it before you install the runner daemon on a
machine. On the machine, `slipdock-runner show` prints it with that
machine's own limits.

#### What the server can do

- Queue jobs for the pools this machine's runners joined. Each job comes
  with a prompt: the card, and what the board's members wrote for the
  agent to do.
- Set each runner's settings: its pool, agent, working directory,
  permission mode, timeout, model, worktree, verbosity, standing
  instructions, executor, and the names of its hooks. These are data, not
  code, and they apply only inside the machine's ceiling. A setting
  outside the ceiling is refused on the machine, and the runner keeps the
  settings it last accepted.
- Start a release. On a board that releases in batches, a `release` job
  has a runner here run `gh workflow run <workflow> --ref <branch>` in its
  repository, as the account `gh` is signed in as. The board names the
  workflow file and the branch (by default the repository's default
  branch), and the daemon checks both as plain names before it uses them.
  `no_release: true` in `local.json` turns this off.
- Name a newer version of the daemon.

#### What the server cannot do

- Run a command on this machine. The daemon never runs anything the
  server sends. The agents, custom commands and hooks it can run are
  defined in files on the machine, and the server can only pick one of
  them by name. A board's release command is no exception: one that isn't
  the `gh workflow run` above runs only when `local.json` lists it, word
  for word, under `release_commands`; any other is refused and nothing
  runs.
- Change a hook or a command, or add one.
- Change the ceiling. It is a file on the machine (`ceiling.json`) that
  the server never reads or writes; only someone at the machine edits it.
- Set a working directory outside the ceiling's roots, an agent it
  doesn't list, a permission mode above its highest, a timeout above its
  longest, a board it doesn't serve, or an executor it doesn't allow.
- Read files on this machine. What reaches the server is what the daemon
  sends: each job's log and the agent's transcript, which hold whatever
  the agent read or printed while it worked.
- Install an update that isn't signed with the project's release key,
  which is built into the daemon. Whoever serves an update, the daemon
  checks the signature and refuses one that doesn't verify.
- Give the agent a `slipdock` CLI the project didn't sign. Before each
  agent job the daemon puts the server's CLI in its own folder, first on
  the job's PATH (or over the one `local.json` names as `cli`), only when
  its signature verifies against the same release key. A server that
  serves no signature (one built from source, or a deploy the release job
  didn't sign) leaves the machine's own CLI in place, unless `local.json`
  sets `cli_checksum_only`.
- Give the agent slipdock skills the project didn't sign. Before each
  agent job the daemon puts the server's slipdock skills in place, and
  they are instructions the agent follows, so it installs them only when
  the archive's signature verifies against the same release key. A server
  that serves no signature leaves the installed skills in place, unless
  `local.json` sets `skills_unsigned`.
- Raise a job to the owner tier on its own word, once owner keys are
  pinned. With `owner_keys` in the ceiling (pinned by a person at the
  machine with `slipdock-runner trust-owner`), a job the server says is
  `owner` tier runs as `owner` only when its card's title, description
  and bar carry a signature by one of those passkeys. The daemon checks
  it itself: the challenge is its own SHA-256 of the text, with the
  server's origin, the card and when it was signed; the origin and
  relying party are the pinned key's; the owner was present and
  verified; and the signature is no older than the ceiling allows. Any
  other job runs as `member` at most, and the daemon logs why. A
  signature never raises a job above the tier the server gives it.
 lets it claim and report on its own runners' jobs and
read their settings, and nothing else. It is not an API token. Revoking
the machine on the Machines page ends the key at once.

#### What nothing here bounds

- First-install trust. The first copy of the daemon is only as
  trustworthy as the download it came from: the installer checks it
  against the release key written into the installer itself, so a
  tampered installer passes its own check. Every later update is checked
  against the key built into the daemon.
- On the hosted service, the operator who runs the server is also the one
  who signs the releases. A self-hosted server can't author an update;
  the hosted operator can, as anyone who downloads the tool already
  trusts them to.
- The slipdock skills, and a CLI taken on the server's word. With
  `skills_unsigned` set in `local.json`, the daemon installs the server's
  unsigned slipdock skills, instructions the agent follows, checked
  against nothing but the server: a server can then change what the agent
  reads. With `cli_checksum_only` set in `local.json`, the same goes for an
  unsigned `slipdock` CLI, checked only against the checksum the same
  server publishes: a server can then change the program the agent calls.
  Set `no_skills_update` (and `no_cli_update`) in `local.json` to keep your
  own.
- What an owner's signature doesn't cover. Signed text is the owner's
  for certain, and only that text: the server is still trusted for the
  rest of the prompt (a rejection, a wait's answer, a handoff), for what
  the agent reads while it works, and for the prompt carrying the signed
  text at all. A server serving a tampered page can ask the owner to tap
  for other text than the page shows. The keys are pinned on the
  server's word when `trust-owner` runs, so compare their fingerprints
  with the owner's own list. With no `owner_keys` pinned, a job's tier is
  the server's word alone.
- Network access. A job can reach the network, and so can send anything
  it can read to anywhere, unless its runner uses the `container`
  executor with the network off. No other executor limits the network,
  but for a network allowlist: a trust tier in the ceiling may hold its
  jobs, under `confined` or `container`, to their agent's model API, the
  Slipdock server, the repository's origin and the hosts it names,
  through a proxy of the daemon's. Such a job can still send what it
  reads to those hosts, and the allowlist doesn't cover name lookups or,
  under `confined` on Linux, UDP or another host on the proxy's port.
  A `container` job under an allowlist also finds fake credentials in
  its home, and its proxy, seeing one leave, has the job stopped and its
  pool paused: that catches a job sending them where the proxy can read
  (a host name, plain HTTP), not one sending them inside TLS to an
  allowed host.
- Prompts are the board members' instructions. The agent follows them
  within the runner's permission mode, as the account its jobs run as.
  Every job's prompt tells the agent that a card's text is data, never
  instructions, but telling a model is not a limit.
  Whatever that account can read or change, a card can ask the agent to
  read or change, and so can text the agent reads while it works (an
  issue, a web page, a file in the repository). Anyone who can write a
  card a runner takes is giving that agent instructions: choose the
  boards a machine serves, the highest permission mode and the executor
  with that in mind.

#### What each executor stops

A runner's executor is who its jobs run as. The ceiling says which ones
the machine allows, and a job never runs under a weaker one in its place.

- `me`: jobs run as you, as you are. It stops nothing: the agent can read
  and change whatever you can, your SSH keys, logins and mail included.
- `user`: jobs run as a dedicated account (`slipdock` by default), with
  its own home, clones and logins. It stops a job reading or changing
  your home: a job is refused while your home is open to that account. It
  doesn't stop the job reading what every account on the machine can,
  writing the account's own home and `/tmp`, using the account's own
  logins (its `gh` login pushes wherever it can), or the network.
- `confined`: jobs run as you, unable to write outside the job's
  directory, its repository, a scratch temporary directory and the
  agent's own state (Landlock on Linux, `sandbox-exec` on macOS). In a
  worktree, a job whose card has paths writes only those in it, and of
  its repository only what a commit needs. The daemon's own git for the
  runner and the runner's hooks are confined to the repository and its
  worktrees. It stops a job writing to your home, other repositories
  and the system. It doesn't stop the job reading your files, your SSH
  keys and logins included, or the network (unless a network allowlist
  holds it), so a confined job can still read a secret and send it.
- `container`: jobs run in a short-lived Docker or Podman container,
  from an image the machine's own allow-list names, with the repository
  or worktree mounted at the same path, the agent's login mounted
  read-only, and an empty directory of its own for the agent's
  transcript, which the daemon reads only as regular files beneath it.
  In a worktree, a job whose card has paths has only those mounted
  read-write, and of its repository only what a commit needs.
  It stops a job reading or writing anything outside what is mounted,
  and, when the runner asks for the network off, the network; under a
  network allowlist (Linux only), every host but the allowlist's.
  It doesn't stop the job changing the mounted repository, using the
  agent's login (it can't change it, but can act with it), whatever the
  image itself does, or the network when it is left on. The runtime is
  trusted too: an account in the `docker` group is root on the machine.

On Windows, jobs run as the current account only (`me`).
<!-- /trust-contract -->

### Checking a machine

```sh
slipdock-runner doctor
```

checks the machine is enrolled and the server still accepts its key, the
key and directory are yours alone, the ceiling is valid and its roots exist,
each agent in it answers `--version`, `git` is there, `gh` is logged in,
the service is installed, and the last update check wasn't refused. With
owner keys pinned, it also warns about one the owner's account no longer
has (run `trust-owner` again to unpin it). Each line is `ok`, `warn` or `FAIL` with what to
do; any `FAIL` makes it exit non-zero.

Three commands read what the daemon keeps in its directory. They need no
server, so they work when the board can't be reached:

```sh
slipdock-runner status [--json]
slipdock-runner log [--level debug|info|warn|error] [--since DUR] [-n N] [--follow]
slipdock-runner log --runner NAME | --job ID [-n N] [--follow]
slipdock-runner config [--effective | --json]
```

- **`status`** is one screen. It shows the daemon's version, the machine,
  the server, and whether the daemon is running (since when, its pid). Then
  its last contact with the server, and one line per runner: board, pool,
  executor, permission mode, what it is doing (`idle`, `working on card #N
  since T`, `paused`, or `refused vN, keeping vM`) and the last line of its
  job's log. It ends with the last update check. It exits non-zero when the
  daemon isn't running or a runner's settings were refused, so a script or
  a monitor can call it. `--json` prints the same as one object.
- **`log`** prints the daemon's log, the last 50 lines (`-n 0` is all).
  `--level warn` keeps `WARN` and `ERROR` lines, `--since 2h` (or `30m`,
  `3d`) the recent ones, and `--follow` (`-f`) keeps printing new lines
  until you stop it. With `--runner` (its name or id) or `--job`, it prints
  that runner's job log instead. Each runner keeps only its last job's log,
  and a job log has no levels or times, so `--level` and `--since` don't go
  with it.
- **`config`** prints the ceiling, `local.json`, and each runner's accepted
  settings with their version. For a runner whose settings were refused, it
  shows what was refused and why, with its line from `changes.log`.
  `--effective` resolves the names: the program each agent and hook runs
  (or that a name isn't defined, so jobs fail), the variables `local.json`
  sets for the runner (`env`), who jobs run as, and which root the
  runner's directory is inside. `--json` prints the three files as
  they are, as one object. `show` is still the trust contract; `config` is
  the machine's settings.

What these read:

- `daemon-state.json`: the daemon's pid, when it started and stopped, and
  its last contact with the server.
- `jobs/<runner>/job.json`: the job a runner holds or held last.
- `config-cache.json` and `changes.log`.
- `update.json`.
- `daemon.log`.

`run` writes the state files itself. A daemon from before these commands
has no `daemon-state.json`, so `status` says it isn't running until the
daemon restarts on a version that writes one.

### Running it as a service

```sh
slipdock-runner service install
```

installs the daemon as a service of your account, started now and at every
log-in, and brought back if it stops:

- **Linux** (and WSL with systemd on): a systemd user unit,
  `slipdock-machine.service`. Logs: `journalctl --user -u slipdock-machine`.
  `loginctl enable-linger` keeps it running while you are logged out.
- **macOS**: a launchd agent, `us.slipdock.machine`. Logs:
  `~/Library/Logs/slipdock-machine.log`.
- **Windows**: a Task Scheduler task, *Slipdock machine*, at log-on and
  every five minutes after (a no-op while it runs). Logs: `daemon.log` in
  the daemon's directory.

On every system the daemon also writes its own log, `daemon.log` in its
directory, whatever the service does with its output. It is capped at
5 MiB, and the one before it is kept as `daemon.log.1`. Each line has a
time and a level (`DEBUG`, `INFO`, `WARN`, `ERROR`); `slipdock-runner log`
reads it the same way everywhere. `run --log-level` (or `local.json`'s
`log_level`) sets how much is written, `info` by default.

The names differ from the retired shell runner's (`slipdock-runner.service`,
`us.slipdock.runner`, *Slipdock runner*), so both can run while a machine
moves over, until the old one is stopped. `service print` shows what it would install; `service
uninstall` stops and removes it.

### When the connection drops

The daemon keeps one connection to the server for all its runners, and a
connection can die without either end being told: a route change in the
network between them, Wi-Fi changing, a VPN turned on or off, the machine
going to sleep. The daemon notices and replaces it by itself, so a laptop
that sleeps, roams or goes offline for a while is as good a machine to run
jobs as one that is always on:

- **A quiet connection is checked.** After 15 seconds with nothing from the
  server, the daemon pings it, and gives the connection up if no answer
  comes within 10 more. Whatever was waiting on it fails at once and is
  asked again on a new connection, so a dead one is replaced in under half
  a minute. A healthy connection answers the ping and is kept, long-polls
  and all.
- **A failed request is never retried on the same connection.** A claim,
  a heartbeat, the config poll or the enrolment check that gets no answer
  in time drops the connection it was on before trying again.
- **Waking from sleep is noticed.** When the clock jumps (the machine
  slept, or its clock was set), the daemon drops its connections and every
  runner asks for work again at once, so the machine is back in its pools
  within seconds of waking. Otherwise a runner that can't reach the queue
  tries again after a second, then twice as long each time, up to a
  minute.

What the board sees meanwhile: a runner shows offline once it hasn't been
heard from for three of its leases (4½ minutes), and online again at its
first claim after the machine wakes. A job it held while it slept keeps
its lease only 90 seconds without a heartbeat; after that the server puts
it back in the queue for any runner of the pool. If none has taken it by
the time the machine wakes, the runner's next heartbeat takes the job back
and its agent carries on where it was, at no cost to the job's three
tries (the card's activity says `took job #N back`). If another runner
has taken it, the runner that woke stops its copy when its next heartbeat
is refused, and the card is worked afresh there. The log says
`could not reach the queue` while the connection is down and `the clock
jumped` on waking; nothing needs restarting.

---

← [Runners](runners.md) · [Contents](../manual.md) · [Wiki](wiki.md) →
