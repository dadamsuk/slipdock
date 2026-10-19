# Tool packages: the reference

This page is for a program or an agent that builds, publishes or uses a
Slipdock **Tool**: a package of docs, files, a board blueprint and agent
skills that one person publishes on a Slipdock server and other people
install. It covers the package format, the endpoints, what an install
creates and changes, and how a skill reaches its files at run time.
A complete worked example is at the end.

`test/slipdock/tool_packages_doc_test.exs` checks this page against the
server. The example package at the end must publish, the response shape
must match what the server returns, and the preset table must list every
preset. If the code changes, that test fails until this page is updated.

Throughout, `$SLIPDOCK_URL` is the server's address (such as
`https://slipdock.example.com`) and `$SLIPDOCK_TOKEN` is an API token
(Account → API tokens).

The code behind it:

| What | Where |
|---|---|
| Reading a package | `lib/slipdock/tools/package.ex` |
| Publishing, listing, installing, upgrading | `lib/slipdock/tools.ex` |
| The board blueprint (`board.json`) | `lib/slipdock/blueprint.ex` |
| Rule presets a blueprint can use | `lib/slipdock/automations/presets.ex` |
| The HTTP API | `lib/slipdock_web/controllers/api/tool_controller.ex`, `tool_json.ex`, `wiki_file_controller.ex` |
| MCP | `lib/slipdock_web/mcp/tools/list_tools.ex`, `install_tool.ex` |
| CLI | `cli/lib/slipdock_cli/tools.ex` |

## The package

A package is a **gzipped tar** with this layout. It may sit inside one
top-level folder (`my-tool/tool.json`), which is what
`tar czf my-tool.tgz my-tool` makes, and that folder is stripped.

```
tool.json                    required: the manifest
README.md                    required: UTF-8; rendered as the Tool's page
board.json                   optional: the board blueprint (without it, the Tool has no board)
skills/<skill>/SKILL.md      required: at least one skill
skills/<skill>/…             optional: anything else the skill carries (references/, scripts, assets)
files/…                      optional: extra files, each one declared in tool.json "files"
```

Nothing else is allowed at the top level. The server refuses symlinks and
any other non-regular files, absolute paths, paths with `..`, backslashes
and drive letters. It silently drops `.DS_Store`, `Thumbs.db`, `._*` and
`.git/`.

**Limits:** 10 MB compressed, 25 MB unpacked, 10 MB for any one file, and
300 tar entries (folders count). Each version also counts against the
publisher's storage quota.

### `tool.json`

| Field | Required | Rule |
|---|---|---|
| `name` | yes | `^[a-z0-9][a-z0-9-]{0,47}$`. The Tool's address (`/tools/<name>`, `/api/tools/<name>`). The first account to publish a name owns it. |
| `version` | yes | A semantic version (`1.0.0`). It must be greater than the latest published version. |
| `summary` | yes | One line, 200 characters at most. |
| `title` | no | 80 characters at most. Defaults to `name`, and is also the installed board's default name. |
| `author` | no | Text. |
| `requires` | no | An object or a list. Stored and shown, never enforced. |
| `files` | no | A list of `{"path", "install", "skill"}`: see below. |

Each file under `files/` must be declared, and each declared file must be
present:

```json
"files": [
  {"path": "template.docx", "install": "board"},
  {"path": "build.py", "install": "local", "skill": "my-skill"}
]
```

- `"install": "board"` copies `files/<path>` into the installed board's wiki,
  in a folder called **`Tool`**. Subfolders are kept, so `templates/a.docx`
  lands in `Tool/templates/a.docx`. These copies are wiki **files**, not
  attachments on a page.
- `"install": "local"` places `files/<path>` beside the named skill's
  `SKILL.md` wherever the skill is downloaded (the skills tarball and the
  claude.ai and ChatGPT zips). `skill` is required, and the path must not
  clash with one of that skill's own files.

### Skills

Each `skills/<skill>/SKILL.md` must start with front matter whose `name` is
the folder's name and which has a non-empty `description`:

```markdown
---
name: my-skill
description: What it does and when to use it.
---
```

The skill name is `^[a-z0-9][a-z0-9._-]{0,63}$`. Everything else in the
folder (`references/procedure.md`, scripts, images) ships with the skill.

## Publishing

`POST /api/tools` with a write token. The package is sent either:

- as the multipart field `package`:
  `curl -F "package=@my-tool.tgz;type=application/gzip" …`. This is what
  `slipdock tools publish <folder>` sends, after packing the folder itself.
- or as the whole request body, with content type `application/gzip`,
  `application/x-gzip` or `application/octet-stream`.

JSON is not accepted.

| Status | Meaning |
|---|---|
| `201` | Published: `{"tool": …}`, the shape `GET /api/tools/<name>` gives |
| `400` | No package, or an empty one |
| `401` / `403` | No token, or a read-only token |
| `402` | The publisher's storage is full |
| `422` | `{"error": "…"}` saying exactly what is wrong (`board.json: lists: …`, `skills/x/SKILL.md: front matter needs a name and a description`, a name owned by someone else, or a version that isn't newer) |

**Versions.** The number is whatever `tool.json` says, and the server only
checks that it is greater than the latest. A published version never
changes. It is identified by a sha256 over every file's path and bytes, so
the same files give the same sha however they were packed. To publish a
fix, bump `version` and publish again.

**Who can see it.** A new Tool is visible only to its owner. The owner can
share it with a person or group on its page in the web app, which gives
them every version. To offer it to everyone on the server:

- `POST /api/tools/<name>/listing` (optional `version`, default the latest)
  asks for that version to be listed. Only the owner can ask. The answer is
  `{"tool": …}`, whose `listing.this_version` reads `waiting for an admin`.
  The CLI is `slipdock tools request-listing <name> [--version V]`.
- An admin approves or declines it in the web app under **Tool listings**
  (`/admin/tools`). There is no API for this step.
- Once approved, everyone on the server can see and install **that version
  only**. A newer version needs its own request and approval, and until
  then the approved one stays listed. Approving an old request never
  replaces a newer listed version.

## The board blueprint: `board.json`

The top-level keys are `lists` (required), `folders`, `tags`, `pages` and
`automations`. Any other key is an error. Objects may also be written with
keys this page doesn't list, and those keys are ignored.

### `lists` (1 to 20)

Each list is either a name or an object:

```json
{"name": "Doing", "role": "doing", "category": "doing", "color": "amber", "wip_limit": 3}
```

- `name` is required, at most 60 characters, and unique regardless of case.
- `role` is one of `ready`, `backlog`, `doing`, `done` or `dropped`. It sets
  the category: `ready` and `backlog` become `todo`, and the others become
  the category of the same name.
- `category` is one of `todo`, `doing`, `done` or `dropped`. If it is given
  with a `role`, the two must agree.
- With neither, the category is guessed from the name:
  - `done`, `complete`, `completed`, `finished`, `shipped` or `closed` give `done`;
  - `doing`, `in progress`, `wip`, `working on`, `in review` or `review` give `doing`;
  - `to do`, `todo`, `to-do`, `next`, `up next` or `ready` give `todo`;
  - anything else gives no category.
- `color` is one of `slate red orange amber lime emerald teal sky indigo violet fuchsia rose`.
  **An unknown list colour is silently dropped** (an unknown tag colour is an error).
- `wip_limit` is a positive integer.

**Roles are checked against how the server will read the board.** The agent
guide works out which list plays which part from the categories, the names
and the order together, and the server refuses a blueprint whose roles it
would read differently:

- **ready** is the `todo` list whose name contains `to do`, `todo`, `to-do`,
  `now`, `ready`, `selected`, `next` or `this week`. Failing that, it is the
  first `todo` list not named like a backlog (`backlog`, `later`, `icebox`,
  `someday`, `parking`, `ideas` or `inbox`). Failing that, the first `todo`
  list.
- **doing** and **done** are the first list of that category. An
  uncategorised list counts by its name.

The usual trap is a list *named* "Ready" (or "Next") that isn't where work
starts. With no category, its name makes it `todo`, and it then takes the
ready role from the list you meant. The error says so:

```
lists: “Found” is meant to be the ready list, but the server would read “Ready” as that — reorder the lists, or rename the one that takes it
```

Give such a list an explicit category (`"category": "doing"`) or rename it.

### `folders` (at most 50)

Paths such as `"Config"` or `"Runs/Archive"`. Each segment is 1 to 120
characters. Parent folders are created as needed.

### `tags` (at most 50)

A name, or `{"name", "color"}`. Names are at most 30 characters, and colours
are from the palette above.

### `pages` (at most 50)

```json
{"title": "Criteria", "folder": "Config", "summary": "…", "body": "# {{board.name}}\n…", "template": false}
```

- `title` is required and unique regardless of case.
- `folder` must also be listed in `folders`.
- `body` and `summary` are text. They may use `{{board.name}}` and
  `{{today}}`, which are filled in when the page is made.
- `"template": true` makes the page a **page template** (what
  `slipdock page from <board> <template>` and the web's "new page from
  template" use).

### `automations` (at most 20)

Rules come only from the ready-made **presets**. A hand-written rule spec
is not accepted.

```json
{"preset": "send_to_runner", "name": "Draft it", "params": {"column": "Generate", "pool": "generate"}}
```

- `preset` is a key from the table below.
- `params` holds that preset's fields. Fields left out take their defaults,
  and keys a preset doesn't have are ignored.
- `name` is optional and replaces the preset's own generated name, such as
  "Send Generate to the generate runners".
- **Lists are named, never numbered.** A `column` field names a list,
  regardless of case. At publish time it must be one of the blueprint's
  lists; at install time, one of the board's.
- For notifying presets, "me" (the default email, `notify`) is whoever
  installs the Tool.

`*` marks a required field; a default is shown in brackets.

<!-- presets:start -->
| Preset | What it does | Fields |
|---|---|---|
| `follow_board` | Follow this board | `notify`* (alert), `email` |
| `follow_list` | Follow a list | `column`*, `notify`* (alert), `email` |
| `follow_card` | Follow a card | `card`*, `notify`* (alert), `email` |
| `watch_comments` | Comments | `assignee`, `notify`* (alert), `email` |
| `watch_field` | A field changes | `field`, `notify`* (alert), `email` |
| `assigned` | Assigned to someone | `assignee`, `notify`* (alert), `email` |
| `flagged` | A card is flagged | `flag`* (blocked), `notify`* (alert), `email` |
| `due_soon` | Due soon | `hours`* (24), `notify`* (alert), `email` |
| `overdue` | Overdue | `notify`* (alert), `email` |
| `stale` | Gone quiet | `days`* (7), `column`, `notify`* (alert), `email` |
| `complete_in_done` | Complete cards in Done | `column`* |
| `archive_done` | Archive finished work | `column`*, `days`* (14) |
| `weekly_tidy` | Weekly tidy-up | `weekday`* (1), `at`* (09:00) |
| `tag_priority` | Tag sets priority | `tag`*, `priority`* (critical) |
| `webhook` | Call a URL on every change | `url`* |
| `send_to_runner` | Send cards to a runner | `column`*, `pool`* (default), `kind` (claude), `wait`* (no), `prompt` |
| `feed_runner` | Work a list with a runner, top card first | `column`*, `pool`* (default), `kind` (claude), `wait`* (yes), `requeue` (1), `prompt` |
| `runner_trouble` | A runner job times out or a card is given up | `pool`, `notify`* (alert), `email` |
<!-- presets:end -->

`slipdock automation-presets` prints the same list from a running server.

**Runner rules.** The two runner presets make the rule a runner on the
installer's own machine acts on:

- `send_to_runner` fires when a card **enters** `column` (trigger
  `card_entered`) and queues one job per card.
- `feed_runner` keeps the pool busy with `column`'s top card (trigger
  `list_top`), one card at a time.

Both make the action `{"type": "runner", "pool", "kind", "prompt"}`:

- `pool` is the runner pool, and `kind` names what the runner's own config
  runs (`claude` by default).
- `prompt` is what the job is told. It is at most 20,000 bytes and may use
  the card placeholders (`{{card.title}}`, `{{card.url}}`,
  `{{card.description}}`, `{{board.name}}` and so on). Left out, the job
  gets the card's title, link and description.
- Every prompt ends with a fixed paragraph telling the agent that nobody
  will answer questions.
- `wait: "yes"` keeps a job queued while any other card on the board is in
  progress.

### What a blueprint cannot make

- Cards, custom fields, swimlanes, or board settings such as
  `automation_wip` (an owner turns that on in the board's settings, or with
  `PATCH /api/boards/<board>`).
- Attachments on a page or a card. Board files go into the wiki's `Tool`
  folder instead (see `files` above).
- A rule that isn't one of the presets. For anything else, the Tool's setup
  skill can write the rule after install with MCP `manage_automation` or
  `slipdock new-automation`.

## Installing and upgrading

Install with `POST /api/tools/<name>/install` (optional `version`, and
`name` for the board's name, which defaults to the Tool's title). The same
install is MCP `install_tool` (`tool`, `version`, `board_name`), the CLI's
`slipdock tools install-board <name>`, or **Make the board** on the Tool's
page. Installing needs a write token that isn't confined to some boards.

On a **first install** the server builds the board:

1. the lists, with the categories their roles need;
2. the folders, tags, pages and rules;
3. the `board` files, into `Tool/`;
4. an install record (`user`, `tool`, `version`, `board`).

There is one install per person per Tool. The answer is `201`:

```json
{"install": {"board": "<board code>", "board_id": 42, "board_name": "…", "url": "…/boards/42",
  "created": true, "upgraded": false, "version": "1.0.0", "installed_version": "1.0.0",
  "added": {"lists": […], "folders": […], "tags": […], "pages": […], "automations": […], "files": […]},
  "skipped": {"lists": [], "folders": [], "tags": [], "pages": [], "automations": []}}}
```

On a **second install**, what happens depends on the version:

- **The same or an older version:** `200` with the same board,
  `created: false`, `upgraded: false`, and **nothing changed**, even if
  something has since been deleted from the board.
- **A newer version:** `200` with `upgraded: true`. The newer blueprint is
  applied **additively**, matched regardless of case:
  - lists, tags and rules by name, folders by path and pages by title;
  - board files by name within their folder.

  Anything missing is added. Anything already there is left alone: no
  change to a list's category, colour or WIP limit, and no replacement of a
  rule or a board file. The report lists what was `added` and what was
  `skipped`.
- **The board was deleted:** the next install builds a new one.

**Rules are never updated.** A rule whose name changes between versions
(through `name`, or through params that change the generated name) is added
next to the old one.

**Pages are replaced only when unedited.** A page counts as unedited when
its body is *byte for byte* the skeleton from the **installed** version,
rendered for this board. In that case, if the new skeleton differs, the
body and summary are replaced, and the report shows `"<title> (updated)"`.
Any edit at all keeps the page as it is. A skeleton using `{{today}}`
renders differently on another day, so such a page always counts as edited.

**So a fix to a page the person hasn't touched reaches them when they
install the newer version**, from their agent, the CLI or the Tool's page.
The Tool has no way to change a page the person has edited. If that matters,
the skill can make the change itself with `update_page`. Treat pages as the
person's data once they are made.

## Files and skills at run time

Every endpoint here needs a token. A **read** token is enough for these
GETs. Each one answers with the latest version the caller can see:

- the owner, and the people a Tool is shared with, get the newest version;
- someone who sees it only through its listing gets the approved version.

`?version=` picks another version. A Tool the caller can't see is a `404`
that reads exactly like one that doesn't exist.

| What | How |
|---|---|
| A Tool in full: its blueprint, skills, files, versions and your install | `GET /api/tools/<name>`; MCP `list_tools` with `tool`; `slipdock tools show <name>` |
| **One file of the package, by path** | `GET /api/tools/<name>/files/<path>`, where `<path>` is its path in the package (`skills/<skill>/SKILL.md`, `skills/<skill>/references/x.md`, `files/build.py`, `README.md`, `tool.json`); MCP `list_tools` with `tool` and `file`, or `skill` (its `SKILL.md`) and `skill` with `file` (a path in that skill's folder); `slipdock tools file <name> <path> [--version V] [--out F]` |
| Every skill as one tarball for a skills directory | `GET /api/tools/<name>/skills.tar.gz`; `slipdock tools install <name> [--dir D]` |
| **Any of these without a token**, for a shell that only has the MCP connector | MCP `list_tools` with `tool` and `link: true`: a single-use `download_url`, good for 10 minutes, for the skills tarball, or with `skill` that skill's claude.ai zip, or with `file` that file |
| One skill as claude.ai's or ChatGPT's upload | `GET /api/tools/<name>/skills/<skill>/claude.zip`, `…/chatgpt.zip` |
| Whether installed skills are behind the server | `slipdock tools check` (compares shas) |
| The board's wiki files, by path | `GET /api/boards/<board>/files[?folder=Tool]`; `slipdock wiki files <board> [--folder F]` |
| **One wiki file's bytes** | `GET /api/boards/<board>/files/<path>` (such as `Tool/template.docx`); `slipdock wiki get <board> <path> [--out F\|-]` |

`GET /api/tools/<name>/files/<path>` returns:

- text (valid UTF-8) as `text/plain; charset=utf-8`, and anything else as an
  `application/octet-stream` download;
- headers `x-tool-version: <version>` and `etag: "<sha256 of the file>"`;
- `404` for a path that isn't in the package.

MCP `list_tools` with `file` answers
`{tool, version, path, size, sha256, text}` for text files up to 200 KB.
For a binary or a bigger file, it gives an error naming the URL to fetch
instead.

`GET /api/tools/<name>` gives the address of each part:

- each skill's `skill_md` URL;
- each declared file's `url`;
- for a `board` file, once the caller has installed the Tool, a `board_url`
  pointing at the copy on their board.

`GET /api/boards/<board>/files` answers
`{board, files: [{id, name, path, folder, size, content_type, sha256, updated_at, url}]}`.
Paths match regardless of case. A wiki file is always sent as a download,
never shown inline. Reading needs read access to the board, and a token
confined to other boards gets `403`.

Only Slipdock's **own** skills (`/api/skills/...`) and the agent guide
(`/api/guide`) can be read without a token. A Tool's skills and files always
need one.

### A stub skill

A skill's `description` is what tells the agent when to use it, and that
lives in the copy the person installed. Its procedure can live on the
server, so that publishing a new version changes what runs without anyone
reinstalling:

```markdown
---
name: my-skill
description: … (this is what triggers the skill, so keep it in the stub)
---

Fetch the current procedure and follow it:

- With a shell: `curl -fsS -H "Authorization: Bearer $SLIPDOCK_TOKEN" "$SLIPDOCK_URL/api/tools/my-tool/files/skills/my-skill/references/procedure.md"`
- Over MCP: `list_tools` with `{"tool": "my-tool", "file": "skills/my-skill/references/procedure.md"}`
```

A change to the `description`, or to a `local` file the stub runs from its
own folder, still needs a reinstall (`slipdock tools install`).

## Per-person settings, and finding the board

A Tool has no per-install settings or variables. An install records only
the person, the Tool, the version and the board. Keep per-person
configuration as **wiki pages on the installed board** (a `Config` folder
with page skeletons the setup skill fills in), and read them at run time.

To find the board an install made:

- `GET /api/tools/<name>` → `tool.installed` =
  `{"version", "board", "board_id", "board_name"}`, or `null` when there is
  no install;
- MCP `list_tools` (each Tool has the same `installed`), or with `tool` for
  one Tool;
- `slipdock tools` (the BOARD column).

Look the board up this way rather than searching for a page title. People
rename boards, and can install a Tool onto a board with a name of their
choosing.

## Worked example

A Tool, `reply-drafts`, that creates a board with:

- the lists Found, Generate, Ready, Sent and Closed;
- a page "Criteria" with skeleton content, in a folder "Config";
- a rule that queues a runner job (pool `generate`, kind `claude`, with its
  own prompt) when a card enters Generate;
- one skill with a reference file, and a `build.py` that installs beside the
  skill.

Note that "Ready" gets `"category": "doing"`, or it would take the ready
role from Found.

```
reply-drafts/
├── tool.json
├── README.md
├── board.json
├── skills/reply-drafts/SKILL.md
├── skills/reply-drafts/references/procedure.md
└── files/build.py
```

#### `tool.json`

```json
{
  "name": "reply-drafts",
  "version": "1.0.0",
  "title": "Reply Drafts",
  "summary": "A board for inbound requests: a runner drafts a reply for each one, then it is tracked to a close.",
  "files": [
    {"path": "build.py", "install": "local", "skill": "reply-drafts"}
  ]
}
```

#### `README.md`

```markdown
# Reply Drafts

Installs a board with the lists Found → Generate → Ready → Sent → Closed.
Moving a card into **Generate** queues a job for the `generate` runner pool.
Fill in **Config/Criteria** before the first run.
```

#### `board.json`

```json
{
  "lists": [
    {"name": "Found", "role": "ready"},
    {"name": "Generate", "role": "doing", "wip_limit": 3},
    {"name": "Ready", "category": "doing", "color": "emerald"},
    {"name": "Sent"},
    {"name": "Closed", "role": "done"}
  ],
  "folders": ["Config"],
  "pages": [
    {
      "title": "Criteria",
      "folder": "Config",
      "summary": "What a request needs before a reply is drafted.",
      "body": "# Criteria for {{board.name}}\n\n## Must have\n\n- \n\n## Nice to have\n\n- \n\n## Never\n\n- \n"
    }
  ],
  "automations": [
    {
      "preset": "send_to_runner",
      "name": "Draft a reply",
      "params": {
        "column": "Generate",
        "pool": "generate",
        "kind": "claude",
        "wait": "no",
        "prompt": "Use the reply-drafts skill to draft a reply for card {{card.id}} ({{card.title}}): {{card.url}}"
      }
    }
  ]
}
```

#### `skills/reply-drafts/SKILL.md`

```markdown
---
name: reply-drafts
description: Draft a reply for a card on the Reply Drafts board. Use when a runner job from the generate pool arrives, or when asked to draft a reply for a card on that board.
---

# Reply Drafts

1. Find the board: `list_tools` with tool "reply-drafts" gives `tool.installed.board`.
2. Read `Config/Criteria` on that board.
3. Follow `references/procedure.md`, then run `python3 build.py <card-id>` from this skill's folder.
4. Move the card to Ready and comment with what was produced.
```

#### `skills/reply-drafts/references/procedure.md`

```markdown
# Procedure

Read the card's description, check it against Criteria, and draft the reply.
```

#### `files/build.py`

```python
import sys

print(f"building the reply for card {sys.argv[1]}")
```

### Publish it

```sh
tar czf reply-drafts.tgz reply-drafts
curl -fsS -X POST "$SLIPDOCK_URL/api/tools" \
  -H "Authorization: Bearer $SLIPDOCK_TOKEN" \
  -F "package=@reply-drafts.tgz;type=application/gzip"
# or: slipdock tools publish ./reply-drafts
```

#### Response

`201`. The shas, sizes and timestamps differ on every server; the shape is
what is checked:

```json
{
  "tool": {
    "name": "reply-drafts",
    "title": "Reply Drafts",
    "summary": "A board for inbound requests: a runner drafts a reply for each one, then it is tracked to a close.",
    "version": "1.0.0",
    "mine": true,
    "kind": "mine",
    "installed": null,
    "sha": "3f1c…",
    "author": null,
    "requires": null,
    "published_at": "2026-01-01T00:00:00Z",
    "versions": ["1.0.0"],
    "readme": "# Reply Drafts\n…",
    "board": {
      "lists": [
        {"name": "Found", "role": "ready", "category": "todo", "color": null, "wip_limit": null},
        {"name": "Generate", "role": "doing", "category": "doing", "color": null, "wip_limit": 3},
        {"name": "Ready", "category": "doing", "color": "emerald", "wip_limit": null},
        {"name": "Sent", "category": null, "color": null, "wip_limit": null},
        {"name": "Closed", "role": "done", "category": "done", "color": null, "wip_limit": null}
      ],
      "folders": ["Config"],
      "tags": [],
      "pages": [
        {"title": "Criteria", "folder": "Config", "summary": "What a request needs before a reply is drafted.", "body": "# Criteria for {{board.name}}\n…", "template": false}
      ],
      "automations": [
        {"preset": "send_to_runner", "name": "Draft a reply", "params": {"column": "Generate", "pool": "generate", "kind": "claude", "wait": "no", "prompt": "Use the reply-drafts skill to draft a reply for card {{card.id}} ({{card.title}}): {{card.url}}"}}
      ]
    },
    "skills": [
      {
        "name": "reply-drafts",
        "description": "Draft a reply for a card on the Reply Drafts board. …",
        "files": ["SKILL.md", "build.py", "references/procedure.md"],
        "sha": "9ab2…",
        "bytes": 712,
        "version": "1.0.0",
        "skill_md": "/api/tools/reply-drafts/files/skills/reply-drafts/SKILL.md?version=1.0.0",
        "claude_zip": "/api/tools/reply-drafts/skills/reply-drafts/claude.zip?version=1.0.0",
        "chatgpt_zip": "/api/tools/reply-drafts/skills/reply-drafts/chatgpt.zip?version=1.0.0"
      }
    ],
    "skills_archive": "/api/tools/reply-drafts/skills.tar.gz?version=1.0.0",
    "files": [
      {"path": "build.py", "install": "local", "skill": "reply-drafts", "url": "/api/tools/reply-drafts/files/files/build.py?version=1.0.0"}
    ],
    "size": 1650,
    "listing": {"listed_version": null, "this_version": "not requested", "declined_reason": null}
  }
}
```

### Install it, and read a file back

```sh
curl -fsS -X POST "$SLIPDOCK_URL/api/tools/reply-drafts/install" \
  -H "Authorization: Bearer $SLIPDOCK_TOKEN"
# 201: {"install": {"board": "<code>", "created": true, "added": {"lists": ["Found", "Generate", "Ready", "Sent", "Closed"], "folders": ["Config"], "pages": ["Criteria"], "automations": ["Draft a reply"], "files": [], …}, …}}

curl -fsS -H "Authorization: Bearer $SLIPDOCK_TOKEN" \
  "$SLIPDOCK_URL/api/tools/reply-drafts/files/skills/reply-drafts/references/procedure.md"
```

`added.files` is empty because `build.py` is a `local` file. It reaches the
person's machine with the skill (`slipdock tools install reply-drafts`), not
the board. Had it been `"install": "board"`, it would be at `Tool/build.py`,
reachable with `GET /api/boards/<code>/files/Tool/build.py`.
