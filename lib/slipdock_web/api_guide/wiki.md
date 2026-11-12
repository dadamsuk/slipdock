
## The wiki: writing things down

The board answers *what are we doing*. It cannot answer *how does this
work*, *what did we decide and why*, or *what shape is the thing* — and
those are the answers that stop being rediscovered every month. Each board
has a wiki for them: Markdown pages in a tree of their own, with the
board's permissions and the board's API.

A page answers to three names, and they are not interchangeable:

- its **code** — `W-31` — stable across renames, and what belongs in a
  commit message or a link;
- its **slug** — taken from the title, and what the URL reads as;
- `board-code/slug`, for naming a page on another board.

All three work wherever `:id` appears below (URL-encode the slash in
`board-code/slug`, so `apiwiki%2Frunbook`).

```sh
curl -s -H "$H" B/api/boards/1/pages            # the board's pages
curl -s -H "$H" "B/api/boards/1/pages?tree=true"   # nested, as the sidebar shows them
curl -s -H "$H" "B/api/boards/1/pages?q=refund"    # by substring
curl -s -H "$H" "B/api/boards/1/pages?recent=true" # newest edit first, the newest 100
curl -s -H "$H" B/api/pages/W-31                # one page: Markdown source, not HTML

# write one
curl -s -H "$H" -H 'content-type: application/json' B/api/boards/1/pages \
     -d '{"title": "Retry policy", "body": "# Retry policy\n\nThree times, then stop.",
          "summary": "How retries work", "message": "first draft"}'

# change one, safely (see below)
curl -s -X PATCH -H "$H" -H 'content-type: application/json' B/api/pages/W-31 \
     -d '{"body": "…", "base_hash": "<the content_hash you read>", "message": "why"}'

curl -s -X POST -H "$H" -H 'content-type: application/json' \
     B/api/pages/W-31/move -d '{"parent": "W-30", "position": "top"}'
curl -s -X DELETE -H "$H" B/api/pages/W-31       # archive (?purge=true, owner only)
curl -s -X POST -H "$H" B/api/pages/W-31/restore
curl -s -H "$H" B/api/pages/W-31/revisions
curl -s -H "$H" "B/api/pages/W-31/revisions/12?diff=previous"
curl -s -H "$H" "B/api/pages/W-31/revisions/12?diff=7"   # from version 7 to 12
curl -s -X POST -H "$H" -H 'content-type: application/json' \
     B/api/pages/W-31/revert -d '{"revision_id": 12}'
```

**`base_hash` is the thing to get right.** Every page carries a
`content_hash`. Send back the one you read and a save that would land on
top of someone else's is refused — HTTP 409, with the page as it now
stands in `current`, to merge against. Omit it and the last write wins,
which is recoverable from history but is still someone's paragraph gone.
Two agents and a person may all be writing the same runbook; send the
hash.

**Every write is recorded.** A revision carries who wrote it, why
(`message` — write one every time), and how: `via` is the client and
`agent` is the name on the API token, so a page's history says which robot
changed which paragraph without anyone keeping a separate log. Nothing is
ever deleted by a save, and reverting is itself a save.

### Folders: where a page is kept

Two axes, and they answer different questions. `parent_id` says what a
page is **part of** — the rollback half of the runbook. A **folder** says
where it is **kept** — "Design", "Contracts", "Meetings" — and holds pages
that have nothing to do with one another except that somebody files them
together. Both are optional and neither implies the other.

A folder answers to its id, its slug, its name, or a path of names.
Deleting one never deletes writing *unless you say so*: by default its
subfolders move up to its parent and its pages go back to the board's
root. `?purge=true` is the other answer — the folders beneath it and every
page filed in any of them, deleted for good — and it is the board owner's
to give, as purging a page is.

```sh
curl -s -H "$H" B/api/boards/1/folders          # the filing, nested, pages and all
curl -s -H "$H" B/api/wiki                      # every board you can open, folders and all
curl -s -H "$H" "B/api/boards/1/tree?folder=Design"   # one level: rows and counts, no bodies
curl -s -H "$H" "B/api/boards/1/pages/switch?q=acme+call"   # the quick switcher: fuzzy title, alias, path; &vaults=all: your whole wiki
# to another board of your wiki, keeping its code; dry_run says what would stay behind
curl -s -X POST -H "$H" -H 'content-type: application/json' \
     B/api/pages/W-31/move -d '{"board": "projects", "folder": "Acme", "dry_run": true}'
curl -s -X PATCH -H "$H" -H 'content-type: application/json' \
     "B/api/boards/1/folders/Design" -d '{"sort": "name"}'   # manual, name, modified, created; board follows the board's (by name unless chosen)
curl -s -X PATCH -H "$H" -H 'content-type: application/json' \
     B/api/boards/1/tree -d '{"sort": "modified"}'           # the top of the tree, and the folders following it; write access
# a whole folder to another board you can write to: subfolders, pages (codes and history kept)
# and files; "parent" a folder there, "contents": true moves only what is in it, dry_run reports
curl -s -X PATCH -H "$H" -H 'content-type: application/json' \
     "B/api/boards/1/folders/Projects" -d '{"to_board": "projects", "dry_run": true}'

curl -s -X POST -H "$H" -H 'content-type: application/json' \
     B/api/boards/1/folders -d '{"name": "Design/Decisions"}'   # makes both

# file a page — the folder is made if it is new, so this is one call
curl -s -X POST -H "$H" -H 'content-type: application/json' \
     B/api/pages/W-31/folder -d '{"folder": "Design/Decisions"}'
curl -s -X POST -H "$H" -H 'content-type: application/json' \
     B/api/pages/W-31/folder -d '{}'            # take it out of its folder

# or write it straight into one
curl -s -H "$H" -H 'content-type: application/json' B/api/boards/1/pages \
     -d '{"title": "Why Postgres", "folder": "Design/Decisions"}'

curl -s -H "$H" "B/api/boards/1/pages?folder=decisions"   # and list what is in it
curl -s -H "$H" "B/api/boards/1/pages?folder=none"        # the pages filed nowhere

curl -s -X PATCH -H "$H" -H 'content-type: application/json' \
     "B/api/boards/1/folders/Design/Decisions" -d '{"name": "Choices", "parent": "root"}'
curl -s -X DELETE -H "$H" "B/api/boards/1/folders/Choices"   # the folder only
curl -s -X DELETE -H "$H" "B/api/boards/1/folders/Choices?purge=true"
# → {"deleted": {...}, "purged": {"pages": 4, "folders": 1}}
# Organise what is filed in a folder: mode date|ai|tag|flatten. date takes
# parent (a path; the folder itself when absent, "" for the top), granularity
# (month, year, year_month, day) and source (auto: created:/date: front matter
# first; added). ai: a cheap model suggests homes under existing top-level
# folders. dry_run returns the plan; "only": ["page:12"] files just those keys.
curl -s -X POST -H "$H" -H 'content-type: application/json' \
     B/api/boards/1/organise -d '{"folder": "Inbox", "mode": "date", "parent": "Meetings", "dry_run": true}'
# → {"dry_run": true, "plan": [{"key": "page:12", "title": "Standup", "from": "Inbox", "to": "Meetings/2026-10"}]}
# without dry_run → {"plan": [...], "moved": 1, "folders_made": 1, "skipped": []}
```

**One page, several folders.** `folder_id` is a page's **home**; it can be
**also filed in** other folders, as a symbolic link would be — one body,
one history. `POST /api/pages/W-31/folder {"also": "Ideas"}` adds one
(made if new), `{"not_in": "Ideas"}` takes it away, `board` names another
board's folder, and a wiki path (`"/Projects/Notes"`) reaches any board of
the wiki. A path uses the folders that are there and makes only
the levels that aren't, for a folder's `also` as well, if you write on both
boards. A page's JSON lists them as `also_in`; a folder's
listing (`?folder=`, `/folders`) includes them marked `"also": true`, each
page once. Archiving keeps them; deleting a folder drops its own.

**One folder, several places.** A folder can be also filed in other
folders too (#808), and shows there with everything in it; its `parent_id`
stays its home. `PATCH /api/folders/4 {"also": "Ideas"}` (or
`/api/boards/1/folders/<path>`) adds one, `{"not_in": "Ideas"}` takes it
away; the other folder is named by path, by id, on `in_board`, or by wiki
path. Same rules as pages: same board or wiki, write on both, never its
home parent, and never inside its own subtree (through placements too) —
each refusal is a 422 saying why. A folder's JSON lists them as `also_in`;
`GET /api/boards/1/folders/<path>` reads one; listing a folder adds the
pages under folders placed there, marked `"also": true`. Sync writes a
folder once, at home. MCP: `file_folder`.

**Sharing a page or a folder** (#813) hands it to somebody who need not
see the board: a person by email (a stranger is invited) or a group of
yours, `read`, `comment` or `write`. A folder share covers everything whose *home*
is in its subtree (pages, files, drawings, subfolders), never what is only
also filed there. Only the board's writers share.

```bash
curl -s -X POST -H "$H" -H 'content-type: application/json' \
     B/api/pages/W-31/grants -d '{"email": "sam@example.com", "level": "write"}'
# → 201 {"grant": {"id": 9, "level": "write", "user": {"email": "sam@example.com"}, "group": null}}
curl -s -H "$H" B/api/folders/4/grants            # who has it
curl -s -X DELETE -H "$H" "B/api/folders/4/grants?group=Ops"   # take it back
curl -s -H "$H" B/api/shared                      # what is shared with you, by owner
```

What is shared with you reads and edits by its code like any page
(`GET`/`PATCH /api/pages/W-31`); make things inside a shared folder with
`POST /api/folders/:id/pages` and `/api/folders/:id/folders`, and read one
with `GET /api/folders/:id`. **A sharee's limits:** with write they edit,
rename, make pages, files, drawings and subfolders inside the share, and
move things within it; new things are the owner's, on the owner's board
and quota. They never delete, archive or restore, move anything out (to
the top, another folder, another board), move the shared folder itself,
organise, re-share or publish, or encrypt; a page shared on its own is
edited and renamed, not moved. Each refusal is a **403 with a code**:
`shared_read_only`, `shared_no_delete`, `shared_no_move`,
`shared_no_move_out`, `shared_no_create`, `shared_no_reshare`,
`shared_no_encrypt`, `shared_no_organise` — stop, and tell the person; a
retry won't help. A sharee can also file a shared item in a folder of
their own (`also`); a wiki sync then gets **stubs** — one line, a link —
never the content. MCP: `share` (`off: true` to take it back; neither
`with` nor `group` to list), `list_pages {"shared": true}`.
CLI: `slipdock page share <page> <email|group> [--write] [--off]`,
`slipdock folder share <board> <folder> …`, `slipdock shared`.

**File it, don't nest it.** Making a parent page called "Design" that
exists only to hold other pages is the mistake folders are for: the page
is about nothing, and it has to be read to be got past. A folder is a
place, and a place costs nothing.

On a shell: `slipdock wiki`, `slipdock folder ls|show|new|mv|rm [--purge]`,
`slipdock folder file <board> <folder> --also F | --not-in F`, and
`slipdock page file <page> --folder F | --no-folder`.

In the app a folder is a place you can be: `/boards/1/wiki?folder=4` shows
one folder — what is filed in it, the folders beneath it, and the actions
that belong to it. Anywhere a folder is asked for, the tree is shown and
filters as you type, so "where does this go" never means reading a flat
list of forty paths. The sidebar's pencil turns the tree into a
drag-and-drop one: a page dropped in a folder is filed there, a page
dropped on a page becomes part of it, and a folder dropped in a folder
moves under it — the same three calls as `/folder`, `/move` and
`PATCH /folders/:id`, which is what you have.

The wiki's own search box matches names — a page's title and summary, a
folder's — and says so; the words *inside* the pages are the search above,
one click away at `/search?q=…&board=N` (which is a link worth handing
somebody when the name they tried is not what the page is called).

### The wiki: your Knowledge Base and every board, as one tree

Your wiki is one folder tree of Markdown (and other) files, made the first
time it is wanted and derived rather than configured. At the top is your
**Knowledge Base**, first always: a wiki and nothing else (underneath, a
board of kind `wiki`, on no list of boards and counted against no limit).
Then every root board you own is a folder at `/<board name>`, in the order
your home page keeps by hand, and a sub-board sits in its epic's folder,
`<Board>/Cards/<Epic>/`. Everything in a board's wiki is in its folder.
Boards shared with you by someone else are not in it. A new or renamed
board needs no call. Board names that clash, case aside, are numbered,
the oldest plain. A board with **nothing written** on it or below it (no
page or file) is left out of the web's tree; the listing and
`wiki.boards` still have it, with `"empty": true`, so a mirror keeps its
folders: leave it out of a tree you draw. Its first page brings it in.

An **archived board is out of the tree**: not in `boards`, the sync
listing or the feed, which says only that it was archived (a `board`
change, `"action": "archived"`: drop its folder) and, if it comes back,
restored (list again). Browse it from the archived boards
(`GET /api/boards?archived=true`) and its own wiki; restore it to have
its wiki in the tree again. Its pages still answer `[[links]]`.

```sh
curl -s -H "$H" B/api/wiki     # `wiki`: pages, boards, mirrors, knowledge_base; and every board's folders
curl -s -H "$H" "B/api/wiki/locate?path=/Projects/Acme/Call.md"
# → {"board": {"id": 7, "path": "/Projects", ...}, "rest": "Acme/Call.md"}
curl -s -X PATCH -H "$H" -H 'content-type: application/json' \
     B/api/wiki -d '{"shortcut": "w"}'
```

`wiki.boards` has each board's `id`, `code`, `name`, `path`, `archived`,
`empty`, `wiki_tree_icons` and `wiki_sort`; `knowledge_base` is `{id, code, name}`.
`PATCH` takes `shortcut`, `hotkey` and `recordings_folder`; a wiki has no
name. `locate` answers with the deepest board holding the path, a
sub-board being inside its parent's folder, and is a 404 at the root or
in no board. `mirrors` are the folders the wiki is synced to, as far as
the server knows: each API token that has listed it (`/sync`) or followed
its feed, by label, with `last_synced_at`. On a shell: `slipdock wiki
show|set|locate|resolve|wanted|changes|tree`; over MCP, `wiki_info` and
`manage_wiki`; in the web app, `/wiki`, where a page's address is its
path (`/wiki/Projects/Roadmap`): give the person that link rather than a
board's. `/api/vaults/...` answers as `/api/wiki/...` does, for older
clients; it will go.

**Links reach across the wiki.** A plain `[[Note]]` tries its own board,
then the whole wiki: each page has a path (board, folders, parent pages,
title), the last part of a link matches a title, slug or alias, any parts
before it the end of the path, and the shortest path wins a tie — so
`[[X/Note]]` picks one. `GET /api/wiki/resolve?link=X/Note` answers which
page and its path; `GET /api/wiki/wanted` lists what is linked to and
unwritten anywhere in it.

**The change feed.** `GET /api/wiki/changes` gives the cursor to
start from; `?since=<cursor>` then gives every page, folder, attachment
and wiki-file change on the wiki's boards after it — each once, as it is now (a page's
`code`, `title`, `icon`, `color`, `position`, `inserted_at`, `updated_at`,
`content_hash`, `folder_id`, `archived` and `path`), or `"action": "deleted"` — with the next `cursor` and
`more`. A new icon or colour is a change too, and leaves the hashes alone.
Every page, folder, file and board carries `title`, `short_name` (a card
folder's, else null), `path` (the listing's, from disk names, null for what
is archived itself) and `archived` (itself, or a card above
it); a card's folder has `card_id`. A rename of a card, a short name or a
board comes as `"action": "moved"` with the old path in `from_path` on
the folder and on everything that moved under it, with `"subject":
"board"` for a board's own folder: move what you hold, by id, and don't
delete anything. Moved more than once since your cursor, `from_path` is
the first path. It isn't in the file, so a moved file's hash is as it was,
unless the bytes changed too: a page also filed in a folder that moved
names it in `also-in`, and comes as `changed`.
Keep a websocket on `/socket/websocket?token=<token>&vsn=2.0.0`, join
the wiki's `channel` (from `GET /api/wiki`), and a `change` event with
the cursor says when to ask. The log keeps a window (90 days by
default): `"resync": true` means your cursor is older than that — list
the wiki again, then follow on.

**Sync: the wiki as a folder of files.** `slipdock sync init DIR`
binds a local folder and `slipdock sync` (or `--watch`, or `slipdock sync
service install`) keeps it level with the wiki both ways (`slipdock sync
from-server` or `to-server` for a pass one way only); the folder
stays a valid Obsidian vault. `slipdock sync status` says what is waiting
on each side and which conflict copies are left. An existing Obsidian
vault comes in once with `slipdock wiki import DIR` (try
`--dry-run` first: what would be created or skipped, and the links,
embeds and plugin blocks that won't resolve); notes go up byte for byte,
nothing already in the wiki is overwritten. Underneath is
`/api/wiki/sync`:

```sh
curl -s -H "$H" B/api/wiki/sync            # every file: kind, id, path, hash; folders; cursor
curl -s -H "$H" B/api/wiki/sync/pages/412  # one note's file: path, hash, content
curl -s -X PUT -H "$H" -H 'content-type: application/json' \
     B/api/wiki/sync/pages/412 -d '{"path": "Projects/Acme.md", "content": "…", "base": "<hash>"}'
curl -s -X PUT -H "$H" -H 'content-type: application/json' \
     B/api/wiki/sync/pages -d '{"path": "Ideas/New.md", "content": "…"}'
curl -s -X DELETE -H "$H" "B/api/wiki/sync/pages/412?base=<hash>"   # archives
curl -s -H "$H" B/api/wiki/sync/files/9 -o photo.png                # bytes
curl -s -H "$H" -F path=Img/photo.png -F file=@photo.png B/api/wiki/sync/files
```

Paths are paths of files: a page is `Title.md`, or `Title/index.md`
when it has children; a title a file name can't hold has its characters
substituted, and the true title is kept in front matter. A **hash** is the
sha256 of the exact bytes sync writes (front matter included, `also-in:
[Path]` for the other folders a page is filed in), so it moves exactly
when the file would. Every write sends the `base` hash it was made
against; a stale one is a 409 with the file as it now stands. Writing a
file at a new path renames or refiles the page; a directory that is no
folder yet becomes one. Files that are not notes (images, PDFs,
`.excalidraw`) are kept at their path as wiki files —
`POST /sync/files[/:id]` multipart, `PATCH /sync/files/:id {path, base}`
to move, `DELETE` to archive — and `![[photo.png]]` draws them.
`DELETE /sync/files/:id?purge=true` deletes one and its bytes for good and
gives the storage back: the board's owner only (403 otherwise), `base`
guards it as usual (409), and the feed says `deleted`. A
recorded meeting is a page like any other: see *Meeting pages* below.

The listing is enough to draw the wiki's tree. Each page has `icon` and
`color` (names, or null); each page and file has `writable` and
`shareable`, for you and this token: whether you can write to its board,
and whether you may share it, which a file never is. `folders` is the
directories as strings; `folder_details` maps the same paths to
`{id, board_id, icon, color, writable, shareable}`. With `?stubs=1`, a
stub carries none of these, and a directory only a stub needs isn't in
`folder_details`. `boards` lists the boards you can open, each `{id, name,
title, short_name, path, archived, position, empty}` (`empty`: nothing
written on it or below it; draw no row for it): `position` is the order
the top of the tree takes, the one your home page keeps by hand (boards
you placed by their place, the rest after them, oldest first), so sort
the top by it and you agree with the web. `folders` takes in the boards'
directories, and the `Cards` and epic directories a sub-board needs when
no folder stands for them; `virtual_folders` lists those last as `{path,
board_id, title, short_name, card_id, archived}`. Every page, file and
`folder_details` entry also has `title` (whole, however long), `short_name`
(a card folder's when it has one, else null; a page has none) and
`archived`: a card above it put it away (an archived board is not listed), and a path never says so. A
card's folder has its `card_id`. Show titles or short names as the person
chose: `tree_names` in `GET /api/me`, `full` or `short`, set with `PUT
/api/me/display {"tree_names": "short"}` or `slipdock names short`. In
`GET /api/wiki`, each of `wiki.boards`' `wiki_tree_icons` says whether that board's
tree shows icons and colours at all; turning that off isn't in the change
feed.

It is enough to sort that tree as the web app does, too. Each page and file
has `inserted_at` and `updated_at`, and a page a `position`; a file's is
null. `folder_details` adds `position`, `sort`, `inserted_at`, `updated_at`,
and `also_pages` and `also_folders`, the ids of what is also filed there.
`GET /api/wiki` adds each board's `wiki_sort`. Within a directory, the sort is the folder's
`sort`, or if that is null its board's `wiki_sort`, which is `name` until
someone chooses. A page's own directory (no `folder_details`, an `index.md` above
the rest) is always `manual`. Then draw, in this order:

1. **Folders at home there.** By `name`, ignoring case, when the sort is
   `name`; otherwise by `position`, then name, whatever the sort.
2. **Folders also filed there**, in the order of `also_folders`.
3. **Pages at home there.** `manual`: `position`, then title, then id.
   `name`: title ignoring case, then id. `modified`: `updated_at`, newest
   first, then id, highest first. `created`: the same on `inserted_at`.
4. **Pages also filed there**, in the order of `also_pages`. A page's
   `position` is its place at home only, and no sort reorders these.
   A stub isn't in `also_pages`.
5. **Files**, by name ignoring case, whatever the sort.

`PATCH /api/folders/:id {"sort"}` sets a folder's and
`PATCH /api/boards/:board/tree {"sort"}` the top of a board's, with write
access for both. A folder's change is in the feed; a board's isn't. A
drag names only the page moved in the feed, though its siblings' positions
change, so take the listing again after a change to redraw in order.

**Notes tag themselves.** In your wiki, a page's front
matter `tags` and its inline `#tags` (nested `#area/sub` too; not in code,
headings or links; an all-digit `#412` is still a card) are its
`note_tags`, lower-case and apart from the board's card `tags`.
`GET /api/boards/:board/pages?note_tag=area` lists the notes tagged
`area` or anything under it, and `GET /api/boards/:board/pages/tags`
counts them. On a board shared with you, `note_tags` is always empty.

**A page's board tags.** A page's `tags` are the board's own, the ones
its cards wear: `PATCH /api/pages/:id` takes `add_tags`, `remove_tags` and
`tags` (which replaces the set; `[]` clears it), by name, as a card does,
and so does `update_page` (`slipdock page edit W-31 --tag T`). They live
on the root board: `GET /api/boards/:board/tags` lists them, and one that
isn't there is a 422 naming it, with nothing changed. `note_tags` are the
note's own, edited in its text, and these keys never touch them.

### Meeting pages (recordings on Google Drive)

A recorded meeting is **one page**: the summary, a `## Recording`
section, and the whole WebVTT transcript in a ```vtt block under
`## Transcript`. The audio stays on the wiki owner's Google Drive and
is never stored here; the page names it in front matter:

````markdown
---
title: weekly-sync
date: 2026-09-16T12:08:42+01:00
type: meeting
recording: gdrive:Meeting Recordings/2026-09/2026-09-16 12.08.42 weekly-sync.m4a
recording_drive_id: 1AbCdEf…      # optional; add it once the upload lands
recording_duration: 3725.4        # optional, seconds
participants: [Me, Alice]
---

Summary…

Tags: #important (0:05) #action (12:40)

## Recording

[▶ Play recording and transcript](#recording)

## Transcript

```vtt
WEBVTT

1
00:00:01.500 --> 00:00:03.250
<v Alice>Shall we start?
```
````

`recording` is `gdrive:` plus the path from the root of My Drive. A
```vtt block always reads as the conversation (speakers, times); with
`recording:` the page also gets a player that streams the audio from
`GET /wiki-pages/:id/recording` and keeps the transcript in step
(clicking a line seeks to it). A `Tags:` line of `#tag (m:ss)` entries
(`h:mm:ss` from an hour) marks moments tagged while recording: each is
drawn inline in the transcript where it was pressed and becomes a link
to it in that line, and clicking either plays from that moment. If the transcript itself contains a line
starting with ```, fence the block with four backticks. Old notes with
`custom://play` links are left as they are. The whole contract, for
whatever records and transcribes the meeting (cue timings, speakers,
audio types, getting the page in, why it won't play), is in the manual:
docs/manual.md, *Meeting transcripts: what Slipdock expects*.

It plays when the wiki's owner has connected Google Drive (Account →
Settings; read-only) and set the wiki's recordings folder, and only for
files under that folder: `PATCH /api/wiki {"recordings_folder":
"Meeting Recordings"}` (checked against Drive; `""` clears it), or
`slipdock wiki set --recordings-folder PATH`. `GET /api/me/drive`
(`slipdock drive status`) says whether you are connected and your wiki's
folder. Write the page like any other note, with
`PUT /api/wiki/sync/pages {"path", "content"}`; add
`recording_drive_id` later with the `base` hash you got back, and on a
409 change only that key in the content you are sent back.

A client with a token plays it from `GET /api/pages/:id/recording`
(`:id` is an id, a code or `board-code/slug`, with the `/` as `%2F`):
the audio itself, for a media player or a proxy, never through a model,
so there is no MCP tool. `Range` is passed on, and the answer is 200 or
206 with `Content-Range`. It takes read on the board, as in the browser,
so a page shared alone answers 404; a read-only token may play, and one
limited to other boards gets a 403. A strict `Accept: audio/mp4` is a
406, so send `*/*` or leave it out. A refusal is JSON with a `reason`:
409 `not_connected` / `revoked` / `no_folder` / `no_vault`, 403
`outside_folder` / `not_audio`, 404 `not_found` / `no_recording`, 502
`unavailable`.

A quick note: `POST /api/notes {"text"}`, `slipdock note` or the MCP tool
`quick_note` saves text to the person's wiki; the server names it, picks
the folder (the top of their Knowledge Base when nothing fits better), and
answers with `code`, `title` and `location`.

The AI tools beside a page: `POST /api/pages/:id/ai {"tool"}`, `slipdock page
ai <page> <tool>` or the MCP tool `page_tool` run `summarise`, `key_points`,
`actions`, `titles` or `improve` over the saved page on the caller's AI key,
and write nothing. `answer.text` is Markdown, `answer.items` the lines of a
list; `POST /api/pages/:id/cards` makes a card of an action.

### Drawings (Excalidraw)

Obsidian's Excalidraw plugin keeps a drawing as a `.excalidraw.md` page
(front matter `excalidraw-plugin: parsed`, its text listed under
`## Text Elements`, the scene in a ```json or ```compressed-json block
under `## Drawing`) or as a `.excalidraw` wiki file of JSON. Both sync and
import as they are. In the web app `![[Plan.excalidraw]]` (or
`.excalidraw.md`) is drawn as a preview, served as SVG from
`/wiki-drawings/page/:id` or `/wiki-drawings/file/:id` to readers of the
board. People edit drawings in the Excalidraw editor at
`/drawings/page/:id` or `/drawings/file/:id`, which saves by itself (a
couple of seconds after they stop) in the format the drawing came in.
A drawing may be **live**: several people drawing in it at once, their
changes merged element by element the way Excalidraw's own collaboration
merges them (each element's `version`, then `versionNonce`; a deleted
element is kept with `isDeleted: true`). A write you make while it is
open — `PATCH /api/pages/:id`, `write_page`, a wiki sync, a `.excalidraw`
file replaced — lands as usual and is then merged into what they are
drawing: an element you changed wins only if you bumped its `version`
past theirs, an element you added stays, and an element you simply left
out is not deleted (set `isDeleted: true` and bump `version` to delete
one). Their next autosave holds both sides, and your write stays in the
page's history. Edit a drawing page's body through the API only if you
mean to rewrite the plugin's Markdown; the scene is lz-string
compressed, and a body that no longer holds one shows as Markdown —
though if the drawing is open, the next change anybody makes there
saves the drawing back over it. To
read a drawing, `GET /api/pages/:id/render` gives its words (prose above
the drawing, then each text element) rather than the scene, and search
finds a drawing page by those same words.

### Encrypted notes (Meld Encrypt)

A passage can be encrypted in Meld Encrypt's format, the Obsidian plugin's,
so Obsidian with Meld opens it too. The server only ever holds ciphertext:
an inline block `🔐β 💡hint💡<base64> 🔐` (or between `%%`, to hide it in
Obsidian's reading view), or a whole `.mdenc` note kept as a file. It is
never decrypted here, never indexed for search, and goes through sync and
import byte for byte. A page holding one says `encrypted` in the tree. The
format is written up on the wiki of the board that built it.

Don't decrypt or encrypt by hand through the API: you would be sending the
plaintext. Do it on your own machine with the CLI, which asks for the
passphrase (or reads `--passphrase-file`, or `$SLIPDOCK_MELD_PASSPHRASE`):

```sh
slipdock page encrypt W-31 --section Keys --hint "the usual"   # or the whole page
slipdock page decrypt W-31 --section Keys                       # print it, here only
slipdock page decrypt W-31 --in-place                           # remove the encryption
```

Text that was on the page before it was encrypted is still in the page's
earlier revisions. `page encrypt` counts them. With `--purge-history`, the
board's owner deletes them: the client matches the text against
`GET /api/pages/W-31/revisions?bodies=all` and sends only the ids, to
`POST /api/pages/W-31/revisions/purge {"ids": [..]}`. It never touches the
newest revision, and it is logged. This is the one write that removes
history, so it is owner-only.

### Writing one section at a time

A page is addressed by heading: `Deploy/Rollback` is the `## Rollback`
under the `# Deploy`. This is the write to prefer, and by some distance.

```sh
curl -s -H "$H" B/api/pages/W-31/sections              # the paths you may name
curl -s -H "$H" B/api/pages/W-31/section/Deploy/Log    # read one
curl -s -X POST -H "$H" -H 'content-type: application/json' \
     B/api/pages/W-31/section/Log -d '{"body": "- 2026-09-29 rolled back at 14:05"}'
curl -s -X PUT -H "$H" -H 'content-type: application/json' \
     B/api/pages/W-31/section/Deploy/Rollback -d '{"body": "## Rollback\n\nNew words."}'
curl -s -X POST -H "$H" -H 'content-type: application/json' \
     B/api/pages/W-31/append -d '{"body": "## Findings\n\n…"}'
```

A replace whose body has no heading of the section's level keeps the old
heading; one that has it renames the section. Rows appended to a section
ending in a table extend the table. The answer's `note` says which
(`heading kept`, `heading replaced`, `table extended`, `list extended`,
`appended`).

Two writers touching different sections never collide, and an **append
cannot clobber anything at all** — so it takes no `base_hash` and never
refuses. An agent keeping a running record should append to `## Log` and
send nothing else; it costs one small request instead of the whole
document, and it is the difference between collaborating on a page and
overwriting it.

### Writing links

Inside a body:

```
[[Retry policy]]                  a page on this board (title, then slug)
[[retry-policy|how it works]]     the same, with the text to show
[[QVM/Retry policy]]              a page on another board
[[W-31]]  or bare  W-31           a page by its code
[[#412]]  or bare  #412           card 412 — drawn live, never stale
[[Retry policy#Backoff]]          a heading of a page; #^a1b2 a block (` ^a1b2` ends it)
[[#Backoff]]                      a heading on this same page (digits stay a card)
![[Retry policy]]  ![[…#Backoff]] the page, or that section, drawn in place
[[board:QVM]]  [[view:QVM/Blocked work]]
[[!toc]]  [[!children]]  [[!backlinks]]
@name                             someone on the board
```

A reference inside a code span or a fenced block is not a reference. A
card chip is resolved when the page is *read*, so writing `#412` rather
than "the card about retries" is what keeps a document true after the
card is renamed.

**Link to pages that do not exist yet.** `[[Rollback procedure]]` written
before anyone writes it is not a broken link: it renders as an invitation
and turns up in `GET /api/boards/:board/pages/wanted`, which is the
wiki's own backlog and a good queue to work from.

```sh
curl -s -H "$H" B/api/pages/W-31/links                 # out, in, and wanted
curl -s -X POST -H "$H" -H 'content-type: application/json' \
     B/api/pages/W-31/links -d '{"card": 412}'         # this page is *the* spec for that card
curl -s -H "$H" B/api/boards/1/pages/wanted
curl -s -H "$H" "B/api/pages/resolve?board=1&title=Retry+policy"
```

`GET /api/pages/:id/render` is the other half of this: it returns the page
with every reference followed, so an agent answering a question reads the
answers rather than the syntax. Read a page to change it; render a page
to learn from it.

### Finding what has been written

Pages are in the same semantic index as cards, and ranked against them:
"what did we decide about refunds" should find the decision record *and*
the card that argued about it, in one list.

```sh
curl -s -H "$H" "B/api/search?q=how+do+retries+work"              # both
curl -s -H "$H" "B/api/search?q=how+do+retries+work&kind=pages"   # documents only
curl -s -H "$H" "B/api/search?q=...&kind=cards"                   # the work only
```

Each result carries `kind` (`"card"` or `"page"`), a `subject` with its
title and URL, and the chunks that matched. A page's matches name the
`section` they came from, so a result can be followed to the heading
rather than the top of a long document.

**Search before you write.** `kind=pages` is the difference between
extending the page that exists and leaving a fourth page about deployment
behind you. A page is chunked by heading, so a match is a section and
reading it is cheap.

Drafts are not indexed at all, and a page the reader cannot open never
comes back — checked against the reader on the way out, not merely at
index time.

### Live queries

A fenced ```` ```slipdock ```` block in a page is a question, answered when
the page is **read** — with the reader's own permissions, never the
author's. A hand-typed list of blocked cards is wrong by Tuesday; this
never is.

````
```slipdock
view: table
board: this
filter: flag=blocked, due < +7d, priority in high|critical
group: assignee
sort: due_date asc
fields: title, assignee, due_date, status
limit: 20
empty: "Nothing blocked and due this week."
```
````

```sh
curl -s -H "$H" B/api/pages/query-vocabulary    # views, settings, operators, fields
curl -s -X POST -H "$H" -H 'content-type: application/json' \
     B/api/pages/query -d '{"board": 1, "body": "view: count\nfilter: flag=blocked"}'
```

**Read the vocabulary and try the block before writing it into a page.**
It comes from the parser, so it cannot be out of date, and a block that
cannot be answered is a red note on somebody's document.

`board:` is `this` (the page's own), `tree` (it and everything beneath
it), or another board's code — cross-board is allowed and filtered by
access. `saved_view: "Blocked work"` embeds a view you already made
rather than spelling its filters out again; the web app will write the
whole block for you from any board view.

In a sentence, `{{count: flag=blocked}}`, `{{progress:412}}`,
`{{card:412.due_date}}`, `{{board.name}}` and `{{today}}` answer inline.
An expression this does not understand is left exactly as written, which
is what keeps a template page readable before it is used.

### A page on the board

A page can sit in one of its board's lists and be dragged about like a
card — the spec in "In Progress" beside the work it describes.

```sh
curl -s -X POST -H "$H" -H 'content-type: application/json' \
     B/api/pages/W-31/place -d '{"column": "In Progress"}'
curl -s -X POST -H "$H" -H 'content-type: application/json' \
     B/api/pages/W-31/place -d '{"column": "Backlog", "before": 412}'
curl -s -X DELETE -H "$H" B/api/pages/W-31/place
```

A page carries the **card's facets** — `priority`, `flags`, `tags`,
`assignee`, `start_date`, `due_date`, `date_precision`, `completed`,
`percent_complete`, `color` — under the same names and with the same
vocabularies as a card's, settable on create or update like any other
field. `add_flags` / `remove_flags` work as they do on a card, and
`assignee` takes an email.

```sh
curl -s -X PATCH -H "$H" -H 'content-type: application/json' B/api/pages/W-31      -d '{"priority": "high", "add_flags": ["review"], "due_date": "2026-10-09",
          "assignee": "sam@example.com", "percent_complete": 40, "color": "amber"}'
```

That is what lets a placed page stand beside the cards in *every* view —
board, swimlanes, table, timeline, calendar — and be grouped, filtered
and sorted with them. A view's `kinds` filter is what separates them again
when you want one sort of thing: `kinds=card`, `kinds=document`,
`kinds=page`, or a comma-separated mix.

```sh
curl -s -H "$H" "B/api/boards/1/swimlanes?kinds=page&rows=none&cols=column"
```

### A page's comments, checklist, status and the rest

A page holds most of the card's **contents** too, in the same tables and
through endpoints that mirror the card's one for one. `GET /api/pages/:id`
returns them alongside the body: `comments`, `checklist`, `urls`,
`status_updates`, `stated_health`, `votes` and `fields`.

```sh
curl -s -X POST -H "$H" -H 'content-type: application/json' \
     B/api/pages/W-31/comments -d '{"body": "Needs a worked example."}'
curl -s -X POST -H "$H" -H 'content-type: application/json' \
     B/api/pages/W-31/checklist -d '{"text": "worked example for backoff"}'
curl -s -X POST -H "$H" -H 'content-type: application/json' \
     B/api/pages/W-31/status -d '{"health": "at_risk", "body": "stalled on review"}'
curl -s -X POST -H "$H" -H 'content-type: application/json' \
     B/api/pages/W-31/urls -d '{"url": "example.com/rfc", "title": "the RFC"}'
curl -s -X DELETE -H "$H" B/api/pages/W-31/urls/7
# An image for the page: put the `markdown` that comes back in the body.
curl -s -H "$H" -F file=@diagram.png B/api/pages/W-31/attachments
curl -s -H "$H" B/api/pages/W-31/attachments
curl -s -X DELETE -H "$H" B/api/pages/W-31/attachments/5
curl -s -X POST -H "$H" -H 'content-type: application/json' \
     B/api/pages/W-31/vote -d '{"count": 2}'
curl -s -X PATCH -H "$H" -H 'content-type: application/json' B/api/pages/W-31 \
     -d '{"fields": {"effort": 3}}'
```

A board can turn the lot off for its whole wiki: `PATCH /api/boards/:board
{"page_card_features": false}` (`slipdock set-board B
--no-page-card-features`), and a board's JSON carries
`page_card_features`. The web app then leaves status, checklist, links,
fields, votes and comments off every page of that wiki; tags stay on. Nothing is
deleted and the endpoints above still answer, so read the flag before
commenting on such a page: the people reading it will not see the comment.

**Default view.** A board's JSON carries `default_view`: what opening it
in the web app lands on — `board`, `swimlanes`, `table`, `timeline`,
`calendar`, `outline`, `narrative`, `prioritise` or `wiki` — from the
board list, the switcher and favourites (a favourite board's `url` points
there). Set it with `PATCH /api/boards/:board {"default_view": "wiki"}`
(`slipdock set-board B --default-view wiki`); `"board"` or `""` clears it,
anything else is a 422. A board whose default is `wiki` is mostly read as
its wiki, so link people to its pages rather than its lists.

Checklist items and comments are removed through the routes they share
with cards — `POST /api/checklist/:id/toggle`, `POST /api/checklist/:id/move`,
`DELETE /api/checklist/:id`,
`DELETE /api/comments/:id` — which authorise against whichever the row
hangs off. Votes come out of the board tree's one budget, so a page
competes with the cards for it.

**A comment on a page is writing too.** `[[Retry policy]]` in one turns
up in that page's backlinks, naming the page it was written on, exactly
as a comment on a card names the card. In `GET /api/pages/:id/links`,
an `incoming` link written on a card carries `card` where a page's
carries `page`.

What a page does **not** take is the work-shaped pair: blocking
dependencies and typed card links, both card-to-card joins carrying
scheduling meaning, and sub-cards. A page has `[[wikilinks]]`, backlinks
and pins for saying what it is *about*, and child pages for a subtree.
Asking a page for the rest gives an empty list rather than an error.

`before` counts cards as well as pages — a card's number, or `page-7` —
because the two share one position sequence and a document that had to
sit after every card would not really be on the board. A board's JSON
carries each list's `pages` alongside its `cards`, both with the position
that orders them together.

The web app offers this at the foot of every list — a document icon
beside **Add** and a paperclip (a file, landing as a card of its own with
the file attached). All three are shortcuts to putting one more item in a
list, and each can be turned off per board:

```sh
curl -s -X PATCH -H "$H" -H 'content-type: application/json' B/api/boards/1 \
     -d '{"add_document": false}'
```

A board's JSON carries `add: {card, page, document}`, so a client that
draws a list draws the same three.

Placement is a **second, optional axis**: the page keeps its place in the
wiki tree either way, and taking it off the board changes nothing about
the page. Most pages are never placed. The ones worth placing are the
documents somebody is working *through* — a spec being written, a retro
waiting to be held — not the reference material.

### The board and the wiki, both ways

The point of a wiki inside a work tracker is that neither side has to
remember the other exists.

```sh
curl -s -H "$H" B/api/cards/412/pages          # what has been written about this card
curl -s -X POST -H "$H" -H 'content-type: application/json' \
     B/api/cards/412/pages -d '{}'             # "write it up": a page for it, pinned
curl -s -X POST -H "$H" -H 'content-type: application/json' \
     B/api/cards/412/pages -d '{"template": "Spec template"}'
curl -s -X POST -H "$H" -H 'content-type: application/json' \
     B/api/pages/W-31/cards -d '{"text": "Retries are wrong\nThey never stop."}'
curl -s -X POST -H "$H" -H 'content-type: application/json' \
     B/api/boards/1/pages/from-template \
     -d '{"template": "Decision record", "title": "Dropping the queue", "values": {"owner": "ops"}}'
```

**Pin the page to the card it explains.** A page nobody can find from the
work is a page nobody reads, and pinning is what puts it at the top of the
card's Docs. It is a person's judgement rather than something the prose
says, so it survives whoever next edits the page.

**A comment can link a page too** — "blocked on [[Retry policy]]" on a
card shows up in that page's backlinks. Writing on cards is writing.

**Templates** are ordinary pages with `"template": true`, not read as
content but copied. Bodies may use the same `{{…}}` placeholders an
automation action does — `{{card.title}}`, `{{board.name}}`, `{{today}}` —
plus anything passed in `values`, and Obsidian's `{{title}}`, `{{date}}`,
`{{time}}`, `{{date:YYYY-MM-DD}}` and `{{time:HH:mm}}` (Moment formats,
UTC), so an Obsidian template works unchanged.

**Conventions worth keeping to**, because they are what make a wiki
readable a year later rather than a pile of near-duplicates:

- **Search before you write.** A fourth page about deployment is the most
  common mistake here. Extend the page that exists unless the subject is
  genuinely new.
- **A page or a comment?** Durable and re-read → a page. About one card
  and about *now* → a comment or a status update on the card. Not both.
- **One `## Log` section** for dated notes, appended to, newest last.
- **Write the `message`** on every edit: history is the audit trail.
- **Don't rewrite a section you did not author** without saying so in the
  message.
- **A page per durable thing**, not per conversation.
- **Query, don't list.** A hand-typed list of blocked cards is stale by
  Tuesday; a `slipdock` block never is.

Drafts (`"status": "draft"`) are visible only to people who could edit the
board, so a half-written page is not a half-answer to someone else's
question. A page can also be shared on its own, without its board.

On a shell, the same thing is `slipdock page ls|tree|read|render|new|edit|
section|append|file|mv|rm|restore|links|pin|wanted|history|diff|revert` —
`slipdock page read` prints the Markdown, and `--body -` takes the body on
stdin.

### Out, and on the open web

```sh
curl -s -H "$H" B/api/boards/1/pages/export          # every page as {path, body}
curl -s -X POST -H "$H" -H 'content-type: application/json' \
     B/api/boards/1/pages/import -d '{"files": [{"path": "Charter.md", "body": "…"}]}'
curl -s -X POST -H "$H" -H 'content-type: application/json' \
     B/api/pages/W-31/publish -d '{}'                # read-only at /w/:token
curl -s -X POST -H "$H" -H 'content-type: application/json' \
     B/api/pages/W-31/publish -d '{"published": false}'
```

Export is one Markdown file per page, front matter and all, in the
directory its wiki folder names and nested as the page tree is — a
directory plus an `index.md` for a page with children. Import reads a
directory by the same one rule: **with an `index.md` it is a page with
children; without one it is a folder.** So a wiki moves between boards by
handing one answer to the other, and a folder of hand-written notes comes
in as filing rather than as pages about nothing. A title already on the
board is skipped and reported rather than duplicated.
`/boards/:id/wiki.zip` is the same thing zipped.

**Front matter is kept exactly.** A page imported from a file keeps that
file's front matter as written — key order, quoting, comments — and a
page's JSON carries it as `front_matter`, the YAML between the `---`
lines (null when there is none). Send `front_matter` on create or
`PATCH /api/pages/:id` to replace it (`""` clears it; a line of `---` or
`...` is refused). Export patches only Slipdock's own keys into it.
Its `aliases` (a list, or Obsidian's older `alias`) become the page's
`aliases`: `[[Alias]]` and `/api/pages/resolve?title=Alias` find the page
as its title would, a real title winning over an alias.

**Publishing freezes the answers.** A published page's live queries show
what they said when it was published, and its references are plain text:
there is nobody behind an anonymous request to have permissions, so a
live query there would be a way to read private cards from the open web.
The images it embeds (`![[photo.png]]`) are the exception: they are
shown, served through the page's link while it is published. Publishing
again refreshes them. A draft cannot be published.

An automation can write a page too — the `create_page` action starts one
for the triggering card, pinned to it — and `has_doc` is a condition, so
"when a card lands in Ready and nothing has been written about it, alert
me" is a rule rather than a habit.

## Skills

This server ships the instructions for using it, versioned with the code
they describe, so a copy in somebody's agent directory can be checked
against the API that actually answers:

```sh
curl -s B/api/skills                      # name, description, version, files
curl -s B/api/skills/slipdock-wiki          # one of them
curl -s B/api/skills/slipdock-wiki/references/markup.md

slipdock skills install                     # writes them to ~/.claude/skills
slipdock skills check                       # says whether a local copy is behind
slipdock skills chatgpt                     # zips for ChatGPT, one per skill
```

ChatGPT can't run the CLI, so every skill but `slipdock-loop` also comes
as a zip for its skill upload, `B/api/skills/<name>/chatgpt.zip`, with
each `slipdock` command mapped onto the tool of this server's MCP
connector that does the same. The listing's `chatgpt_zip` says which.

They need no token, because they say how to call this API and nothing
about what is on it. Board codes, list names and tag vocabularies stay out
of them deliberately and come from this guide instead — a skill that
hardcodes them rots, and one that sends you here does not.
