[Slipdock — the manual](../manual.md)

## Machines

A **machine** is a computer of yours that runs Slipdock's
[runners](runners.md) through one program, the **runner daemon**
(`slipdock-runner`). You enrol the machine once; after that its runners are
added and changed from the board, not from a shell on the machine, and the
machine's own **ceiling** limits what the board may set.

The daemon is being built in steps (epic #2569). What is here today:
enrolling a machine, its ceiling, `show`, `doctor`, the service, signed
releases that it updates itself from, running its runners' jobs, and the
Machines page where its runners are set, taking changes made there while
it runs. Until a machine moves over, its runners are still the
[shell runners](runners.md).

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
`SLIPDOCK_RUNNER_BIN` puts it elsewhere. Anything that doesn't verify is
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

To build it yourself instead, with Go 1.22 or newer (a build of your own
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
  runner takes a job; found by a later check, a job a runner holds is
  stopped as when the service stops, and goes back to the queue.
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
your browser when it can (`--no-browser` doesn't). It also prints the
machine's **fingerprint**: check the approval page shows the same one before
you approve, so you know it is this machine you are letting in. On the page
you choose the boards the machine may serve.

When you approve, the daemon receives the machine's key and keeps it in its
directory, readable only by you. The key lets the machine claim and report
on its own runners' jobs and nothing else: it is not an API token. Revoking
the machine on the Machines page ends it at once.

On a machine with no browser to hand, make a one-time **enrolment key** on
the Machines page (`slipdock machine enrol-key <board>…`) and give it to `init`:

```sh
slipdock-runner init --server https://slipdock.example.com --key sdk_…
```

A machine that is already enrolled refuses a second `init`; `--replace`
enrols it again (revoke the old one on the Machines page).

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
| `boards` | the boards the machine serves | the ones chosen on the approval page |

`init --root DIR --agent NAME --max-mode MODE --max-timeout MINUTES` sets
them as it writes the file (`--root` and `--agent` repeat). `init --replace`
keeps a ceiling already there unless one of those flags is given. A setting
from the board outside the ceiling is refused on the machine, and the runner
keeps its last accepted settings.

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
  "models": {"schema": "opus"}
}
```

- `agents`: `claude` and `codex` need an entry only when they aren't on the
  `PATH`, or when `claude` has tools a job may use without asking
  (`allowed_tools`: in a job nobody is there to approve one). Any other agent
  a runner names must be defined here. It gets the prompt as
  `$SLIPDOCK_PROMPT`, never on its command line.
- `hooks`: what a runner's before and after hooks run, by name. A before
  hook that fails stops the job; the after hook runs however the job ended,
  with `$SLIPDOCK_EXIT` and `$SLIPDOCK_STATUS` (`done`, `failed`,
  `cancelled` or `timeout`).
- `models`: a model for a card's profile (`docs`, `fix`, `feature`,
  `schema`, `security`, `spike`), over the runner's own.
- `transcripts`, `skills_dir` and `cli` say where Claude Code's
  transcripts, the slipdock skills and the `slipdock` CLI are, when they
  aren't in the usual places. `no_merge: true` turns off the built-in merge.

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

Each runner takes one job at a time, as a shell runner does. Its claims say
which kinds it takes (its agent's, `verify` and the built-in `merge`), and
which skills and CLI are installed, so the board shows drift. While a job
runs, its log's tail goes to the board every 20 seconds and Claude Code's
transcript about once a minute, with this machine's keys and tokens taken
out. Cancelling the job on the board, or its timeout, stops it and every
process it started. With `worktree` on (or `auto`, when two runners share a
directory) each job gets a git worktree of its own, on the branch
`card-<id>`. A merge job merges the card's pull request only if it is in the
runner's repository, still open, and at the accepted commit. A runner that
crashes is started again, and the machine's other runners carry on.

### The Machines page

**Account → Machines** lists your machines, and the machines of other
people that serve a board you're on. Each opens its own page, which shows:

- whether it is **online** (heard from in the last two minutes), its system,
  and when it was last seen;
- its **ceiling** and the **executors** it offers, as the machine reported
  them: read-only, since only someone at the machine changes them;
- its **runners**: name, board, pool, agent, directory, permission mode,
  timeout, what it runs as, and its state (*ready*, *waiting for the
  machine*, *working* on a card, *paused* or *rejected*);
- a **refusal** in full: the setting the machine refused, its reason, the
  limit it crossed, and the version it still runs;
- the **changes**: every setting the machine accepted or refused.

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
- **Pause** a runner: it is handed no job until you **Resume** it. The job
  it holds finishes.
- **Remove** a runner: the machine finishes the job it holds, then stops
  it.
- **Update now**: the machine looks for a newer signed release at once,
  rather than waiting for its next check.
- **Revoke** the machine: its key stops working at once.

Someone who only shares a board with the machine sees the page with the
runners of their boards, and none of the buttons. From the command line:

```sh
slipdock machines
slipdock machine show 4
slipdock machine add-runner 4 my-board --pool build --dir ~/src/app --timeout-minutes 30
slipdock machine set-runner 4 build-box-build --permission-mode plan
slipdock machine pause-runner 4 build-box-build
slipdock machine resume-runner 4 build-box-build
slipdock machine rm-runner 4 build-box-build
slipdock machine update 4
```

### What the server can and cannot do

```sh
slipdock-runner show
```

prints the **trust contract**, filled in with this machine's ceiling: what
a Slipdock server can make the machine do (queue jobs for its runners' pools,
set their settings inside the ceiling, name a newer version), what it cannot
(run a command, change a hook, set a directory outside the roots, read
files, install an unsigned update), and what nothing here bounds (the first
download, the hosted operator also being the signer, the network outside a
container, and prompts being the board members' instructions).

### Checking a machine

```sh
slipdock-runner doctor
```

checks the machine is enrolled and the server still accepts its key, the
key and directory are yours alone, the ceiling is valid and its roots exist,
each agent in it answers `--version`, `git` is there, `gh` is logged in,
the service is installed, and the last update check wasn't refused. Each line is `ok`, `warn` or `FAIL` with what to
do; any `FAIL` makes it exit non-zero.

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

The names differ from the shell runner's, so both can run while a machine
moves over. `service print` shows what it would install; `service
uninstall` stops and removes it.

---

← [Runners](runners.md) · [Contents](../manual.md) · [Wiki](wiki.md) →
