# Wiki: Markdown docs inside the kanban, written by people and agents

Date: 2026-09-29. Status: **built** — all six phases of §9 are implemented.
The six open questions were settled on the day it was written; §11 records
the answers and the body reflects them, and §12 records the four places
where the build had to differ.

The board answers "what are we doing". Nothing here answers "how does this
work", "what did we decide and why", "what is the shape of the thing" —
that lives in Obsidian, in Google Docs, in chat, in nobody's head. A wiki
closes that gap, but only if it is the *same* system: the same permissions,
the same semantic search, the same API an agent already knows, and links
that go both ways between a decision and the work that carries it out.

This spec is written against what exists (Sept 2026): boards with cards to
any depth, `Slipdock.Access` grants, `Slipdock.Search` hybrid semantic search,
the token JSON API with its self-describing `/api/guide`, the `slipdock` CLI,
automations with a condition vocabulary, and six board views driven by
`Slipdock.Swimlanes.Config`.

---

## 1. Shape of the thing

### 1.1 A page belongs to a board

There is no new "space" concept. **A board is the space**; a board's wiki is
a tree of pages hanging off it. This is not laziness — it buys, for free and
without a second permission model to keep honest:

* **Permissions.** `Slipdock.Access.board_permission/2` already decides who
  reads and writes a board. A page inherits it. Sub-boards inherit through
  their parent card, so a docs tree under an epic is scoped the way the epic
  is.
* **Scoping.** Search, activity, tags, templates, favourites and the board
  picker are all board-shaped already.
* **Nesting.** A board tree *is* the org chart of the work. Docs land in it
  rather than beside it.

A general-purpose wiki with no project attached is just a board whose cards
you never use — cheap, and one concept rather than two. If that proves ugly
in practice, a `board.kind = "wiki"` flag that hides the card views is a
one-line follow-up, not a re-model.

Within a board, pages form their own tree via `parent_id`, independent of
cards. Depth is unbounded; the sidebar shows it.

### 1.2 Tables

```
pages
  id
  board_id        → boards (required, indexed)
  parent_id       → pages  (nullable, tree within the board)
  title           string, required, 1..200
  slug            string, required, unique per board, derived from title, editable
  code            string, required, unique globally — "W-31", the stable short handle (§2.1)
  number          integer — the per-board sequence behind the code
  body            text, Markdown, may be ""
  summary         string, nullable — one line, shown in listings, search and link hovers
  position        integer, order among siblings
  status          "draft" | "published" (default "published"; drafts are visible to writers only)
  template        boolean, default false — a page used as a starting point, not read as content
  public_token    string, nullable, unique — published read-only at /p/:token, as saved views are
  content_hash    string — sha256 of body, the concurrency token
  created_by_id   → users
  updated_by_id   → users
  archived_at     utc_datetime, nullable — archived like cards, not deleted
  inserted_at, updated_at

boards                      -- one new column
  page_seq        integer, default 0 — the counter the next page's number comes from

page_revisions
  id
  page_id         → pages (indexed)
  title           string     — the title as of this revision
  body            text       — full snapshot, not a diff (bodies are small; diffs are computed)
  summary         string, nullable — the edit's own message ("why", not "what")
  author_id       → users, nullable
  via             string, nullable — "web" | "api" | "cli" | "assistant" | "automation"
  agent           string, nullable — the API token's name, when via is api/cli
  byte_size       integer
  inserted_at

page_links                  -- rebuilt from the body on every save
  id
  page_id         → pages (the page the link is written in)
  kind            "page" | "card" | "board" | "view" | "query" | "external"
  target_page_id  → pages, nullable
  target_card_id  → cards, nullable
  target_board_id → boards, nullable
  target_view_id  → saved_views, nullable
  raw             string  — what was written, e.g. "Retry policy" or "#412"
  label           string, nullable — the display text, when the link gave one
  resolved        boolean — false for a [[wanted page]] that does not exist yet
  pinned          boolean, default false — "this doc is the spec for that card"
  count           integer — occurrences, so a passing mention ranks below a page about it

page_tags        -- many-to-many onto the board's existing tags
  page_id, tag_id
```

Three edits to existing tables:

* `attachments.card_id` becomes nullable and `page_id` is added, with a
  check that exactly one is set — pasted images in pages use the flow cards
  already have (`Slipdock.Boards.Attachment`, `AttachmentController`).
* `access_grants.page_id` is added, alongside `board_id` / `card_id` /
  `saved_view_id`, so one page can be shared with a person or group without
  the board. The existing `validate_one_of/3` covers it. **Decided: phase
  1** — "share just this doc" should never be answered with "move it to
  another board", not even for one release.
* `activities.page_id` is added; kinds `page_created`, `page_updated`,
  `page_moved`, `page_archived` join the board's activity stream, so "what
  changed this week" includes the writing.

`search_embeddings` changes too, but that has its own section (§6).

### 1.3 Modules

Following the existing split — domain under `Slipdock`, rendering under
`SlipdockWeb`:

```
lib/slipdock/wiki.ex                  the context: CRUD, tree moves, revisions, revert
lib/slipdock/wiki/page.ex             schema + changeset
lib/slipdock/wiki/revision.ex         schema
lib/slipdock/wiki/link.ex             schema
lib/slipdock/wiki/links.ex            extract links from a body, reconcile page_links
lib/slipdock/wiki/markup.ex           parse the wiki extensions out of Markdown (no HTML here)
lib/slipdock/wiki/query.ex            a ```slipdock block → a Swimlanes.Config + filters → results
lib/slipdock/wiki/section.ex          address a page by heading: read, replace, append one section
lib/slipdock_web/wiki/renderer.ex     Markdown + extensions → safe HTML
lib/slipdock_web/live/wiki_live/*     index (tree), show, edit, history
lib/slipdock_web/controllers/api/page_controller.ex
```

`Slipdock.Wiki.Markup` returning a *structure* rather than HTML is the load-
bearing choice: the same parse feeds the HTML renderer, the link extractor,
the search chunker and the API's `render` endpoint (which resolves dynamic
blocks to Markdown, for agents). One parser, four consumers, no drift — the
way `Automations.Spec` is the one place that knows a rule's shape.

---

## 2. Markup

Bodies are **CommonMark + GFM** (tables, task lists, strikethrough,
autolinks, fenced code), plus the extensions below.

**Decided:** add `{:mdex, "~> 0.9"}` — a Rust/comrak binding giving
CommonMark + GFM with HTML sanitisation built in and no Node. The existing
`SlipdockWeb.Markdown` (an 80-line regex renderer for model answers:
paragraphs, lists, bold) stays where it is, rendering assistant replies;
growing it into a real parser to carry tables, fenced blocks and nested
structure would be a week spent owning escaping bugs someone else has
already fixed. This is the only new dependency the spec asks for, and
`AGENTS.md`'s rule against unasked dependencies is satisfied by having
asked.

### 2.1 Links

| Written | Means |
|---|---|
| `[[Retry policy]]` | a page on this board, matched by title then slug |
| `[[retry-policy\|how retries work]]` | same, with link text |
| `[[QVM/Retry policy]]` | a page on another board, by board code or name |
| `[[W-31]]` or bare `W-31` | a page by its short code — survives renames and re-slugs |
| `[[#412]]` or bare `#412` | card 412 — rendered as a live chip: title, list, status, assignee |
| `[[board:QVM]]` | a board |
| `[[view:QVM/Blocked work]]` | a saved view |
| `[[!toc]]` | table of contents from the page's headings |
| `[[!children]]` | the page's child pages, with summaries |
| `[[!backlinks]]` | everything linking here (also always shown in the page footer) |

A `[[wanted page]]` that does not resolve renders in a distinct style and
links to "create this page", carrying the title through. Wanted pages are
listed on the wiki index — the classic wiki growth mechanism, and a good
work queue for an agent ("fill in the pages people keep linking to").

Bare `#412` is only a card reference when the number matches a readable
card; otherwise it stays literal, so `#1 priority` survives. Card chips
resolve at render time, so a renamed card is never stale in prose.

**Page codes.** Every page gets a short code on creation — `W-` plus a
number, so `W-31`, matching how `#412` works for cards: short enough to say
out loud, paste into a commit message or drop in a chat, and **stable across
renames and re-slugs**, which `board-code/slug` is not. The code is globally
unique and is what the API, the CLI and `[[…]]` all accept in place of an id.
Prose inside the wiki should still prefer `[[Retry policy]]` — a code is for
the places a title would be ambiguous or would rot.

> **As built (phase 1).** This section first said the number behind the code
> came from the board's own counter *and* that the code was globally unique.
> Those cannot both hold: two boards' first pages would both be `W-1`.
> Resolving without a board is the more useful half — `[[W-31]]` and
> `GET /api/pages/W-31` carry no board with them — so the **code's number is
> global**, and `boards.page_seq` survives as the page's per-board ordinal in
> `pages.number` ("the fourth page written on this board"), which is real
> information and is what the counter was always measuring.

`@name` mentions resolve against board members and notify them (reusing the
automation notifier), unresolved ones stay literal.

### 2.2 Dynamic queries

A fenced `kanban` block is a live query, evaluated **at render time with the
reader's own permissions**. Never at write time: a doc must not become a way
to see cards you cannot open.

````
```slipdock
view: table
board: this
filter: flag=blocked, due<=+7d, priority in high|critical
group: assignee
sort: due_date asc
fields: title, assignee, due_date, status
limit: 20
empty: "Nothing blocked and due this week."
```
````

* `view:` — `table` (default), `list`, `board`, `timeline`, `calendar`,
  `count`, `progress`. Each maps onto an existing renderer: `Slipdock.Table`,
  `Slipdock.Swimlanes`, `Slipdock.Timeline`, `Slipdock.Calendar`, `Slipdock.Rollup`.
* `board:` — `this` (default), a code/name, or `tree` for the board and
  everything beneath it. Cross-board queries are allowed and filtered by
  access.
* `filter:` — the **automation condition vocabulary** (`Automations.Spec`:
  `column priority tag assignee flag title description completed archived
  blocked has_due_date has_assignee due_date start_date percent_complete
  health age_days`, with `is is_not contains any_of before after within_days
  gt lt` …), written in the compact `field op value` form. One vocabulary,
  one validator, already documented at `/api/automations/vocabulary` and
  already understood by the model that writes automations from English.
* `saved_view: "Blocked work"` — embed an existing saved view instead of
  spelling out filters. Reuse over re-expression.
* `card: 412` with `view: progress` — a roll-up bar for one card's tree,
  straight from `Slipdock.Rollup`.
* `assigned: me | @name` with `view: list` — a person's work, from
  `Slipdock.Work`, the same sections `/work` shows.

Compiles to a `Slipdock.Swimlanes.Config`, so every filter, sort, grouping and
field chooser that exists in the UI is available to a document on day one,
and the UI can offer "insert this view into a doc" from any board view —
the honest way to author these without learning the syntax.

Inline, `{{...}}` mirrors the placeholder syntax automations already use:
`{{count: flag=blocked}}`, `{{card:412.due_date}}`, `{{progress:412}}`,
`{{board.name}}`, `{{today}}`. For sentences like "there are {{count:
flag=blocked}} blocked cards as of {{today}}".

Errors never blow up a page: an unparseable block renders as a red-bordered
note with the reason, and the raw block beneath it.

Results are cached per (block, reader, board version) for a few seconds so a
doc with a dozen queries is one pass over the board, not a dozen.

---

## 3. Two-way integration with the work

The point of a wiki inside a PM tool is that neither side has to remember
the other exists.

**From a doc to the work** — §2.1 links and §2.2 queries.

**From the work to the docs** — the card detail panel gets a **Docs**
section, next to Links and Dependencies, listing every page that references
the card, pinned ones first. Pinned links carry meaning: a page pinned to a
card is *the* spec/notes/retro for it, and shows as a prominent chip on the
card, in the table view as an optional column, and in the timeline hover.
Pinning is done from either end.

A board's wiki home is reachable from the board header alongside the view
switcher (`Board · Table · Timeline · … · Wiki`).

Other joins, each small and each earning its place:

* **Create a card from a selection** in a page — selected text becomes
  title + description, with a link back to the source page written into both
  ends. The way a doc grows a backlog.
* **Create a page from a card** — "Write it up" on a card opens a new page,
  pre-titled, pinned to the card, and pre-filled from a template if the
  board has one.
* **Templates.** Pages with `template: true` (Decision record, Runbook,
  Retro, Spec) and `{{...}}` placeholders resolved on creation. Board
  templates (`Slipdock.Boards.Template`) gain a `pages` section so a new
  board arrives with its docs skeleton.
* **Status updates and comments** may `[[link]]` pages; the same extractor
  runs, so a comment pointing at a runbook shows up in that runbook's
  backlinks.
* **Automations.** A new action, `create_page` (from a template, under a
  parent, pinned to the triggering card), and a new condition,
  `has_doc` / `has_no_doc` — "when a card lands in Ready and has no spec,
  alert me" is the rule everyone writes first.
* **Favourites** gain a `page` kind; **saved queries** already store text,
  so `kind: page` search is free.

---

## 4. Editing

**Decided: raw Markdown, not WYSIWYG.** Raw Markdown in a textarea with a
live preview pane, plus the affordances
cards already have: paste an image to attach it, drag a file, slash-menu for
inserting a card reference, a page link, or a query block (the last opens
the filter chooser, not a syntax lesson). Not a WYSIWYG — the content must
stay diffable, agent-writable and greppable, and every agent on earth
writes Markdown — and a rich-text layer would have to round-trip
`[[links]]` and query blocks losslessly, which is exactly where editors of
that kind break.

**Concurrency.** Every save carries the `content_hash` it was based on. A
mismatch is a 409 with both bodies and a three-way diff — never a silent
overwrite. This matters more than usual here: two agents and a person may
all be writing the same runbook, and the failure mode of "last write wins"
is invisible data loss.

**Section editing** (`Slipdock.Wiki.Section`) is the mitigation: address a
page by heading path (`"Deploy/Rollback"`), read it, replace it, or append
to it. Two writers touching different sections do not conflict. This is the
primary write path for agents (§5) — appending a dated note under
`## Log` should never require sending the whole document back.

**History.** Every save writes a revision. The history view lists them with
author, `via`, edit summary and size delta; any two can be diffed; any one
can be reverted (which is itself a new revision, never a deletion). Agent
edits are badged, so "what did the robot change" is one filter. Retention:
keep everything (bodies are kilobytes); collapse consecutive revisions by
the same author within 10 minutes into one.

---

## 5. Agent capability

The premise: **anything a person can do to a page, a token can do over
HTTP**; the API tells the agent how without anyone pasting docs into a
prompt; and the skills that teach an LLM to use it ship from this repo and
are served by the running app (§5.5), so they cannot drift from it. This is
how the rest of the system already works — keep it.

### 5.1 REST

```
GET    /api/boards/:board/pages            tree or flat; ?q= substring, ?tag=, ?template=, ?archived=
POST   /api/boards/:board/pages            {title, body, parent, summary, tags, template}
GET    /api/pages/:id                      Markdown source + metadata + links + backlinks
                                           (:id accepts a numeric id, a code like W-31,
                                            or board-code/slug)
PATCH  /api/pages/:id                      {title?, body?, summary?, status?, base_hash?, message?}
DELETE /api/pages/:id                      archive (?purge=true for owners)
POST   /api/pages/:id/restore

GET    /api/pages/:id/render               dynamic blocks resolved; ?format=markdown|html|text
GET    /api/pages/:id/section/:path        one heading's text
PUT    /api/pages/:id/section/:path        replace it        (base_hash aware)
POST   /api/pages/:id/section/:path        append to it      (never conflicts)
POST   /api/pages/:id/append               append to the page

POST   /api/pages/:id/move                 {parent, position} — reparent / reorder
GET    /api/pages/:id/revisions
GET    /api/pages/:id/revisions/:rev       body, and ?diff=previous
POST   /api/pages/:id/revert               {revision_id, message}

GET    /api/pages/:id/links                outgoing, incoming, unresolved
POST   /api/pages/:id/links                pin/unpin a card or page relation
GET    /api/boards/:board/pages/wanted     links written but never created
GET    /api/pages/resolve?title=…&board=…  title → id, for writing links safely
POST   /api/boards/:board/pages/from-template {template, title, values}
```

Search (§6) gains `?kind=card|page|all`, and cards gain
`GET /api/cards/:id/pages`.

Deliberate choices:

* **`render` is a first-class endpoint.** An agent reading a doc full of
  live queries needs the *answers*, not the query blocks. `format=markdown`
  returns tables it can reason over.
* **Reads return Markdown source by default.** Not HTML, not a JSON AST.
  The model edits what it reads.
* **`base_hash` is optional but recommended**, and the guide says so. Omit
  it and you get last-write-wins with a revision to recover from; send it
  and you get a 409 you can merge.
* **Section append is the cheap, safe write.** An agent logging progress
  into a running doc costs one small request and can never clobber.
* **Every write records `via` and the token's name**, so provenance is
  visible in history without a separate audit log.

### 5.2 CLI

`slipdock page ls|tree|read|render|new|edit|append|section|mv|rm|links|wanted|
history|diff|revert|pin|publish`, following the existing `cli/` patterns —
`read` prints Markdown to stdout, `edit` takes a body on stdin or `$EDITOR`,
everything takes `--json`. Agents on a shell use this; agents over HTTP use
§5.1; both hit the same controllers.

### 5.3 The guide

`SlipdockWeb.APIGuide` gains a wiki section, since it is what an agent reads
first: the endpoints, the markup extensions (with the query vocabulary
inline), and — as important — the **conventions**:

* a page per durable thing, not per conversation;
* one `## Log` section for dated append-only notes, so agents append and
  people do not have to read a diff;
* pin the page to the card it explains;
* write a `message` on every edit, saying why;
* prefer `[[links]]` to prose references so the graph stays real;
* prefer a live query block to a hand-written list that will go stale;
* do not rewrite a section you did not author without saying so in the
  message.

The `skills/slipdock-work` skill gets the same, so board-driven agent work
naturally leaves documentation behind.

### 5.4 The in-app assistant

`Slipdock.AI.Researcher` gains tools: `search_pages`, `read_page`,
`list_pages`, and in edit mode `write_page` / `append_section` proposals
routed through `Slipdock.AI.Actions` (proposed, shown, applied on confirm —
the existing pattern, so an agent cannot silently rewrite a document from a
chat box). `Slipdock.AI.Context` includes the current page when the chat is
opened from one, so "summarise this and make cards for the open questions"
works on the page you are looking at.

### 5.5 Skills shipped with the system

The CLI already ships `cli/SKILL.md` (a command reference) and
`skills/slipdock-work/SKILL.md` (a workflow that starts by fetching the
server's own `/api/guide`). The wiki follows the same two-part shape,
because it works: **a skill says when and how to reach for the thing; the
running server says what is currently true.** A skill that hardcodes board
names, list names or endpoint shapes rots; one that tells the agent to read
`slipdock guide` first does not.

Three new skills, each with the same anatomy (YAML frontmatter with a
trigger-rich `description`, a short body, details in `references/`):

**`slipdock-wiki` — the reference.** Sibling to `cli/SKILL.md`, and the one
loaded whenever the user mentions docs, notes, a runbook, a spec, "write it
up", "where is it documented", or a wiki page.

```
skills/slipdock-wiki/
  SKILL.md                    ~120 lines: auth, find, read, write, link, search
  references/markup.md        the [[link]] forms, chips, TOC/children/backlinks
  references/queries.md       the ```slipdock block: views, filter vocabulary, {{…}}
  references/api.md           the REST surface, for agents with no CLI
```

Its body covers, in order: finding pages (`slipdock page tree <board>`,
`slipdock page ls --tag`, and semantic `slipdock search --kind page`); reading
(`slipdock page read` for source, `slipdock page render` when the doc contains
live queries — with a loud note that these differ and why); writing
(`new`, `section`, `append`, `edit --base-hash`); and linking (`pin`,
`links`, `wanted`). The write section leads with **append/section, not
whole-body edit**, because that is the difference between an agent that
collaborates on a document and one that quietly deletes a colleague's
paragraph.

**`slipdock-docs` — the workflow.** The counterpart to `slipdock-work`: not
"how do I call it" but "what belongs in a document, and where". Triggered by
asking to document something, write up a decision, record a retro, keep
notes on an investigation, or check what is already written before starting
work. It opens the way `slipdock-work` does:

```sh
slipdock guide --section wiki      # the server's own conventions, once per session
```

and then states the judgement calls that a model otherwise gets wrong:

* **Search before writing.** `slipdock search --kind page "<the thing>"` —
  the most common agent failure here is a fourth page about deployment.
  Extend an existing page unless the subject is genuinely new.
* **A page or a comment?** Durable and re-read → a page. About one card and
  about *now* → a comment or status update on the card. Never both.
* **Pin it.** A page that explains a card is pinned to it, so the person
  looking at the work finds the writing without searching.
* **Append to `## Log`, don't rewrite.** Dated entries, newest last.
* **Write the edit message.** `--message "why"`, every time; history is the
  audit trail and `via`/`agent` already records that a robot did it.
* **Link, don't restate.** `[[Retry policy]]` beats a paraphrase that will
  be wrong in a month.
* **Query, don't list.** A hand-typed list of blocked cards is stale on
  Tuesday; a ```slipdock``` block never is.
* **Leave wanted pages.** Linking `[[Rollback procedure]]` before it exists
  is how the next agent finds the work — `slipdock page wanted` is a backlog.
* **Don't rewrite someone else's section** without saying so in the message.

**`slipdock-wiki-author` — the long-form worker.** Optional, phase 6: the
skill for "read the board and write the spec / the onboarding doc / the
quarterly summary". It is the researcher loop expressed as a skill —
gather with `search`/`read_card`/`list_cards`, draft with a template,
embed live queries rather than snapshots, pin, and report back with the
page URL. Kept separate because its instructions are about structuring a
document, not about the API, and mixing the two makes both worse.

**Distribution — the part that matters.** Skills that live only in this
repo are skills that drift. The server serves them, and the CLI installs
them:

```
GET  /api/skills                  list: name, description, version, sha
GET  /api/skills/:name            SKILL.md
GET  /api/skills/:name/:file      a references/ file
```

```sh
slipdock skills install             # writes ~/.claude/skills/slipdock*/…, honours --dir
slipdock skills check               # warns when the local copy is behind the server's
```

The board-specific parts — board codes, list names, tag vocabulary, which
boards have wikis — stay out of the skill files entirely and come from
`slipdock guide`, which already appends the caller's own boards and lists when
a token is present. `/api/guide` grows a `wiki` section (§5.3) and accepts
`--section` / `?section=` so a docs-focused agent can read a page rather
than the whole manual.

The same three files are what a non-Claude agent gets too: they are plain
Markdown with a `curl` form beside the CLI one, exactly as `slipdock-work` is
today.

---

## 6. Semantic search

Pages must be searchable by meaning alongside cards, through the same
`Slipdock.Search` — a separate doc search would be the whole point missed.

**Schema.** `search_embeddings.card_id` becomes nullable, `page_id` is
added, and the `kind` set grows `page` and `page_section`. The unique key
stays `{kind, source_id}`. `board_id` stays required and non-null, which is
what the permission filter runs on, so the fast path is unchanged.

**Chunking.** `Slipdock.Search.Chunk.for_page/1` splits a page **by heading
section**, not by fixed window: a section is what a person wrote as a unit,
and a heading is a free label for it. Each chunk repeats its context the way
card chunks do — board, page path, heading — because a vector has no context
but its own text. A short page is one chunk. A section longer than ~1500
characters is split on paragraph boundaries with the heading repeated.

**Results.** `Slipdock.Search.search/3` currently rolls chunks up to a card and
returns `%{card:, score:, matches:}`. It grows a `:kind` (`"card"` |
`"page"`) and a `:subject`, with `:card` kept as-is for cards so nothing
existing breaks. Rollup for pages is to the page (not the section), carrying
the matching sections as snippets with anchors, so a result links to
`…/wiki/runbook#rollback`. Callers to update: `SearchLive.Index`, the API
search controller, the researcher's tool rendering.

**Indexing.** `Slipdock.Search.Indexer` gains a page queue, enqueued on save
like cards. Content hashing means an edit re-embeds only the sections that
changed — the reason for chunking by section rather than by page.
`mix slipdock.reindex` covers pages in its backfill.

**Ranking.** Pages are long and therefore semantically diffuse; a runbook
will match nearly everything about deploys weakly. Two corrections: the
keyword boost applies to the page *title* as well as the body, and page
results carry a small penalty against card results of equal score (the card
is the live thing; the doc explains it). Both are constants next to
`@keyword_boost`, tuned once there is a corpus.

`Slipdock.Search.stats/0` reports pages alongside cards.

---

## 7. Permissions and publishing

* Page permission = board permission, raised by any direct page grant
  (`Access.page_permission/2`, mirroring `card_permission/2`). Ships in
  phase 1.
* `:view`-level board access (view-grant holders) does **not** reach pages.
  A shared saved view is a window onto cards; it must not leak documents.
* Drafts (`status: "draft"`) are visible to writers and owners only.
* `public_token` publishes a page read-only at `/p/:token`, like saved
  views. Published pages render dynamic query blocks **as of publish time,
  frozen**, not live — an anonymous reader must never drive a query against
  private data. Card chips degrade to plain text.
* Archive, never hard-delete, except a purge by the board owner.

---

## 8. UI

```
/boards/:id/wiki                    tree + recently changed + wanted pages
/boards/:id/wiki/:slug              a page
/boards/:id/wiki/:slug/edit
/boards/:id/wiki/:slug/history
/boards/:id/wiki/:slug/history/:rev
/wiki                               across every readable board: recent, favourites, search
```

Page view: breadcrumb (board › ancestors), title, summary, body, then
children, backlinks, tags, last edited by/when. Right rail: TOC, pinned
cards, "Ask about this page". Keyboard: `e` edit, `h` history, `/` search.

The board header's view switcher gains Wiki. The global search page gains a
Pages filter. Card panel gains the Docs section (§3).

---

## 9. Build order

Each phase is shippable and useful on its own; API and CLI land *with* each
phase, not after, because that is how the rest of this system is built.

1. **Pages exist.** Schema (including page codes and `boards.page_seq`),
   `Slipdock.Wiki`, permissions **including per-page grants**, revisions,
   tree, archive. REST + CLI. `:mdex` rendering from the start — it is one
   dependency and phase 2 needs it anyway. Minimal LiveView: tree, read,
   edit with preview, history.
2. **Wiki links and markup.** `[[links]]` in every form (title, slug, code,
   cross-board), card chips, backlinks, wanted pages, TOC/children,
   attachments and paste,
   `resolve` endpoint, section read/replace/append. The `slipdock-wiki` and
   `slipdock-docs` skills, and `slipdock skills install` to distribute them.
3. **Slipdock integration.** Docs section on cards, pinning, create-card-from-
   selection, create-page-from-card, templates, activity entries,
   favourites.
4. **Dynamic queries.** `Slipdock.Wiki.Query`, the block language, insert-view
   from any board view, inline `{{…}}`, publishing freeze.
5. **Semantic search.** Chunking, indexer, result rollup, reindex task,
   assistant and researcher tools, `/api/guide` wiki section, and the
   search-before-you-write step in `slipdock-docs` (which only becomes true
   advice once pages are indexed).
6. **Polish.** Public publishing, automation action/condition,
   export (a board's wiki as a zip of `.md` with links rewritten — the
   Obsidian escape hatch), import of a Markdown folder.

---

## 10. Testing

Per house rules: `mix precommit` before done,
`mix ecto.gen.migration` for every schema change, and the dev server is
`slipdock.service` — restart it after config changes.

Worth explicit tests: link extraction and reconciliation (including renames
— renaming a page must not break inbound links, which is why links resolve
by id once resolved and by title only when wanted); `base_hash` conflict;
section addressing with duplicate and nested headings; query blocks
evaluated as a *reader with fewer permissions* (the leak test); published
pages not running live queries; embedding re-use when only one section
changed; and revert producing a new revision.

---

## 11. Decisions, and what they cost

Settled 2026-09-29.

1. **Markdown: add `:mdex`.** CommonMark + GFM + sanitisation from
   comrak, no Node. One new dependency; native compilation on every host
   that builds the app (including ps-prod-1). `SlipdockWeb.Markdown` stays
   for assistant replies. → §2.
2. **Board-scoped only.** A wiki always belongs to a board; docs with no
   project get a board of their own. No global namespace, no second
   permission path. If it chafes, `board.kind = "wiki"` hides the card
   views without a re-model. → §1.1.
3. **Per-page grants in phase 1.** `access_grants.page_id` and
   `Access.page_permission/2` ship with the first release rather than in
   phase 6. Costs a migration and a mirror of `card_permission/2`; buys a
   real answer to "share just this doc" from day one. → §1.2, §7.
4. **Raw Markdown editor with live preview.** No WYSIWYG, now or later.
   The source stays diffable, greppable and identical to what agents read
   and write. The slash-menu and the insert-this-view affordance carry the
   authoring load instead. → §4.
5. **Skills in this repo, served by `/api/skills`.** Versioned with the
   code they describe, installed by `slipdock skills install`, checked by
   `slipdock skills check`. Board-specific detail stays out of them and
   comes from `slipdock guide`. Costs an endpoint and two CLI commands;
   buys skills that cannot drift from the API. → §5.5.
6. **Pages get short codes (`W-31`).** Globally unique (see the "as built"
   note in §2.1: the sequence is global, and `boards.page_seq` became the
   per-board ordinal in `pages.number`), stable across renames and re-slugs,
   accepted by the API, the CLI and `[[…]]` wherever an id is. Costs a
   column, a counter taken in the insert transaction, and a third way to
   name a page alongside slug and title — mitigated by the rule that prose
   inside the wiki prefers `[[Retry policy]]` and codes are for the places
   a title would rot. → §1.2, §2.1, §5.1.

## 12. Built, and what changed on the way

All six phases are implemented (Sept 2026). Four things turned out
differently from this document, and each is recorded where it lives:

1. **Page codes are globally sequential**, not per-board. A per-board counter
   cannot be globally unique, and resolving `W-31` without a board is the more
   useful half. `boards.page_seq` survives as the page's per-board ordinal in
   `pages.number`. → §2.1, §11.6.
2. **`search_embeddings` keeps a `section` column**, so its key is
   `{kind, source_id, section}`. §6 expected the key to stay as it was; it
   cannot, once one page is many chunks. → the phase-5 migration.
3. **`timeline` and `calendar` query views are presets** of `table` and
   `board`. A document is a column of text, not a canvas; link the real view
   with `[[view:…]]` when the picture is the point. → `Slipdock.Wiki.Query`.
4. **`page_links` has a polymorphic source.** §3 wanted comments and status
   updates to count as writing; that needs a source beyond the page, so the
   table has one, with exactly one source per row enforced by the database.
   → the phase-3 migration.

The skills live in `priv/skills/` rather than `skills/` and `cli/`, served by
`/api/skills` and installed by `slipdock skills install` — one home rather than
two, which is what §5.5 was asking for.

## 13. Added after the fact: a page on the board

Not in the original specification, and asked for once it was running: a page
can be put in one of its board's lists and dragged about like a card.

`pages.column_id` and `pages.board_position` are a second, optional axis —
the page keeps its place in the wiki tree either way. The position is shared
with the list's cards, so the two interleave: `Slipdock.Boards.active_items/1`
returns a list's contents as `{:card, id}` / `{:page, id}` refs in one order,
and both move operations repack that order together. A page that could only
sit after every card would not really be on the board.

It was drawn as a plain tile at first, on the reasoning that a card is work
with a state and a document has none of that. Asked for again straight after
— "let's make them even more like cards" — and the reasoning turned out to be
wrong in an interesting way, which §15 records.

## 15. Added after the fact: the card's facets on a page

A page carries `priority`, `flags`, `start_date`, `due_date`,
`date_precision`, `completed`, `percent_complete`, `color` and `assignee_id`,
under the card's field names and validated against the card's vocabularies —
`Slipdock.Wiki.Page.validate_facets/1` mirrors `Slipdock.Boards.Card`'s, dates
snapping to whole buckets and all. Tags a page already had.

**The line, and why it is there.** A card's attributes divide cleanly in two:

* **Facets** — what says *where a thing stands*. These are exactly what a
  board groups, filters and sorts by, and they are what a document can
  honestly answer: this spec is high priority, due Friday, Sam's, 40% done.
* **Contents** — checklists, comments, dependencies, votes, custom fields,
  sub-cards, status updates. A document has better versions of every one of
  these. A checklist on a page that has headings is a worse checklist.

A page takes the facets and refuses the contents. The refusal is not an
error, though: the contents are declared as **virtual fields with empty
defaults** (`field :checklist_items, {:array, :map}, virtual: true, default:
[]`), so anything that reads a card can read a page and get an honest empty.
`Page.for_board/1` sets the one field whose name differs, `description` from
`summary`.

**Shape-based readers.** The consequence is that `Slipdock.Boards.Card`'s
*readers* — `fuzzy?/1`, `effective_due/1`, `starts_on/1`, `progress/1`,
`blocked?/1` and the rest — now match on shape (`%{date_precision: p}`)
rather than on `%Card{}`. Everything that *writes* still takes a card and
nothing else. That one change is what lets a single component draw either,
and is why the page appears in every view — board, swimlanes, table,
timeline, calendar — grouped, filtered and sorted beside the cards, rather
than only on the board. `Swimlanes.move_ops/5` needed nothing: dropping a
page into the "Critical" row already produced `{:attrs, %{"priority" =>
"critical"}}`, which `Wiki.update_page/3` accepts.

**Two gestures on one tile.** A small document icon sits where a card's tick
box would be, *outside* the tile's click target so the two never race:
clicking it navigates to the document, clicking anywhere else opens a
card-style panel (priority, assignee, dates, precision, percent, colour,
visibility, flags, tags, list) which itself has an "Open the document"
button. `SlipdockComponents.item_id/1` gives every per-item DOM id its
`page-` prefix, without which a page and a card sharing a number collide —
which is also why `Timeline` de-duplicates on `{struct, id}` rather than on
`id`.

The keyboard cursor stays card-only (`card_focus/2` returns `nil` for a
page): the shortcuts it drives are card operations.

Asked for again immediately — "wiki pages should be allowed comments, and
status updates; in fact nearly everything cards have" — which §16 records.

## 16. Added after the fact: the card's contents on a page

§15 drew a line between a card's facets and its contents and gave a page only
the facets. The line did not survive contact: a spec people are working
through wants a comment on the draft and a "stalled on the SRE review" as
much as any card does, and "a document has better versions of those" was true
of *prose* and not of the conversation around it.

So a page now holds **comments, status updates, a checklist, web links,
votes and custom field values**. The migration is the interesting part:
rather than a second set of tables, each existing table grew a nullable
`page_id` beside its `card_id` with

```sql
CHECK ((card_id IS NOT NULL) + (page_id IS NOT NULL) = 1)
```

— the shape `attachments` already had. (Under SQLite, which this ran on at
the time, a `NOT NULL` could not be dropped, so all six tables were rebuilt;
the Postgres baseline simply declares them nullable.) `Slipdock.Boards.Owned`
states the rule once for all of them: `validate_owner/1` turns the constraint
into a readable message, `owner_key/1` gives the foreign key to `struct!`
onto a new row, and `owner_ref/1` reports which it is as the board's usual
`{:card, id}` / `{:page, id}`.

**One writer each.** `Boards.add_comment/2`, `add_status_update/3`,
`add_checklist_item/2`, `add_card_url/2`, `Votes.set/4` and
`Fields.set_value/3` take a card or a page and route the three side effects —
the activity line, the broadcast, the re-index — through `log_owned/3` and
`notify_owned/1`. There is no second implementation to drift.

**One set of components.** The card panel's markup for these six moved into
`SlipdockWeb.ItemComponents`, taking `item`. The card panel, the board's page
panel and the page's own view all draw them, and the events behind them are
the same names. In `BoardLive.Show`, `subject/1` is the whole of it: the open
page when a page panel is up, the open card otherwise. `@item_write_events`
is guarded by `item_can_write`, which follows the subject.

**A comment on a page is writing too.** `page_links` grew `source_page_id`,
the twin of the `source_card_id` that already carried "the card this remark
was written on". `Links.name_the_source/1` fills a comment link's `page` in
from it, so every reader of a backlink — the permission filter, the sidebar,
the API — asks one question rather than two.

**The CLI took no new commands.** `comment`, `check`, `status`, `vote`,
`weblink` and `unweblink` route on the shape of the reference: a number is a
card, anything else (`W-31`, `board/slug`) is a page. Deleting a checklist
item or a comment already went through `/checklist/:id` and `/comments/:id`,
which now authorise against whichever the row hangs off.

**What is still card-only**, and this time for a reason that holds: blocking
dependencies and typed card links are card-to-card joins carrying scheduling
meaning, and would need a polymorphic join on *both* ends to say something a
page already says better with `[[wikilinks]]`, backlinks and pins. Sub-cards
are what child pages are. Those four stay virtual empties.

**Two things followed from it.** The document's own view grew the six
sections below the prose — as an `items-start` grid of small panels, not a
tall rail beside the text, which ran on far below everything else on the
page. And the wiki grew the board's toolbar: `view_tabs/1` and
`filter_menu/1` moved from `BoardLive.Show` into `SlipdockWeb.SlipdockComponents`
and the filter predicate into `Slipdock.Filters`, which reads a card or a page
by shape. The wiki is one more way of looking at a board, and a page is one
more thing that answers a filter. Its display menu is its own — drafts,
templates, archived — because those are what a *tree* shows rather than what
a filter narrows.

## 17. Added after the fact: a page from the foot of a list

The board's lists grew **Add a page** and **Add a document** beside **Add a
card** — one row of three small buttons, named by their hover text, because a
list is narrow. All three are shortcuts to putting one more item in a list,
which is why none of them is a new kind of thing: a document becomes a card
named after the file with the file attached through `Boards.add_attachment/3`.

**Add a page is a link, not a form.** It goes straight to
`/boards/:id/wiki/new?column=<id>` — the wiki's own Markdown editor, which is
where a page is written; a one-line title box would have been the card form
wearing a document's name. The editor says which list the page will land in,
and `save/4` calls `Wiki.place/3` once the page exists.

`boards.add_card`, `add_page` and `add_document` say which to offer, settable
in the board's settings, over the API and from `slipdock set-board`. A board
that never holds documents would rather not look at the button.

Three things about the document upload, every one of them found by driving a
real browser and invisible to `render_upload/2`:

* A `live_file_input` **must sit inside a form with a change binding**.
  LiveView picks the file up from the form's change event, so a bare input
  takes the file and does nothing whatever with it — `files: 1` on the
  element, `data-phx-active-refs` empty, no error anywhere.
* The input is **one per board**, not one per list: a hidden input in every
  column is a duplicate id. The button reaches it with
  `JS.dispatch("click", to: "##{ref}")` rather than a `<label for=…>`, so the
  one gesture both records the list and opens the picker. Its id is the
  upload's ref — `live_file_input/1` names it and ignores an `id` of yours.
* Which list a file lands in is `aim_document`'s job, pushed by that same
  gesture, because the upload that follows carries no column. When it is
  somehow missing the handler now **says so**: a file that vanishes without a
  word is indistinguishable from a button that does nothing.

## 18. Still open, but not blocking

None of these need answering before phase 1 starts; each is a judgement
best made with something running.

* **Revision retention.** The spec keeps everything and collapses
  consecutive same-author edits within 10 minutes. Revisit if an agent
  writing every few minutes makes history unreadable.
* **Ranking of pages against cards** in search results (§6) — the penalty
  constant needs a real corpus before it means anything.
* **Whether `slipdock-wiki-author`** (§5.5, phase 6) is worth writing, or
  whether `slipdock-docs` plus the researcher loop covers it.
* **Import.** Phase 6 mentions a Markdown-folder import; the Obsidian
  vault is the obvious first customer, and its wikilink dialect is close
  enough to this one to be worth checking before committing to a format.
