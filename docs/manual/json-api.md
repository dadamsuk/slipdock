[Slipdock — the manual](../manual.md)

## JSON API

Everything the UI can do is available under `/api`. Every request needs an
API token (create one under Account) as `Authorization: Bearer <token>`;
`GET /api/me` shows who the token belongs to, whether their API key is on file
(`ai_key`), and which endpoint and model their AI requests use (`ai`).
`PUT /api/me/ai-key {"api_key": "sk-or-…"}` sets that key,
`DELETE /api/me/ai-key` removes it; the key itself is never read
back out, only its masked shape.
`PUT /api/me/ai-provider {"base_url": "http://llm.local:1234/v1", "model": "…"}`
points them at a model of their own (only the fields sent are changed, `""`
clears one), and `GET /api/me/ai-models` lists what that endpoint can run.

`GET /api/guide` is the exception: it needs no token and answers in Markdown
with the API's own instructions for an agent — the model, the convention that
top-level cards are epics holding their tasks as subcards, how to choose what
to do next (in progress before To Do before Backlog, depth first through an
epic's subcards, skipping what is blocked), and what to write back while
working (claim, comment, flag, complete). The vocabularies and the endpoint
list in it are generated from the code at request time, and a token earns a
closing section naming your boards and what each of their lists means.
`?format=json` returns the same text plus those parts as data, and
`slipdock guide` prints the short guide, `slipdock guide <name>` a section and
`slipdock guide all` the whole of it. The whole of it is long (tens of thousands of
words), so `?section=short` gives the part needed to work a board, ending with
the names of the other sections, and `?section=<name>` one of them, the same
cuts the MCP `get_guide` tool serves; `?section=all`, like the plain URL, is
the whole guide, and an unknown name is a `404` listing the names there are. Point an agent at it before letting it near a board. Permissions match the UI:
reading needs read access, changing needs edit access, and renaming or
deleting a board needs its owner. Boards and columns can be referenced by id
or name, and a board by its code as well — `/api/boards/qvm-v1-rem`.

```
GET    /api/search   ?q= &board= &limit= &archived= &kind=card|page|all
                                                        search every board you can read, by meaning
GET    /api/search/status                               what is indexed, and whether anything is queued
GET    /api/saved-queries   ?mode=search|ask            your own saved queries (yours alone)
POST   /api/saved-queries   {mode, q}                   save one; saving it twice saves it once
DELETE /api/saved-queries/:id      DELETE /api/saved-queries   {mode, q}
POST   /api/ask     {q, history: [{role, content}]}     ask the assistant; it searches for itself
GET    /api/templates                      POST   /api/templates   {name, description, columns: ["Name" | {name, wip_limit, color}]}
GET    /api/templates/:id                  PATCH  /api/templates/:id   DELETE /api/templates/:id
GET    /api/boards                         POST   /api/boards   {name, code, description, color, template,
                                                   columns: ["Name" | {name, wip_limit, color, category}],
                                                   save_template: "Name" | true}
       ?archived=true|all &sort=manual|name|active|newest|oldest|cards
GET    /api/boards/:board                  PATCH  /api/boards/:board   DELETE /api/boards/:board
POST   /api/boards/:board/archive          POST   /api/boards/:board/restore   (owner only)
POST   /api/boards/order   {boards: [ref, ...]}   your own order for the index; others unaffected
POST   /api/boards/welcome   {force}   build the Getting Started tour board (409 if you have one)
GET    /api/boards/:board/cards            POST   /api/boards/:board/cards
       ?column= &tag= &priority= &flag= &q= &completed= &archived=true|all
       &due=overdue|today|week|month|has|none  &deps=blocked|ready|blocking|violated|free
       &assignee=EMAIL|NAME|me|none            (the board views' own filters; a bad bucket is a 400)
       POST takes "archived": true to make the card straight into the archive
GET    /api/boards/:board/columns          POST   /api/boards/:board/columns
PATCH  /api/boards/:board/columns/:id      DELETE /api/boards/:board/columns/:id
GET    /api/boards/:board/tags             POST   /api/boards/:board/tags
DELETE /api/boards/:board/tags/:id         GET    /api/boards/:board/activity?limit=&card=
GET    /api/boards/:board/swimlanes         ?view= &rows= &cols= &unit= &sort= &dir= &q= &due= &done= &empty=
                                            &tags= &priorities= &flags= &columns= &colors=   (lists are comma-joined)
GET    /api/boards/:board/views            POST   /api/boards/:board/views   {name, ...config params}
GET    /api/boards/:board/views/:id        PATCH  /api/boards/:board/views/:id   DELETE /api/boards/:board/views/:id
GET    /api/favourites                     POST   /api/favourites   {kind: board|column|card|view|page, id}
DELETE /api/favourites/:kind/:id           (yours alone; both writes are idempotent)
GET    /api/card-views                     your named card views, and every element   POST {name, show, hide}
GET    /api/card-views/:id                 PATCH  /api/card-views/:id {name, elements, show, hide, inherit, reset}
DELETE /api/card-views/:id                 (by id or name; yours alone)
GET    /api/card-views/level  ?board= &list=      a level: neither is global, board alone the board's
PUT    /api/card-views/level  ?board= &list=      {card_view, elements, show, hide, inherit, reset, show_all}
DELETE /api/card-views/level  ?board= &list=      clears it, so it inherits everything (PATCH as PUT)
GET    /api/card-views/applied ?board= &list= &view=   what applies, each element with the level that decided it
GET    /api/cards/:id                      PATCH  /api/cards/:id       DELETE /api/cards/:id
POST   /api/cards/:id/move   {column, index: "top"|"bottom"|N}
POST   /api/cards/:id/move   {board, column}   to another board, with its subcards; answers
                                               `moved: {tags_created, fields_dropped, milestones_unpinned}`
POST   /api/cards/:id/archive              POST   /api/cards/:id/restore
POST   /api/cards/:id/timer {action: start|stop}   stopping adds the minutes it ran to time spent
POST   /api/cards/:id/checklist {text}     POST   /api/checklist/:item_id/toggle   DELETE /api/checklist/:item_id
POST   /api/checklist/:item_id/move {before}   before another item of the same card or page, or last
                                               without one; answers {items} in the new order
POST   /api/cards/:id/comments {body}      DELETE /api/comments/:comment_id
GET    /api/cards/:id/handoff              POST   /api/cards/:id/handoff {next_step, body} | {clear: true}
DELETE /api/cards/:id/handoff              the current one, outright: {deleted, handoff} (the one now current)
GET    /api/cards/:id/timeline             the lists it sat in, its waits and jobs, as spans
POST   /api/cards/:id/dependencies {blocked_by: id} | {blocks: id}
POST   /api/cards/:id/subboard {template}  DELETE /api/cards/:id/subboard
GET    /api/boards/:board/sprints/next     (what New sprint would fill in: name, start, days)
POST   /api/boards/:board/sprints {name, start, days, goal}   all optional; answers the sprint card
POST   /api/cards/:id/sprint {cards: [id...]}   move cards into a sprint; answers `added` and
                                               `skipped` ({id, reason}) — a board's `kind` is
                                               "sprints" on a sprint board (PATCH it to set one)
GET    /api/cards/:id/burndown             a sprint's {sprint, total, done, estimate, days:
                                               [{date, remaining, remaining_estimate, ideal}]};
                                               remaining is null for days still to come
GET    /api/boards/:board/sprints/velocity {sprints: [{id, title, start, due, committed,
                                               completed, committed_estimate, completed_estimate,
                                               finished}], average} — estimates in minutes
DELETE /api/cards/:id/dependencies/:other_id     (either direction)
GET    /api/automations/vocabulary         (the grammar a spec is written in, plus an example)
GET    /api/automations/presets            (the ready-made rules, and the fields each one takes)
GET    /api/boards/:board/automations      POST   /api/boards/:board/automations   {spec | preset+params | text, name, scope}
GET    /api/boards/:board/automations/:id  PATCH  /api/boards/:board/automations/:id   {enabled | name | spec | text}
DELETE /api/boards/:board/automations/:id  POST   /api/boards/:board/automations/:id/run
GET    /api/alerts                         DELETE /api/alerts/:id   DELETE /api/alerts
GET    /api/boards/:board/pages            ?tree=true &q= &parent= &archived=true|all &template= &status=
POST   /api/boards/:board/pages            {title, body, summary, parent, status, template, message}
GET    /api/pages/:id                      PATCH  /api/pages/:id   {title, body, summary, slug, status, base_hash, message}
DELETE /api/pages/:id      ?purge=true     POST   /api/pages/:id/restore
POST   /api/pages/:id/move                 {parent, position: N|top|bottom}
GET    /api/pages/:id/revisions            GET    /api/pages/:id/revisions/:rev   ?diff=previous|<rev id>
POST   /api/pages/:id/revert               {revision_id, message}
GET    /api/pages/:id/render               ?format=markdown|html|text  (references resolved)
GET    /api/pages/:id/recording            a meeting page's audio, with Range  (see Meeting transcripts)
GET    /api/pages/:id/sections             the heading paths a section may be addressed by
GET    /api/pages/:id/section/*path        PUT (replace)  POST (append — cannot conflict)
POST   /api/pages/:id/append               {body, message}
GET    /api/pages/:id/links                POST /api/pages/:id/links   {card | page, pinned}
GET    /api/boards/:board/pages/wanted     GET  /api/pages/resolve   ?board= &title=
GET    /api/cards/:id/pages               POST /api/cards/:id/pages   {title, template, values}
POST   /api/pages/:id/cards               {text, column}
POST   /api/boards/:board/pages/from-template  {template, title, card, values}
POST   /api/pages/:id/place    {column, before}    put it in a list, before a card or page-N
DELETE /api/pages/:id/place                          take it off the board
POST   /api/pages/:id/publish   {published: false to withdraw}   read-only at /w/:token
GET    /api/boards/:board/pages/export    POST /api/boards/:board/pages/import  {files, overwrite}
GET    /api/export   ?boards=del,ops &archived=cards|pages|boards|all   board trees as one document
POST   /api/import   <a document>                       build the trees in it, as new boards
                     (or a Trello board's JSON; ?from=trello to say so)
GET    /api/pages/query-vocabulary        the grammar a ```slipdock block is written in
POST   /api/pages/query    {board, body}  try a block without writing it anywhere
GET    /api/skills                         GET  /api/skills/:name    GET /api/skills/:name/*file

# Your one wiki (see Your wiki): its address names none
GET    /api/wiki                          {wiki: {url, pages, boards, mirrors, shortcut, hotkey,
                                          recordings_folder, knowledge_base}, boards: every board's
                                          folders and pages}
PATCH  /api/wiki                          {shortcut, hotkey, recordings_folder}  answers {wiki}
GET    /api/wiki/locate  ?path=           GET  /api/wiki/resolve  ?link=     GET /api/wiki/wanted
GET    /api/wiki/changes ?since=          the feed sync follows
GET    /api/wiki/sync                     the listing: entries, folders, folder_details,
                                          virtual_folders, boards (each with position)
GET    /api/wiki/sync/pages/:page         PUT /api/wiki/sync/pages[/:page] {path, content, base}
DELETE /api/wiki/sync/pages/:page         ?base=
GET    /api/wiki/sync/files/:file         POST /api/wiki/sync/files[/:file_id]  (multipart)
PATCH  /api/wiki/sync/files/:file_id      {path, base}   DELETE ?base= &purge=true
POST   /api/header-links                  {board | wiki: true, icon}
# /api/vaults and /api/vaults/:id/... answer the same, kept for older clients; will be removed.
```

A page's `:id` is its numeric id, its code (`W-31`), or `board-code/slug` with
the slash URL-encoded. Reads return the Markdown source in `body`, never HTML.
`base_hash` is the `content_hash` the edit was made against: send it and a
save that would land on someone else's comes back as a **409** with the page
as it now stands in `current`; omit it and the last write wins. `message` is
the edit's own note, kept in history beside the author, the client (`via`) and
the API token's name (`agent`). Drafts are invisible to anyone who could not
have written them — a reader gets a 404 rather than a 403, because the page's
existence is itself the thing being withheld.

Automation rules are the board owner's: listing or changing them needs
`:owner`, not just write access. `POST` takes either `spec` — the trigger,
conditions and actions written out, validated and stored exactly as given, no
model involved — or `text`, a sentence the server's model turns into a spec
(the web UI's path, and it needs an OpenRouter key). A program should send
`spec`; `GET /api/automations/vocabulary` is the whole grammar as data so it
can. Or send `preset` and `params` — one of the ready-made rules from
`GET /api/automations/presets`, filled in (`{"preset": "follow_list",
"params": {"column": "Doing", "notify": "email"}}`), again with no model; a
missing or unusable field is a 422 naming it. An unknown trigger, action or
condition comes back as a 422 naming it.
`…/run` runs a rule now, first forgetting what a timed rule has already acted
on, and answers `{"fired": n, "automation": {…}}`. Alerts are listed for
whoever the token belongs to, and dismissing one is per person — `DELETE
/api/alerts/:id` removes it from your list, not everyone's.

Card fields for create/update: `title description priority flags start_date due_date completed color`,
plus `column` (name or id), `tags` (replace), `add_tags` / `remove_tags`, `add_flags` / `remove_flags`,
and `assignee` (a user's email, or `me`; `""` or null unassigns). A card can
have several people on it: `assignees` (a list of emails) replaces the whole
set, the first becoming the lead; `assignee` replaces it with one person; and
`add_assignees` / `remove_assignees` change it without restating it.

Card JSON includes `blocked` (boolean), `blocked_by` and `blocks` (lists of
`{id, title, completed, archived}`), `sub_board` (`{id, name, completed,
total, columns: [{id, name, cards}]}` or null), `assignees` (a list of
`{id, email, name}`, lead first), `assignee` (the lead, or null) and `rollup` — null for a card without subcards, else
`{done, total, start, due, start_derived, due_derived, slip_days, blocked,
overdue, health, depth}` summarising every level beneath the card. Board JSON
includes `root_id` and `parent_card` (`{id, title, board_id}` or null).
Templates are addressed by id or name.

Swimlane config params accept tags and lists by name or id. On the grid
endpoint, `view` loads a saved view and the other params override it; the
response holds `rows`, `cols` (with labels and counts), `cells[row][col]`
(card lists) and the effective `config`. Views are addressed by id or name.

---

← [Data](data.md) · [Contents](../manual.md) · [CLI](cli.md) →
