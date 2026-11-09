[Slipdock — the manual](../manual.md)

## MCP server

> Connecting a particular client step by step is in
> [Setting up an agent](../agents.md#over-mcp). This section is the reference:
> what the server offers, how it authenticates, and the limits it keeps.

The app is also an MCP server, at `https://your-server/mcp` — the same
address as the web app with `/mcp` on the end; **Set up an agent** shows this
install's own. It speaks stateless Streamable HTTP (MCP revisions 2025-03-26
to 2025-11-25): every call is one `POST`, nothing is kept between them, and
there is no session to resume. claude.ai, the Claude desktop and mobile apps,
Claude Code, the Claude API's MCP connector and IDE clients all connect to it.

### The tools

A client gets a small, coarse set of tools rather than the whole
[JSON API](json-api.md): every tool's schema costs context in every session of
every client that connects, so there are few of them and each does a whole
step of the work. Each one goes through the same access checks as the API,
so a token can do exactly as much over MCP as over HTTP — no more.

| Tool | What it does |
|---|---|
| `whoami` | Who the connection is signed in as, the token's scope, and how much of the account's item limit is used. |
| `get_guide` | The [agent guide](skills.md) for this caller: the conventions, and the caller's own boards and lists. Read once per session, before changing anything. Gives the short guide by default; `section` gives one of the others it names, or `all`. |
| `list_boards` | Boards you can see, with code, lists and which list is ready, in progress and done. `archived: true` includes archived ones. |
| `get_board` | A board's lists in order, with a summary of each card and its description. |
| `list_cards` | Cards in list order, filtered by `column`, `open`, `deps: "ready"`, `no_assignee` and `archived` (`exclude`, `include` or `only`). `full: true` gives each card as `get_card` does (comments, checklist, docs), 20 at a time unless `limit` says otherwise. |
| `get_card` | A card in full: description, checklist with item ids, comments, dependencies, subcards and the wiki pages about it, and on a handbook board its `handbook` (the index and the sections to read before building). With `timeline: true`, also its timeline: each list it sat in, its waits and its jobs. |
| `search` | Cards, comments and wiki pages by meaning, across every board you can read or one. `archived: true` includes archived cards; a card's id or link as `q` finds that card, archived or not. |
| `ask` | A `question` in prose, answered from the boards as `POST /api/ask` answers it, with the cards and pages it read (`id`, `title`, `kind`). `board` keeps it to one board. A model call on your own AI key and provider, so it can take a while; a token confined to some boards is refused, as it is by `/api/ask`. |
| `read_page` | A wiki page's Markdown and its `content_hash`, by code (`W-31`) or by board and slug or title. `board` says whose page it is (`id`, `code`, `name`) and whether that board is `archived` — a code reaches pages on your archived boards, which `list_boards` leaves out unless asked. A page on a board you cannot see is not found. |
| `list_pages` | A board's wiki pages in order — code, title, summary, folder, parent and pinned cards — filtered by `q`, `archived` (`exclude`, `include` or `only`), `template` and `draft`; `tree: true` nests children under their parents. `shared: true` (no board) lists what other people have shared with you, by owner. |
| `page_info` | Finding the way round a wiki, by `what`: `links` (a page's outgoing, unresolved and incoming links), `sections` (its heading paths, as `write_page`'s section modes take them), `wanted` (a board's linked-to pages nobody has written) and `resolve` (is there a page for this `title`, and the `[[link]]` to write). Drafts stay out of sight of readers who cannot edit them. |
| `page_history` | A page's revisions, newest first (`limit`, default 20): who saved each, how (`web`, `cli`, `mcp`…), the message and when. With `rev`, that revision's body and the diff it made against the one before, or with `against` (another revision id) the diff from that version instead; `diff: true` alone gives the latest save's diff. Long unchanged stretches come back as `skip` with a count, so a one-line edit does not return the whole page. |
| `wiki_info` | Your one [wiki](wiki.md#your-wiki), with its boards and Knowledge Base; with `path`, which board that path lands in and what is left of the path below it; with `link`, the page a `[[link]]` finds; with `changes_since`, what changed after a cursor. |
| `activity` | A board's activity log, newest first; `card` narrows it to one card's entries. `view: "ledger"` (with `since`) gives the [ledger](the-ledger.md) instead: what shipped since 07:00 yesterday. |
| `download_file` | A file attached to a card or a page, by its `attachment` id (`get_card` and `read_page` list them, `read_page` under `attachments`). The attachment's details come first; then a text file's contents as `text` (cut at 100,000 characters, with `truncated`), an image as an MCP image block, or anything else up to 5 MB as an embedded resource in base64. A bigger file is refused with its link in the web app. Checked as reading the card or page is: a file the token can't reach is not found. **`text: true`** (#1527) sends the words read from a PDF or an image instead (`status`, `error`, `pages`, `truncated`, `text`). **`link: true`** (#1147) sends no bytes: it answers with the attachment's details and a `download_url` that works once, for 10 minutes, with no token (`curl -fsSo cv.docx <download_url>`), so a file of any size reaches a shell without passing through the model. A read-only token may have one. The link is checked again as that token when it is used; a used, expired or unknown one is `410 link_gone`. |
| `list_automations` | A board's [automation rules](automations-and-alerts.md), as `GET /api/boards/:board/automations` gives them: each one's name, trigger, `spec`, `scope`, whether it is `enabled`, and how often it has run; `rule` (an id or name) gives one. `vocabulary: true` adds every trigger, condition and action a spec may use and the ready-made presets, so a client can write one without guessing. Only the board's owner, on a write token, may read them, as over HTTP. |
| `list_tools` | The [Tools](tools.md) the caller can install — their own, the ones shared with them, the ones listed for everyone — each with its `kind` and the board their install made (`installed.board`), which is how a Tool's skill finds its board. With `tool` (and optionally `version`), that Tool in full: its README, board blueprint, skills with shas and download links, files, and, for its owner, where listing stands. With `tool` and `file` (a path in the package, like `skills/<skill>/SKILL.md`), that file's text from the latest version, or from `version` (text up to 200 KB; anything else names the API URL to fetch). With `skill`, that skill's `SKILL.md`, or with `file` a path in its folder. With `link: true`, a single-use `download_url` (10 minutes, no token) for the file, the skill's claude.ai zip, or the skills tarball. Read-only. |
| `garden` | A board's open [tidy-up suggestions](tidying-up.md), as `GET /api/boards/:board/garden` gives them: each with its check, explanation, the cards and pages it is about, the steps applying it takes and any alternatives; plus the last run and every check's settings. `run: true` looks the board over first, which records a run and files what it finds, so it needs write access and the tool isn't marked read-only; `check` narrows to one. A read-only token can still list. |
| `create_card` | A card on a board, or with `parent` a subcard (making the sub-board if needed). |
| `update_card` | Title, description, priority (or clearing it), start and due dates, percent, flags, tags, assignees, what blocks it, its checklist — add, tick and untick items — and whether it repeats (`recurrence`, or `null` to stop it). Only what is passed changes. |
| `move_card` | To another list on its board, or with `board` to another board, subcards and all. |
| `comment` | A Markdown comment on a card; `@name` mentions notify. |
| `leave_handoff` | Leaves the card's handoff, as `POST /api/cards/:id/handoff` does: `next_step` (one line) and a `body` note, or `clear: true`; `delete: true` deletes the current one outright (its author, or anyone who can edit the card). Write one whenever you stop with the card unfinished; `get_card` shows it first. |
| `garden_decide` | Applies, dismisses or undoes one gardener suggestion (`decision`: `apply`, `dismiss` or `undo`), as `POST /api/garden/suggestions/:id/…` do. Only for what the person approved, so it needs `confirm: true`. `keep` names the card that stays for a duplicate; `choice` takes one of its alternatives. |
| `upload_file` | Attaches a file to a `card`, or to a `page` (a code, or a slug with `board`): `filename`, and the bytes as `content_base64` or a text file's contents as `text`; `content_type` (else the name decides), `hide_on_card` and `sha256` are optional. `sha256` is the hex SHA-256 of the file's bytes before base64: given, bytes that arrive different (one flipped bit leaves the size as it was) are refused with `sha256_mismatch`, saying what arrived, and nothing is stored. Up to 10 MB — the CLI's `slipdock attach` and the API take bigger files. Answers with the attachment, its `sha256` the hash of the bytes as stored (compare it with the source's to verify in one call), and the `markdown` that embeds or links it, as `POST /api/cards/:id/attachments` does, and counts towards the owner's limits the same way. **In chunks** (#1016), for anything over a few KB, since base64 written out by a model is damaged more often the longer it is: the first chunk with `append: true` (plus `card` or `page`, `filename`) and that chunk's own `sha256` answers with an `upload_id` and `received`; each next chunk sends `upload_id`, `append: true`, `offset` (the last `received`) and its own `sha256`. A chunk that doesn't match is refused with `sha256_mismatch` and the rest is kept, so only it is resent; a resend of a chunk that already landed at that `offset` isn't added twice, and a wrong `offset` is `offset_mismatch`. Then `upload_id`, `finish: true` and the whole file's `sha256` (no content) checks the assembled file and attaches it, with the same access and limit checks as a single call; until then nothing is on the card. A whole file that differs discards the upload. Unfinished uploads expire after a day, and one person may have 10 open. `replace: true` (on a single call, or on the first chunk or `finish`) deletes the card's or page's older files of the same `filename` once the new one is stored, so a rebuild leaves one current copy; their ids come back as `replaced`. The old files go only after the new one is in, so a refused upload keeps them. **`link: true`** (#1147), with only `card` or `page` (and `board`), sends no file: it answers with an `upload_url` that works once, for 10 minutes, with no token. `curl -F file=@cv.docx -F sha256=<hex> <upload_url>` then takes what `POST /api/cards/:id/attachments` takes (`file`, `sha256`, `filename`, `replace`, `hide_on_card`), up to its limit, and answers as it does. It acts as the token that asked for it: that token needs write scope, its access is checked again when the link is used, and deleting the token kills its links. A refused upload (a `sha256_mismatch`, no `file`) stores nothing and leaves the link good to try again; a used, expired or unknown link is `410 link_gone`. For a scheduled task or a shared skill that has a connector but nowhere to keep an API token. |
| `delete_attachment` | Deletes a file from a card or a page by its `attachment` id (`upload_file`, `get_card` and `read_page` give it), as `DELETE /api/cards/:id/attachments/:attachment_id` does. Needs `confirm: true`. Checked as editing the card or page is; a file the token can't read is not found. |
| `complete_card` | Marks a card completed and moves it to the done list, with an optional closing comment, and `evidence` / `commit` (what was checked, at which commit; a board may require it). On a board that verifies work it submits the card instead (see [Verified work](verified-work.md)). |
| `verify_card` | Accepts or rejects a card waiting for verification, as `POST /api/cards/:id/verify` does: `decision` (`accept` or `reject`), `reason` (required to reject) and `commit`. Not on a card you submitted. |
| `status_update` | Posts a status update on a card, as `POST /api/cards/:id/status` does: its `health` (`on_track`, `at_risk`, `off_track`) and an optional `body`. The latest is the card's stated health. |
| `archive_card` | Puts a card away, or with `restore: true` brings it back. |
| `delete_card` | Deletes a card with its subcards, comments and files. Needs `confirm: true`. |
| `create_list` | A list at the end of a board, with its category (`todo`, `doing`, `done`, `dropped`, `triage` for a list nothing feeds from, or `scheduled` for where recurring agent work lands) and an optional WIP limit. |
| `create_tag` | A tag on a board (on its root, so the whole tree shares it), with an optional colour. A tag of that name already there comes back with `created: false` rather than a second one. |
| `delete_list` | Deletes an empty list; one holding cards only with `with_cards: true`. |
| `create_board` | A board of your own, with a template's lists (Backlog, To Do, In Progress, Done by default), or `lists` of its own that `save_template` can keep as a new template. |
| `update_board` | Changes settings on a board you own, as `PATCH /api/boards/:board` does: `name`, `description`, `color`, `simple`, `default_view`, `handoff_label`, and [Verified work](verified-work.md)'s `bar_required`, `evidence_required`, `verify_work`, `verify_pool` and `ship_via`, and `lanes`, and `wait_routes` ([who gets asked](waiting-on-a-person-waits.md) each kind of question). Only what you send changes. |
| `archive_board` | Archives a board you own, or with `restore: true` brings it back. |
| `delete_board` | Deletes a board you own and everything on it. `confirm` must repeat the board's code. |
| `write_page` | The wiki: `create` a page, `append` or `append_section` to one, or `replace_section` and `replace`, which need the `content_hash` from `read_page` so nobody's edit is overwritten. |
| `update_page` | Everything about a page but its body: `title`, `summary`, `parent` (`""` for the top) and `position` among its siblings, `folder` (made if new; `""` unfiles), `also` / `not_in` (other folders it is also filed in), `archived` (`false` restores it, children too), and `pin_card` / `unpin_card` to mark it *the* page for a card you can read. Only what is passed changes. Purging a page for good stays on the CLI. |
| `quick_note` | Saves text as a note in the person's wiki: the server names it and picks the folder, as [Quick notes](quick-notes.md) does, and answers with its code, title and `location`. `write_page` is for choosing the board and title. |
| `page_tool` | Runs an AI tool over a page on your AI key (see [AI tools beside a page](ai-tools-beside-a-page.md)) and returns the answer: `summarise`, `key_points`, `actions`, `titles` or `improve`. Writes nothing. |
| `file_folder` | Files a wiki folder in one more folder as well as its home (`also`), or takes it out of one (`not_in`): a folder on its board, on `in_board`, or a wiki path. Same board or same wiki, write on both, never inside itself. Answers with where it is filed now (`also_in`). |
| `share` | Shares a wiki page (`page`, a code) or folder (`folder`, with `board`) with a person (`with`, an email) or a group of yours (`group`), `level` read, comment or write; a folder shares everything at home in it. `off: true` takes it back; neither `with` nor `group` lists who has it. Only the board's writers share; somebody it was shared with gets `shared_no_reshare`. |
| `revert_page` | Puts a page back to a revision from `page_history`. The revert is a new revision, so nothing leaves the history and it can itself be undone; it needs `base_hash`, the page's current `content_hash`, so a newer edit is not lost to it unseen. |
| `manage_wiki` | Changes your [wiki](wiki.md#your-wiki), by `action`: `set` (`shortcut`, `recordings_folder`), and `move_folder` (`board`, `folder`, `to_board`, optionally `parent`, `contents`, `dry_run`), a folder with everything in it to another board. |
| `card_views` | Your own [card views](card-views.md), what you see of a card, by `action`: `list` (your named ones, and every element), `get`, `create`, `update` and `delete` a named one; `level`, `set_level` and `clear_level` for a level (`board`, and `list`, for the board's or the list's; neither for global); `applied`, what applies on a `board` (and `list`, and a saved `view`) and which level decided each element. Elements take `show`, `hide` and `inherit`. They are a display preference: agents' own output never follows them, so change them only when the person asks. |
| `manage_automation` | Changes a board's [automation rules](automations-and-alerts.md), by `action`, as the API does and for its owner only: `create` from a `spec` (exact, no model), a `preset` with its `params`, or `text` (a sentence the server's model turns into a spec, on the AI key), with optional `name` and `scope` (`board`, or `tree` for its sub-boards too); `update` a `rule` (id or name) with any of `name`, `scope`, `enabled` and `spec`, or `text` to have the model rewrite it; `delete` a `rule` with `confirm: true` — `enabled: false` turns it off without losing it. A spec that doesn't validate is refused with the reason. |
| `install_tool` | Builds the board a [Tool](tools.md) comes with, for the caller: the lists, folders, tags, page skeletons and rules from its `board.json`, and its board files in a `Tool` folder, by `tool` (its name), with optional `version` and `board_name`. Answers with the board's code and url and what was added. Installing again answers with the board already made, and makes nothing. `tool: "handbook"` with `board` puts the built-in handbook on that board's root instead; `tool: "sweep"` with `board` puts the code sweep there (its Sweeps page, a Triage list and the daily card). |
| `skill_registry` | The [skills registry](tools.md#skills-from-elsewhere), by `action`, as `/api/skill-*` does: `sources` (yours and the seeds, each with its skills' metadata), `source`, `add` (a `url`: fetched through the egress guard), `refresh` (what was added, changed and removed) and `remove` a source, its owner only (an admin, for a seed); `entry`, one skill in full with its `content_hash`, where it is enabled and which Playbook stages name it; `enable` an `entry` on a `board`, pinned to the `hash` you read, `repin` one by `name` after reading its diff, and `disable` it, a board writer only; `stages`, every Playbook stage you can read that names a skill, with what it gets. |
| `claim_job` | Takes the oldest [runner job](runners.md) queued for a pool on a board, with a lease: the card, its link, the job's kind and prompt. Answers `nothing queued` when there is none, so an idle check costs little. The session shows in the board's runner list. |
| `job_progress` | Renews a claimed job's lease; `step`, if given, is kept on the job as what it is doing now (not on the card); `note`, if given, is also a comment on the card. Answers `ok`, or `cancel` when somebody has stopped the job. |
| `finish_job` | Ends a claimed job: `outcome` done, failed, cancelled or timeout, and a `summary` kept on the job. Only the token that claimed it may. |
| `job_log` | A runner job's [live log](runners.md) so far, as `slipdock job-log` prints it: one line per message, tool call or result of its agent. `from` carries on from an earlier call's `next`; `job.open` is false once the job has ended. Anyone who can read the card may. |
| `keep_job_log` | Keeps an ended runner job's live log, which otherwise [expires](runners.md): writes it as a page `Pass <card> (<date>)` in the card's folder and links it from the job. Again gives the same page. Needs write access to the card. |

The reading tools are marked read-only, so a client can let them run
without asking each time. The deletes are marked destructive and none of
them can be undone, which is why each needs its confirmation; archiving,
which restoring undoes, is not. Writes count towards the board owner's
limits exactly as they do through the API, and a refusal comes back as the
tool's error — `card_limit_reached`, `trial_expired`, a read-only token —
rather than as a failed connection.

Every tool's schema lists the arguments it takes and allows no others, and
the server holds it to that: an argument the tool doesn't name (`archved`
for `archived`) is refused before anything is written, with the tool's
real arguments listed. A tool that writes a card answers with the card,
always saying whether it is `archived`.

### The prompts

Besides tools the server offers **prompts** (`prompts/list`, `prompts/get`):
ready-made workflows a client lists in its own menu — the **+** menu in
Claude Desktop and claude.ai, slash commands such as
`/mcp__slipdock__plan-my-day` in Claude Code — so nobody has to know what to
ask. ChatGPT's connectors use tools only, so they don't show there.

A prompt is not canned text. It is rendered with the caller's token, with
live board data already in it — the board's lists and counts, the cards
that matter — so the model starts from the facts instead of spending its
first calls finding them. Every rendered prompt starts with the boards'
conventions, ends by naming the tools to use, and is held to about 6,000
tokens: a long list ends with "…and N more, use list_cards".

| Prompt | Arguments | What it starts |
|---|---|---|
| `plan-my-day` | `board` (optional) | My work: overdue, due today, in progress and snoozed cards waking today, and the top of each ready list. Proposes a short ordered plan and asks before moving anything. |
| `weekly-review` | `board` (optional) | The last 7 days as a narrative — finished cards and the activity — then what slipped (open, past due) and what is stale (in progress, untouched for a week). Changes nothing. |
| `triage` | `board` | The board's intake list (its Backlog or Inbox) card by card: keep, move to the ready list, tag, date or archive, as you decide each. |
| `resume` | `card` | The card's [handoff](where-it-was-left-handoffs.md), blockers, open subcards and latest comments; says where it stands and the next step. |
| `leave-handoff` | `card` | Writes the card's handoff from this conversation with `leave_handoff`, showing you the note first. |
| `tidy-board` | `board` | Looks the board over with the [gardener](tidying-up.md) and walks its suggestions one at a time with `garden_decide`. With a read-only token it lists the suggestions as they stand. |

A prompt that writes is still listed for a read-only token; its text then
says so, and the workflow reports what it would do instead. A board-scoped
token's prompts see only its boards. While you type a `board` argument the
client is offered the codes of your boards, and a `card` argument offers
`#id title` (`completion/complete`), on the board already chosen if there is
one. A connector caches the list, so after an upgrade that adds a prompt,
disconnect and connect it again (or restart Claude Code).

### The resources

A **resource** is something you attach to a conversation yourself, the way you
would attach a file: "the Q4 plan page", "the Payments board". The model then
starts with it in front of it instead of searching for it. Tools are the
model's choice; resources are yours. In Claude Desktop and claude.ai they are
under the **+** menu; in Claude Code you mention one, as in
`@slipdock:slipdock://card/42`. ChatGPT's connectors don't use them.

| Resource | What it reads |
|---|---|
| `slipdock://board/{code}` | The board: each list in order with its open cards (number, title, priority, due date, flags, assignees) and how many are done. |
| `slipdock://card/{id}` | The card in full, as `get_card` gives it: handoff, description, checklist, open subcards, the latest 10 comments and the wiki pages about it. An archived card still reads by its number. |
| `slipdock://page/{code}` | A wiki page's Markdown source, front matter included. An encrypted note comes back as its ciphertext, with a line saying so. |
| `slipdock://view/{board}/{view}` | A [saved view](swimlanes.md)'s rows. The view is its id or its name. |
| `slipdock://work` | [My work](roll-ups-the-outline-and-my-work.md): the cards assigned to you, by when they are due. |

The list a client shows (`resources/list`) is not everything you can read: a
picker of every page in a big wiki is no use. It is My work, your
[favourites](favourites.md) (boards, cards, views and pages, in the order you
marked them) and the pages pinned to your favourite boards. To put something
in the menu, make it a favourite. Anything else is reached by its URI.

Every read goes through the same access checks as the tools, with your
token's scope: a board-scoped token reads only its boards, and a read-only
token reads everything you can. A URI that names nothing you can read is
"resource not found" (`-32002`), word for word what a URI naming nothing at
all gets. Each resource is capped (about 40,000 characters, 100,000 for a
page); a cut one ends with the tool that reads the rest. There are no
subscriptions: a client reads a resource again when it wants it fresh.

### Signing in

Two ways, and the server takes either on any request:

- **OAuth**, for clients that only take an address — claude.ai and the
  Claude apps above all. The server publishes its metadata at
  `/.well-known/oauth-protected-resource` and
  `/.well-known/oauth-authorization-server`, registers clients dynamically
  at `/oauth/register`, and uses PKCE. Connecting sends you here to sign in
  and see what is asking; you approve it, or lower it to read-only first.
  Each connection appears under **Account → API tokens** as a *connected
  app* named for the client, and deleting it there disconnects it. The
  connection renews itself while it is used at least once every 90 days.
- **An API token** in an `Authorization: Bearer` header, for clients that
  take a URL and a header. Make one under **Account → API tokens** (see
  [Signing an agent in](accounts-and-sharing.md#signing-an-agent-in)). A read-only token gets the
  reading tools, and the writing tools answer that it is read-only; a token
  confined to some boards sees only those, and cannot `create_board`.

For Claude Code, either:

```sh
claude mcp add --transport http slipdock https://your-server/mcp        # then /mcp in a session to sign in
claude mcp add --transport http slipdock https://your-server/mcp \
  --header "Authorization: Bearer <token>"
```

In claude.ai: **Settings → Connectors → Add custom connector**, the name and
`https://your-server/mcp`, then **Connect**.

### Reaching it

claude.ai and the Claude apps connect from Anthropic's servers, not from
your browser, so a connector needs a server reachable from the internet over
https; if you self-host behind an allowlist, let in `160.79.104.0/21`. Claude
Code and other local clients connect from the machine they run on, so a
server on a LAN or a tailnet works for them as long as that machine can reach
it. Either way the server has to know its own public address (`PHX_HOST`,
and `SLIPDOCK_URL_SCHEME=https` behind a TLS proxy — see [Running](running.md)),
because the OAuth metadata hands out URLs built from it.

The code is `SlipdockWeb.MCP.Plug` (the transport), `SlipdockWeb.MCP.Tools`
(the list, in the order `tools/list` gives it) and one module per tool under
`lib/slipdock_web/mcp/tools/`.

---

← [Skills](skills.md) · [Contents](../manual.md)
