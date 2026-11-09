[Slipdock — the manual](../manual.md)

## Tools

A Tool packages a way of working so other people on the same server can
install it: a board blueprint, agent skills, files and docs (#958). Tools
live at `/tools`; each has a page at `/tools/<name>`.

[Tool packages: the reference](../tool-packages.md) has everything a program
building a Tool needs, in one place, with a worked example that a test holds
to the server. This section is the overview.

### Installing

The Tool's page renders its README, shows everything it would install — the
board's lists (with their roles), folders, tags, pages and rules, its board
files, and **every skill file in full** — and walks through installing it
from claude.ai, Claude Code or ChatGPT. Every route ends with the person
asking their agent to set the Tool up.

The board is built by the server, never by an agent. `install_tool` (MCP),
`POST /api/tools/<name>/install` (`version`, `name`), `slipdock tools
install-board <name> [--version V] [--name N]` and **Make the board** on the
page all call the same code: the lists are made with the categories their
roles need, then the rest of the blueprint is applied
(`Slipdock.Blueprint`), board files go into a wiki folder called `Tool`, and
a `tool_installs` row records who installed which version onto which board.
The answer is the board's code (`201` when made, `200` when it already
existed). Installing again returns the same board. A Tool's skills find
their board through that record: `list_tools` gives each Tool with
`installed.board`.

**The handbook** is the one built-in Tool, and the one that goes onto a board
that already exists rather than building one: `install_tool` with `tool:
"handbook"` and `board`, `POST /api/tools/handbook/install` with `board`, or
`slipdock tools install-board handbook --board B`. It goes on the board's
root (one handbook per tree) and needs write access there. It makes the
`Handbook` and `Handbook/Decisions` folders; an Index page whose live
`pages: Handbook` query lists the folder; skeleton pages for Specification,
Architecture, UX & UI, Components, Data model, Shared modules, Testing &
tooling, Operations, Principles and Playbook (below), each with
`handbook:`, `read_when:` and `covers:` front matter; and three cards: **Seed the handbook** (the procedure for
drafting every page from the codebase), **Reconcile the handbook**
(nightly, waiting on the seed) and **Triage findings** (nightly, waiting on
the seed: it merges duplicate findings, dismisses one-offs, and promotes
what recurs or shows the handbook wrong, a rule or a decision as a proposal
for a person, logging each run on the Index's `## Triage`). A finding it left
open one night is decided the next, as a card, a proposal, a promotion or a
dismissal with its reason: nothing is left open twice, and the log line counts
the leftovers it decided. Each night's reconcile takes at most 20
commits from where the Index's `## Log` stopped, pipes their paths to
`slipdock handbook <board> --paths-from -`, and reads only the pages that
lists; with nothing new on the default branch it closes with `Handbook: no
change (nothing landed)`. Installing again adds only what is missing: a
section page without a `## Rules` section (as 1.0.0 made most of them)
gets an empty one appended, and nothing else on it changes. A handbook from
before 1.2.0 reconciled weekly: installing over it gives the reconcile
card (the series' current one) the nightly procedure and moves its series
to every day, and changes nothing else on it. Installing 1.3.0 over an
older handbook adds the Triage findings card and appends `## Triage` to the
Index.

**Before you push** (1.4.0): every check CI enforces on a pull request
should run locally through one command, and builders are told which. The
Testing & tooling page has a `## Before you push` section for it: the one
command, in CI's order with CI's arguments, and any CI check with no local
equivalent (a Windows runner, say), with why. The seed card fills it from
the CI config, and where the repo has no such command it proposes one (an
alias, a make target or a script) in its closing comment rather than adding
it. The nightly reconcile checks the section against the CI config whenever
its range touches it (`.github/workflows/**` and the like). On a board that
ships by pull request, the builder's prompt points at the section first.
A handbook installed before 1.4.0 gets the section by installing again:
it is added after the page's `## CI` section (else at the end), empty but
for its hint, and the reconcile card gets the CI step; nothing else on the
page changes, and a page that already has the section is left alone. Then
write the project's command into it (`slipdock page section <code> "Testing
& tooling/Before you push" --body …`), or leave it to the next reconcile
that touches the CI config.

**Principles and Playbook** (1.5.0): two pages that say how the project
decides and plans. **Principles** (prefix `PRIN`) are the tie-breakers
between two right ways: a short paragraph each (the two ways, and why this
one) and a matching `PRIN-n should · judgement` item in the page's `##
Rules`. The page covers no paths, so its rules apply to every change and
a verifier weighs them like any `should` rule. It starts with how to write
one and a baseline of three, to edit or delete: one place for each
concern (`PRIN-1`), the obvious reading of an ambiguous ask, the other
noted on the card (`PRIN-2`), and extending what is there before adding
beside it, and splitting it in the same change once it has grown big or
hard to follow, each part about one thing (`PRIN-3`). Adding, rewording
or dropping one is a rule change, so it goes in as a proposal. The **Playbook** (prefix `PLAY`) is how an
idea becomes cards, read by an agent asked to plan (the `slipdock-plan`
skill) and never by the server when a card is made:

- **Sizing**, checked in order: a *system* (a new deployable, a new
  repository, or a board with no code yet) takes grill, decide,
  principles, spec and cards; a *feature* (a new user-facing surface, an
  external integration, a data model change, or more than one sitting)
  takes grill, spec and cards; anything else is a *card*, made as Card
  shape says, with no stages.
- **One section per stage** (Grill, Decide, Principles, Spec, Cards), each
  saying what it asks, the skill it uses (one named with `skill:`, which
  the plan skill takes from the board's enabled skills, else an installed
  one, else its own text), what it produces and where it
  writes: the epic's description, a `Decision:` page in
  `Handbook/Decisions`, the Principles page (as a proposal when nobody is
  there to agree it), a spec page on the epic, the epic's subcards. A
  stage whose output is already on the board is skipped.
- **Card shape**, the agent guide's until the board edits it here.
- **Defaults**: `defaults: none`, or the page holding the person's own
  stack and hosting choices, which the decide stage proposes and asks
  about, never imposes.

Editing these two pages is how a board changes how it decides and plans.
Installing 1.5.0 over an older handbook adds the two pages and changes no
other page; installing again adds nothing, and an edited page is left as
it is. A Principles or Playbook page that still holds the first, empty
skeleton (#2040) gets the seed in its place, reported as `(seed added)`;
one somebody edited is reported as `(edited: left alone)`. Installing 1.6.0
(#2112) does the same for a Principles page still holding 1.5.0's seed,
whose `PRIN-3` extended with no brake on growth: unedited, it gets the new
seed, reported as `(seed updated)`; edited, it is left alone. The seed card leaves
them to a person, suggesting any principle the code plainly keeps. A
card's handbook block lists every page, held to 2.5 KB.

**The code sweep** is the other built-in Tool that goes onto a board that
exists (#1793): `install_tool` with `tool: "sweep"` and `board`, `POST
/api/tools/sweep/install` with `board`, or `slipdock tools install-board sweep
--board B`. It goes on the board's root and needs write access there. It
adds:

- a **Sweeps** page (front matter `sweep: rotation`): the lenses, a
  **Rotation** table of areas against lenses, and a **Log**. The lenses are
  authorization (every event handler, API route and MCP tool), duplication,
  dead code, test gaps, old code vs rules (code older than a rule that
  breaks it) and secrets & personal details. The areas are the handbook's
  pages whose `covers:` name paths, with those paths; on a board without a
  handbook the first run adds them from the top-level contexts. Each cell is
  the commit and date that area was last swept through that lens, `—` for
  never;
- a **Triage** list, in the `triage` category;
- a **Sweep the code** card, every day. Its procedure: take the stalest
  cell, check out the default branch's head in a clean worktree, read that
  area through that lens without changing code, file each issue as a card in
  Triage (where, why it matters, the fix), record each as a finding in the
  closing comment, then update the cell and the Log. One area and one lens a
  run; a security issue gets the `security` tag and stays vague in commit
  messages, pull requests and the log.

Installing again adds only what is missing (the list, the page or the card,
if deleted) and never touches the page once it is there.

**A Triage list is never fed.** A list whose category is `triage` holds work
for a person to look at, not for the loop: the agent guide never reads it as
the ready list or the backlog (it shows it as `triage: for a person, never
take work from it`), a *Work a list with a runner* rule (`list_top`) sends
nothing from it, and a rule's runner action skips a card that arrives in it.
A person moves what is worth doing from Triage into the ready list. Any list
can be given the category from its menu.

**Rules** live in each section page's `## Rules`, one list item each, the
parts separated by ` · `: `- **UX-4** must · test/app_web/design_tokens_test.exs ·
No colour literals in templates.` The id is the page's prefix (`SPEC`,
`ARCH`, `UX`, `COMP`, `DATA`, `MOD`, `TEST`, `OPS`) and a number, never
reused. The severity is `must` (work that breaks it is rejected) or `should`
(it is noted). An optional `scope lib/app/**` part, after the severity,
narrows it; without one the page's `covers:` is its scope, and a page that
covers nothing makes it apply everywhere. The check is a test path (several,
separated by commas) or `judgement`. Indented lines continue an item, and
`###` headings inside the section group rules. `slipdock handbook <board>`
counts the rules (`rules` in `GET /api/boards/:board/handbook`: `count`,
`must` and `problems`) and lists each item it couldn't read, with its page,
line and why.

`slipdock handbook <board> --paths a,b` gives the pages whose `covers:`
take in any of those paths (each with how many, most first: what a
reconcile reads) and the rules whose scope covers any of them (files,
folders or globs, matched as lanes are), `must` first; `--paths-from -` reads them one per line, so `git diff --name-only
main | slipdock handbook <board> --paths-from -` checks a whole change. Over
REST it is `GET /api/boards/:board/handbook?paths=a,b` (commas or newlines,
or `paths[]=`), answering `{board, index_page, paths, pages, rules}`; the CLI
splits a long list over several requests, so a read-only token can ask. A
card with lane `paths` has the same rules in its `handbook` block
(`get_card`, `GET /api/cards/:id`, `slipdock card`): `rules` with each
one's id, severity, page, section, check and text, held to 2 KB with
`rules_more` counting the rest.

On a handbook board a card's JSON (`get_card`, `GET /api/cards/:id`) has a
`handbook` key: `board`, `index_page`, `index` (each page's code, title,
summary and `read_when`, held to 2.5 KB) with `more`, and `suggested`: up
to five `{page, title, section, why}`, ranked by `covers:` globs matching
paths the card names, then semantic search, then shared words. `slipdock
card` prints them as a **Handbook** block; `slipdock handbook <board>`
(`GET /api/boards/:board/handbook`) prints the index and decisions, and
`slipdock handbook <card>` a card's reading. See the agent guide's
`handbook` section for the docs gate and the `Handbook:` line.

**Upgrading.** Installing a newer version over an install adds only what the
board is missing — lists, folders, tags, pages, rules and files — and
replaces a page only while its body is still exactly the installed version's
skeleton, so an edited page is never touched. The answer has `upgraded: true`
and says what was `added` and `skipped`. The same or an older version
changes nothing.

**Skills.** `GET /api/tools/<name>/skills.tar.gz` is every skill laid out
for a skills directory (`local` files beside their skill), which `slipdock
tools install <name> [--dir D]` unpacks; `slipdock tools check` compares the
local copies by sha. Each skill is also `…/skills/<skill>/claude.zip` (for
claude.ai's skill upload) and `…/skills/<skill>/chatgpt.zip` (with a note on
the connector), and the page offers both through the browser session.

**One file at a time** (#1156). `GET /api/tools/<name>/files/<path>` is one
file of the package by its path (`skills/<skill>/SKILL.md`,
`skills/<skill>/references/procedure.md`, `files/build.py`): text as
`text/plain`, anything else as a download. The headers carry
`x-tool-version` and the file's sha as its `etag`. It comes from the latest
version the caller can see unless `version` says otherwise, so a stub skill
can fetch its procedure at run time and pick up a new version without being
reinstalled. MCP `list_tools` with `tool` and `file` gives the same file's
text (with `skill`, `file` is a path in that skill's folder, and `skill` alone
is its `SKILL.md`), and with `link: true` (#1158) a single-use `download_url`
instead, good for 10 minutes with no token: for that file, for a skill's
claude.ai zip, or with neither for the skills tarball. So a scheduled task or
a chat that has the connector but no API token still reaches all of it. And the CLI is `slipdock tools file <name> <path>`. `GET
/api/tools/<name>` gives each skill's `skill_md` URL and each file's `url`.
Once the caller has installed the Tool, each board file also has a
`board_url`, the copy in the board's `Tool` folder, read with `GET
/api/boards/<board>/files/Tool/<path>`.

**The whole package.** `GET /api/tools/<name>/package.tar.gz` is every file
of a version at its path in the package, saved as `<name>-<version>.tar.gz`:
the way to see exactly what was published, or to take a Tool, change it and
publish it again (bump the version in `tool.json` first). The uploaded
archive isn't kept, so this is rebuilt from the stored files, which are the
same files with the same sha. The CLI is `slipdock tools download <name>
[--version V] [--out F|-] [--force]`, MCP `list_tools` with `tool` and
`package: true` gives a single-use `download_url` for it, and the Tool's page
has **Download the package** beside the version.

### Publishing

`slipdock tools publish <folder>` packs the folder and sends it to
`POST /api/tools` (multipart field `package`, or an `application/gzip`
body). Or publish from the browser: pack the folder yourself
(`tar czf my-tool.tgz my-tool`) and upload it under **Publish a Tool** on
the Tools page. The name in `tool.json` decides whether that is a new Tool
or the next version of one of yours. Your Tool's own page has **Publish a
new version** too, which takes only a package of that Tool, so download the
package there, change it, raise the version and upload it. A package is:

```
my-tool/
  tool.json     name, version, summary; optionally title, author, requires, files
  README.md     the docs, rendered as the Tool's page
  board.json    optional: the board blueprint
  skills/<name>/SKILL.md, and anything else under skills/<name>/
  files/        optional: each listed in tool.json's files
```

- **`tool.json`**: `name` is lowercase letters, digits and dashes, and is
  the Tool's address; the first person to publish a name owns it.
  `version` is a version number and must be newer than the latest published;
  a version never changes once published, and is identified by a sha over
  every file. `summary` is one line (200 characters at most). `files` lists
  each file under `files/` as `{"path", "install": "board"}` (into the
  board's `Tool` folder) or `{"path", "install": "local", "skill"}` (beside
  that skill's `SKILL.md`, on the installer's machine).
- **`board.json`**: `lists` (a name, or `{"name", "role", "category",
  "color", "wip_limit"}`; `role` is `ready`, `backlog`, `doing`, `done` or
  `dropped`, sets the category, and is checked against how the server will
  actually read the lists), `folders` (paths like `Config/Archive`), `tags`
  (names or `{"name", "color"}`), `pages` (`{"title", "body", "summary",
  "folder"}`; bodies may use `{{board.name}}` and `{{today}}`) and
  `automations` (`{"preset", "params", "name"}`, from the ready-made rules:
  `slipdock automation-presets` lists them). A rule may only name lists the
  blueprint makes. The runner presets take a `prompt`, so a blueprint's
  runner rule can say what its jobs are told.
- **Skills**: each `SKILL.md` starts with front matter whose `name` is its
  folder's and which has a `description`.

The server refuses a package with anything else at the top, a symlink or any
non-regular file, a path that is absolute or climbs out, more than 300
entries, more than 10 MB compressed, 25 MB unpacked or 10 MB in one file,
and says why. A version counts against its owner's storage.

Templates use the same blueprint: a template can carry `folders`, `tags` and
`automations` as well as its lists and pages, and a board made from it gets
them through the same applier.

### Sharing and listing

A Tool is private to its owner until shared. The owner shares it by email
on its page (an access grant, `read`: see and install). To offer it to
everyone on the server, the owner asks for a version to be listed (on the
page, `POST /api/tools/<name>/listing`, or `slipdock tools request-listing
<name> [--version V]`); an admin approves or declines it under **Tool
listings** (`/admin/tools`). Somebody who sees a Tool only because it is
listed sees the approved version and no newer one until that is approved
too. `list_tools` and `slipdock tools` give each Tool's `kind`: `mine`,
`shared` or `listed`.

### Skills from elsewhere

Skills are published outside Slipdock too, usually as a GitHub repository of
`SKILL.md` files. The **Skills** page (`/skills`, under Set up in the menu)
keeps the ones a person points the server at (#2059, spec W-2513).

- **Add a source** by its URL: a GitHub repository
  (`https://github.com/owner/repo`), a folder in one (`…/tree/main/skills`),
  one file in one (`…/blob/main/x/SKILL.md`), or a `SKILL.md` at any https
  address. The server fetches every `SKILL.md` under it, or its README when
  there is none, and keeps each as a skill with its front matter's name and
  description, the commit (or ETag) as its version, the repository's licence
  and when it was fetched. The fetch goes through the server's egress guard:
  only public addresses, no redirects, at most 256 KB a file and 50 skills a
  source. What it left out (a file too big, a `SKILL.md` with no name) is
  listed under the source, and a source with nothing readable is refused,
  with the reason as a sentence.
- **Read a skill** in full on its own page, front matter and all, as fetched
  and unrendered: it is instructions an agent may follow.
- **Refresh** fetches the source again and says which skills were added,
  changed and removed. A failed refresh leaves the source as it was.
  **Remove** deletes the source and its skills.
- **Whose.** A source is its adder's alone, who alone refreshes or removes it.
  The ones listed under *On this server* are seeds, seen by everyone and
  changed only by an admin. An admin adds one by ticking *For everyone on this
  server* under **Add a source** (`seed: true` over REST and MCP, `slipdock
  registry add <url> --seed`).
- **Seeds a new server starts with.** At boot the server adds
  [`mattpocock/skills`](https://github.com/mattpocock/skills) (MIT) as a seed,
  enabled on no board (#2075). Each seed is added once: one an admin removes
  stays removed, and one whose fetch failed (the server offline, say) is tried
  again at the next boot. `config :slipdock, :skill_registry, seeds: [...]`
  changes the list, and `seeds: []` seeds nothing.
- **Enable it on a board.** On a skill's page, somebody who can write to a
  board picks it under **Enable on** and presses **Enable this text**. The
  board keeps a copy of exactly that text (and its hash): that copy is what
  the board's agents get. One skill per name per board, and a sub-board
  shares its root board's. A page left open while the source was refreshed
  can't enable the newer text: it is refused, to be read again first.
- **Changed upstream.** A refresh that changes an enabled skill marks it
  *Changed upstream* on its page, with the lines that differ (− pinned,
  + now). The board keeps the pinned text until a writer presses **Re-pin to
  the new text**. A skill gone from its source (removed upstream, or its
  source removed) keeps its pinned text on the board until a writer presses
  **Disable**.
- **Which stages name it.** A stage of a board's Playbook asks for a skill
  with a `skill: <name>` line under its heading (not in a code block). The
  Skills page lists, for each board you can read, every such stage and what
  it gets: the skill enabled there, a skill Slipdock ships, or nothing, which
  is flagged. Each skill's page lists the stages naming it.
- **Without the web app.** Everything above is at every door, with the same
  permissions and the same sentences when it refuses: REST
  (`/api/skill-sources`, `/api/skill-sources/:id/refresh`,
  `/api/skill-entries/:id`, `/api/skill-stages`, and `POST`, `PATCH` and
  `DELETE /api/boards/:board/skills[/:name]` for a board's skills), the CLI
  (`slipdock registry`, `registry add|source|refresh|rm|entry|stages`,
  `registry enable <entry> --board B --hash H`, `registry repin <name>
  --board B --hash H`, `registry disable <name> --board B`) and MCP
  (`skill_registry`, by `action`). Enabling and re-pinning take the
  `content_hash` of the text read, from `registry entry` or the entry's
  `content_hash`, and refuse any other.
- **What the board's agents get.** `GET /api/boards/:board/skills`, for
  anyone who can read the board, lists the skills enabled there, each with
  its name, source, licence, pinned hash, status (`current`, `changed`
  upstream, `removed` from its source) and its pinned text, never newer; a
  board you can't read is a 404. The CLI's door is `slipdock skills board
  <board>`, and `slipdock skills board <board> <name>` prints one skill's
  pinned text; MCP's is `get_guide` with `board`, which adds the same list
  as `skills`. The `slipdock-plan` skill uses it for a Playbook stage that
  names a skill: the one enabled on the board first, else one installed on
  the machine, else its own text, and it says which (#2063). So a board
  plans with a skill nobody installed.

---

← [CLI](cli.md) · [Contents](../manual.md) · [Skills](skills.md) →
