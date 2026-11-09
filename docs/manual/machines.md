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
it runs. It replaced the shell and PowerShell runners, which this server no
longer serves (#2582, [Runners](runners.md)): a machine still running one
moves over as W-1951's runbook *Moving a machine's runners onto the daemon*
says.

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
| `boards` | the boards the machine serves | the ones chosen on the approval page |
| `executors` | who a runner's jobs may run as (below) | `user` with a dedicated account; `me` and `confined` without one (`me` only on Windows) |
| `container_images` | the images a `container` runner may run (below) | none: no image runs until you list one |

`init --root DIR --agent NAME --max-mode MODE --max-timeout MINUTES` sets
them as it writes the file (`--root` and `--agent` repeat). `init --replace`
keeps a ceiling already there unless one of those flags is given. A setting
from the board outside the ceiling is refused on the machine, and the runner
keeps its last accepted settings.

### Who jobs run as: executors

Each runner names an **executor**, and the ceiling's `executors` say which
ones the machine allows. A runner set to one the machine doesn't allow, or
that can't run here, is refused, and its jobs never run under a weaker one
in its place. When a job's executor isn't ready (the account's `sudo` rule
is gone, say), the job fails before anything starts, and its log says why.

| Executor | Jobs run as | What it stops | What it doesn't |
|---|---|---|---|
| `user` | a dedicated account, `slipdock` by default, with its own home, clones and logins | reading your home: a job is refused while your home is open to the account | reading what every account can, writing its own home and `/tmp`, the network |
| `confined` | you, unable to write outside the job's directory | writing anywhere else: your home, other repositories, the system | reading your files, the network. It may also write its own temporary directory, the terminal devices and the agent's own state (`~/.claude` for `claude`) |
| `me` | you, as you are | nothing: an agent can read and change what you can | |
| `container` | you, in a short-lived Docker or Podman container from an image on the machine's allow-list | seeing anything not mounted: your home is an empty one; writing outside the job's directory and repository; the network, when the runner turns it off | the network when it is on; what the mounted logins allow; the image itself, and the runtime (an account in the `docker` group is root on the machine) |

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
  worktree and its repository. The hooks and the daemon's own git also see
  the repository's worktrees (`<repo>-lanes`).
- the agent's login and the slipdock CLI's, read-only: by default
  `~/.claude/.credentials.json` and `~/.claude/skills` for `claude`,
  `~/.codex/auth.json` for `codex`, and `~/.config/slipdock`, those that are
  there.
- the machine's `slipdock` CLI, read-only, over the image's, so the board's
  drift check reads what runs.
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
needs it on, and so does the built-in merge.

Under `container` the agent's and hooks' programs are the image's, found
on its `PATH`. The daemon reads nothing a container job wrote outside the
repository, so the live transcript isn't sent: the job's own log is.

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
  "models": {"schema": "opus"}
}
```

- `agents`: `claude` and `codex` need an entry only when they aren't on the
  `PATH`, or when `claude` has tools a job may use without asking
  (`allowed_tools`: in a job nobody is there to approve one). Any other agent
  a runner names must be defined here. It gets the prompt as
  `$SLIPDOCK_PROMPT`, never on its command line.
- `hooks`: what a runner's before, after and probe hooks run, by name. A
  before hook that fails stops the job; the after hook runs however the job
  ended, with `$SLIPDOCK_EXIT` and `$SLIPDOCK_STATUS` (`done`, `failed`,
  `cancelled` or `timeout`). The probe hook runs at the end of a probe
  (below), and a probe whose hook exits non-zero is red.
- `models`: a model for a card's profile (`docs`, `fix`, `feature`,
  `schema`, `security`, `spike`), over the runner's own.
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
  ceiling's `container_images`, not this file's.
- `transcripts`, `skills_dir` and `cli` say where Claude Code's
  transcripts, the slipdock skills and the `slipdock` CLI are, when they
  aren't in the usual places. `no_merge: true` turns off the built-in merge.
  `no_skills_update: true` stops the daemon putting the server's slipdock
  skills in `skills_dir` before each agent job (see
  [Runners](runners.md), *Skill and CLI drift*).

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
- each runner's latest **probe**: green with when it passed, or red with
  how it ended and the log it sent;
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
- **Probe** a runner: it checks its own setup and shows green or red
  (below).
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
- Name a newer version of the daemon.

#### What the server cannot do

- Run a command on this machine. The daemon never runs anything the
  server sends. The agents, custom commands and hooks it can run are
  defined in files on the machine, and the server can only pick one of
  them by name.
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

The machine's key lets it claim and report on its own runners' jobs and
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
- Network access. A job can reach the network, and so can send anything
  it can read to anywhere, unless its runner uses the `container`
  executor with the network off. No other executor limits the network.
- Prompts are the board members' instructions. The agent follows them
  within the runner's permission mode, as the account its jobs run as.
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
  agent's own state (Landlock on Linux, `sandbox-exec` on macOS). The
  daemon's own git for the runner and the runner's hooks are confined in
  the same way. It stops a job writing to your home, other repositories
  and the system. It doesn't stop the job reading your files, your SSH
  keys and logins included, or the network, so a confined job can still
  read a secret and send it.
- `container`: jobs run in a short-lived Docker or Podman container,
  from an image the machine's own allow-list names, with the repository
  or worktree mounted at the same path and the agent's login mounted
  read-only. It stops a job reading or writing anything outside what is
  mounted, and, when the runner asks for the network off, the network.
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

The names differ from the retired shell runner's (`slipdock-runner.service`,
`us.slipdock.runner`, *Slipdock runner*), so both can run while a machine
moves over, until the old one is stopped. `service print` shows what it would install; `service
uninstall` stops and removes it.

---

← [Runners](runners.md) · [Contents](../manual.md) · [Wiki](wiki.md) →
