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
- The slipdock skills, and a CLI taken on the server's word. With
  `skills_unsigned` set in `local.json`, the daemon installs the server's
  unsigned slipdock skills, instructions the agent follows, checked
  against nothing but the server: a server can then change what the agent
  reads. With `cli_checksum_only` set in `local.json`, the same goes for an
  unsigned `slipdock` CLI, checked only against the checksum the same
  server publishes: a server can then change the program the agent calls.
  Set `no_skills_update` (and `no_cli_update`) in `local.json` to keep your
  own.
- Network access. A job can reach the network, and so can send anything
  it can read to anywhere, unless its runner uses the `container`
  executor with the network off. No other executor limits the network.
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
  agent's own state (Landlock on Linux, `sandbox-exec` on macOS). The
  daemon's own git for the runner and the runner's hooks are confined in
  the same way. It stops a job writing to your home, other repositories
  and the system. It doesn't stop the job reading your files, your SSH
  keys and logins included, or the network, so a confined job can still
  read a secret and send it.
- `container`: jobs run in a short-lived Docker or Podman container,
  from an image the machine's own allow-list names, with the repository
  or worktree mounted at the same path, the agent's login mounted
  read-only, and an empty directory of its own for the agent's
  transcript, which the daemon reads only as regular files beneath it.
  It stops a job reading or writing anything outside what is mounted,
  and, when the runner asks for the network off, the network.
  It doesn't stop the job changing the mounted repository, using the
  agent's login (it can't change it, but can act with it), whatever the
  image itself does, or the network when it is left on. The runtime is
  trusted too: an account in the `docker` group is root on the machine.

On Windows, jobs run as the current account only (`me`).
