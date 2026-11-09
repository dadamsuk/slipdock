[Slipdock — the manual](../manual.md)

## Skills

> Setting an agent up — the address, the approval, the skills — is
> [its own page](../agents.md), written for the person doing it rather than for
> somebody reading the code. The rest of this section is how it works.

`priv/skills/` holds the agent instructions this app ships, and the server
serves them at `/api/skills` — versioned with the code they describe, so a
copy in somebody's agent directory can be checked against the API that
actually answers. Three ways to install them:

- `curl -fsSL <server>/install.sh | sh` — needs only `curl` and `tar`, so it
  works on the machine an agent is actually running on. It unpacks
  `/api/skills.tar.gz` into `~/.claude/skills` (an argument puts them
  elsewhere) and saves the server's address in `~/.config/slipdock/url`.
- `irm <server>/install.ps1 | iex` — the same on Windows, in PowerShell, into
  `%USERPROFILE%\.claude\skills` (`-Dir` for elsewhere, run as
  `& ([scriptblock]::Create((irm <server>/install.ps1))) -Dir C:\somewhere`).
  `install.sh` under WSL would put them in the WSL home instead, which
  Claude on Windows doesn't read.
- `slipdock skills install` (`--dir` for somewhere else), for anyone who has
  the CLI, with `slipdock skills check` to say whether a local copy is behind.
- `GET /api/skills` for the listing — every file, with a sha over each skill —
  and `GET /api/skills/<name>/<file>` for one file, for a client that would
  rather walk it itself.

**For ChatGPT**, which can't run the CLI, every skill but `slipdock-loop` is
also a zip to upload: `GET /api/skills/<name>/chatgpt.zip`, linked from *Set
up an agent*, or all of them at once with `slipdock skills chatgpt` (`--dir`
for somewhere other than here). They are built from `priv/skills` when asked
for, with a section at the top that maps each `slipdock` command onto the
tool of the MCP connector that does the same, and a description that names
the connector rather than the CLI. The listing's `chatgpt_zip` says which
skills have one. `slipdock-loop` is left out: it commits, pushes and watches
CI, which a chat can't.

- **`slipdock`** — the command and API reference: what each call does and when
  to reach for it, and the `curl` form for a machine with no CLI on it.
- **`slipdock-work`** — working *from* a board: epics and subcards, what to
  pick up next, what to write back as you go.
- **`slipdock-wiki`** — the wiki reference: finding, reading, writing, linking
  and the section writes, with `references/` for the markup, the section
  rules and the raw HTTP.
- **`slipdock-docs`** — the harder half: what belongs in a document and where.
  A page or a comment? Search before writing. Pin it to the card. Append to
  `## Log`, don't rewrite.
- **`slipdock-plan`** — planning, when an agent is asked to plan ("plan
  this", "I want to build…", "break this into cards", "spec this out"), not
  when asked for a card. It finds the board's handbook, offering to install
  one where there is none. It reads the Playbook and sizes the ask by its
  `## Sizing`: a card-sized ask becomes one card and stops there. Otherwise
  it runs the stages that size takes (grill, decide, principles, spec,
  cards), each with the skill its section names when that skill is
  installed, else its own text. It writes Decision pages into
  `Handbook/Decisions` and principles onto the Principles page (as a garden
  proposal unless the person agreed them). The spec becomes a page on the
  epic, and the subcards go on in build order. It proposes the person's
  `defaults:` page and asks, never imposes. Run unattended, it puts its
  questions in a wait.
- **`slipdock-loop`** — working the ready list unattended: one pass, one card,
  its subcards included, claimed before the work and closed out with a
  wrap-up comment and the commit id. Where the work lands in a GitHub repo it
  watches the build too: a red default branch becomes a card at the top of
  To Do before anything else is picked, and every push gets a `Build started`
  comment. Subcards close without waiting for their build, which is checked
  before the next subcard starts; the epic, or a card with no subcards, waits
  for the build and is never closed on a red one.
  Written for `/loop`, a schedule or a cron, so the board carries all the
  state between passes.

Board-specific detail — board codes, list names, tag vocabularies — stays out
of these files on purpose and comes from `GET /api/guide`, which generates it
per caller. A skill that hardcodes them rots; one that sends the agent to the
guide first does not. They are plain Markdown, and the two that an agent
reaches for first — `slipdock` and `slipdock-work` — carry the `curl` form
alongside the CLI one, because the CLI is an escript and the machine the agent
is on usually has no Elixir. Everything else is in the guide, which is `curl`
throughout.

---

← [Tools](tools.md) · [Contents](../manual.md) · [MCP server](mcp-server.md) →
