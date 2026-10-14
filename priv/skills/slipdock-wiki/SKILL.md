---
name: slipdock-wiki
description: Read and write the Markdown wiki pages kept on the user's self-hosted Slipdock boards with the `slipdock page` commands. Use whenever the user mentions a wiki, a doc, a page, notes, a runbook, a spec, a decision record, a retro, "write it up", "where is that documented", or asks what a system does or why something was decided. Also use to find, link, pin or search documentation that lives alongside their cards.
---

# The slipdock wiki

Each board has a wiki: Markdown pages in a tree of their own, with the
board's permissions and the board's API. The board says *what we are doing*;
the wiki says *how it works*, *what we decided and why* and *what shape the
thing is*.

This file is the reference. **`slipdock-docs` is the companion**: what belongs
in a document and where, which is the part that is easy to get wrong. And the
server documents itself — run this once a session before writing anything:

```sh
slipdock guide            # includes a wiki section: endpoints and conventions
```

Everything below is also plain HTTP; `references/api.md` has the `curl` form
of each command for an agent with no CLI.

## Naming a page

A page answers to three names, and they are not interchangeable:

| Name | Example | Use it when |
|---|---|---|
| **code** | `W-31` | Writing it down anywhere durable. Stable across renames and re-slugs. |
| **slug** | `retry-policy` | It is what the URL reads as. Changes when the page is renamed. |
| **board/slug** | `qvm-v1-rem/retry-policy` | Naming a page on another board. |

Every `<page>` argument takes any of the three.

## Finding

```sh
slipdock wiki                              # every board's wiki at once, folders and all
slipdock folder ls <board>                 # one board's filing: folders, then pages
slipdock folder open <board> [<folder>]    # one level only, with counts: cheap on a big wiki
slipdock page switch <board> acme call     # fuzzy: title, alias or vault path, across the vault
slipdock page mv W-31 --board jobs --folder Acme --dry-run   # to another board of the vault; drop --dry-run to move
slipdock page tree <board>                 # the shape of the wiki, nesting by indent
slipdock page ls <board> --q retry         # substring of title or body
slipdock page ls <board> --all             # archived pages too (--archived for those alone)
slipdock page ls <board> --recent          # most recently edited first, the newest 100
slipdock search <words...> --kind pages    # by meaning, across every board you can see
slipdock page wanted <board>               # linked to, but nobody has written them yet
```

**`--q` and `search` are not the same thing.** `--q` matches the characters
you typed in one board's pages. `slipdock search` matches by *meaning* across
everything, and is the one to reach for when the user describes a thing
rather than names it. `--kind pages` keeps it to documents, `--kind cards` to
the work; without either you get both, ranked against each other, which is
usually what you want.

A page is chunked by heading, so a match names the section it came from and
reading that section is cheap. Drafts are not indexed.

## Reading

```sh
slipdock page read <page>           # the Markdown source — what you would edit
slipdock page render <page>         # the same with every reference resolved
slipdock page read <page> --json    # source plus the content_hash you need to edit safely
slipdock page sections <page>       # the heading paths you can address
```

**`read` and `render` differ and the difference matters.** `read` gives the
source, `[[links]]` and all — that is what you edit. `render` follows every
reference: page links become links, `#412` becomes what the card says *now*,
`[[!toc]]` and `[[!children]]` expand. Read a page to change it; render a
page to answer a question from it.

## Writing

Lead with the narrow writes. They are cheaper, they are safer, and they are
the difference between an agent that collaborates on a document and one that
quietly deletes a colleague's paragraph.

```sh
# Append to one section. Cannot conflict; needs no hash.
slipdock page section <page> Log --append "- 2026-09-29 rolled back at 14:05"

# Replace one section, heading and all.
slipdock page section <page> "Deploy/Rollback" --file rollback.md --message "why"

# Append to the whole page.
slipdock page append <page> --body - --message "findings from the investigation"

# A new page.
slipdock page new <board> Retry policy --body - --summary "How retries work" \
    --parent W-12 --message "first draft"

# The whole body at once — last resort, and only with --base-hash.
slipdock page edit <page> --body - --base-hash <hash> --message "why"

# Encrypted passages (Meld Encrypt's format): done here, never through the API
# by hand. Asks for the passphrase, or --passphrase-file F.
slipdock page encrypt <page> --section Keys --hint "the usual"
slipdock page decrypt <page> --section Keys        # print it; --in-place removes it
```

`--body -` reads the text from stdin, which is how to write a page of
Markdown without quoting it. `--file F` reads a file.

**`--base-hash` on every whole-body edit.** `slipdock page read <page> --json`
gives `content_hash`; pass it back and a save that would land on top of
someone else's is refused, with the current version printed. Leave it out and
the last write wins — recoverable from history, but still a paragraph gone.
Two agents and a person may all be writing the same runbook.

**`--message` every time.** It is the "why" in the page's history, beside who
wrote it and whether it came from the web app, the API or a shell. Nothing is
lost to a save — every save keeps a revision, and reverting is itself a save —
so history is only useful if the messages are.

## Filing: folders

Two axes, and confusing them is the commonest way a wiki turns into a maze.

- **`--parent`** says what a page is *part of*: the rollback half of the
  runbook, the appendix of the spec. Reading the parent should make you want
  to read the child.
- **A folder** says where a page is *kept*: "Design", "Contracts",
  "Meetings". A folder holds pages that have nothing to do with one another
  except that somebody files them together.

Both are optional and neither implies the other. A folder answers to its id,
its slug, its name, or a path of names.

```sh
slipdock folder new <board> "Design/Decisions"     # makes both levels
slipdock folder ls <board>                         # the filing, pages and all
slipdock page file <page> --folder "Design/Decisions"   # file a page that exists
slipdock page file <page> --no-folder              # take it out of its folder
slipdock page new <board> Why SQLite --folder "Design/Decisions" --body -
slipdock page ls <board> --folder decisions        # what is in one
slipdock page ls <board> --no-folder               # what is filed nowhere
slipdock folder mv <board> Decisions --name Choices --parent Design
slipdock folder mv kb Jobs --board jobs --dry-run    # to another board: subfolders, pages (codes kept), files
slipdock folder rm <board> Choices                 # the folder only
```

**One page, several folders.** A page lives in one home folder and can be
*also filed in* others — the same page, not a copy:
`slipdock page file <page> --also "Design/Decisions"` (`--not-in` to undo;
`--board B`, or a vault path like `/Jobs/Notes`, for another board in the
same vault). File it twice rather than writing it twice.

**File it, don't nest it.** The mistake folders exist to stop is a parent page
called "Design" that is about nothing and only holds other pages — a document
you have to read past. A folder is a place, and a place costs nothing.

**Front matter.** A page imported from a file keeps that file's front matter
exactly as written. `slipdock page props <page>` prints the YAML; edit it and
send it back with `--file F` (or `--clear`). Never paste front matter into the
body: it lives beside the body, and a `---` block in the body is just text.
Its `aliases` are other names `[[links]]` find the page by.

## Vaults: several wikis as one Obsidian-style vault

A **vault** is the user's own, and holds no pages: it maps vault paths onto
board wikis, or onto one folder of a wiki, so the wikis read as one tree of
Markdown files (`/` → KnowledgeBase, `/Jobs` → Job Hunt). The longest matching
prefix wins; a board can be in one vault only, and only a board the user can
write to. Deleting a vault removes its mappings and never a page. In the web
app a board's wiki shows the vault from where the board is mounted down
(KnowledgeBase at `/` shows Jobs among its folders; Job Hunt shows only
`/Jobs`), so to point someone at a note, the board it is on is enough.

```sh
slipdock vault ls                                  # the vaults, with their mappings
slipdock vault new Notes
slipdock vault map Notes / --board kb              # the vault's root
slipdock vault map Notes /Jobs --board jobs --folder Notes
slipdock vault inside Notes /                      # keep the board at / inside the vault (--off: let it out)
slipdock vault locate Notes /Jobs/Acme/Call.md     # which mapping, and the rest of the path
slipdock vault unmap Notes /Jobs
```

On a board in a vault, `[[Note]]` looks on its own board, then across the
whole vault; when two notes share a name the shortest vault path wins, and
`[[Folder/Note]]` picks one. `slipdock vault resolve <vault> <link>` says
which page a link finds before you write it; `slipdock vault wanted <vault>`
is the vault's backlog of unwritten pages.

`slipdock vault changes <vault> --since N` lists what changed in the vault after
cursor N (without `--since`, the cursor to start from) — the feed a sync polls.

`slipdock sync init <dir> --vault V` binds a local folder to a vault, and
`slipdock sync [<dir>]` (or `--watch`) keeps the two level both ways: a note is
`Title.md` (`Title/index.md` with children), renaming the file renames the page,
a delete archives it, and a note changed on both sides keeps the server's
version and saves the local one beside it as `Name (conflict DATE host).md`.
`slipdock sync status` lists what is waiting and the conflicts left. When the
user keeps notes in a synced folder, editing the file and letting sync carry it
is as good as `page edit` — but don't do both to one note at once.

`slipdock vault import <dir> --vault V --dry-run` reports what bringing an
existing Obsidian vault in would create or skip and which links, embeds and
plugin blocks won't resolve; without `--dry-run` it does it (one way, once,
never overwriting what the vault has). Run the dry run and show the user before
the real import: it creates a page for every note.

On a board in a vault, a note's front matter `tags` and inline `#tags` (and
nested `#area/sub`) are its own tags, apart from the board's card tags:
`slipdock page tags <board>` counts them, `slipdock page ls <board> --note-tag
area` lists the notes under one. `#412` is still a card.

**Meeting pages.** A recorded meeting is one note: the summary, a
`## Recording` section holding `[▶ Play recording and transcript](#recording)`,
and the whole WebVTT under `## Transcript` in a ```` ```vtt ```` fence (four
backticks if the transcript has a line starting with ```` ``` ````). Its front
matter says where the audio is: `recording: gdrive:<path from My Drive>`, plus
`recording_drive_id` and `recording_duration` when known, and
`type: meeting`. The audio stays on Google Drive. The web app plays it in step
with the transcript once the vault owner has connected Drive and set the
vault's recordings folder (`slipdock vault set V --recordings-folder PATH`;
`slipdock drive status` shows both). Don't upload the audio, and don't write
a separate `.vtt` file. To add `recording_drive_id` later, change only that
key. Old notes with `manuel2://play` links are left as they are.

**Deleting a folder never deletes writing.** Its subfolders move up to its
parent and its pages go back to the board's root.

A folder named by a path is made on the way past when it is new, so
`--folder "Design/Decisions"` is one call whether or not it exists. Making the
same path twice is making it once.

## Linking

```sh
slipdock page links <page>              # what it points at, what points at it, what it wanted
slipdock page pin <page> --card 412     # "this page is *the* spec for that card" (--off to unpin)
slipdock page resolve <board> "Retry policy"   # is there a page for this? what do I write?
```

Written inside a page body:

| Written | Means |
|---|---|
| `[[Retry policy]]` | a page on this board, by title then slug |
| `[[retry-policy\|how retries work]]` | the same, with link text |
| `[[QVM/Retry policy]]` | a page on another board |
| `[[W-31]]` or bare `W-31` | a page by its code |
| `[[#412]]` or bare `#412` | card 412, drawn live: title, list, state |
| `[[Retry policy#Backoff]]` · `[[Retry policy#^a1b2]]` | a heading of a page · a block (a paragraph ending ` ^a1b2`) |
| `[[#Backoff]]` | a heading on this same page (all digits is still a card) |
| `![[Retry policy]]` · `![[Retry policy#Backoff]]` | the page, or that section, drawn in place |
| `[[board:QVM]]` · `[[view:QVM/Blocked work]]` | a board · a saved view |
| `[[!toc]]` `[[!children]]` `[[!backlinks]]` | expanded when the page is read |
| `@name` | a mention of someone on the board |

A `[[link]]` inside backticks or a fenced block is not a link. A `[[link]]`
to a page nobody has written yet is not a mistake — it shows as an invitation
and turns up in `slipdock page wanted`, which is the wiki's own backlog.

## The board, both ways

```sh
slipdock page card 412                      # what has been written about a card
slipdock writeup 412 [--template T]         # start a page for a card, pinned to it
slipdock page pin W-31 --card 412           # or pin one that already exists (--off to unpin)
slipdock page make-card W-31 --body -       # a passage of a page becomes a card, linked both ways
slipdock page from <board> "Decision record" --title "Dropping the queue" --set owner=ops
```

A template's `{{…}}` are Slipdock's (`{{card.title}}`, `{{today}}`, `--set`
values) and Obsidian's (`{{title}}`, `{{date}}`, `{{time}}`,
`{{date:YYYY-MM-DD}}`), so templates brought over from a vault work as they are.

**Pin the page to the card it explains.** A page nobody can reach from the
work is a page nobody reads; pinning puts it at the top of that card's Docs.
It is a judgement rather than something the prose says, so it survives
whoever next edits the page.

A comment on a card can `[[link]]` a page, and shows up in that page's
backlinks. Writing on cards is writing.

**Templates** are ordinary pages marked `--template`: not read as content,
copied. Their bodies may use `{{card.title}}`, `{{board.name}}`, `{{today}}`
and anything passed with `--set key=value`.

## Live queries

A fenced ```` ```slipdock ```` block is answered when the page is read, with the
reader's own permissions. `references/queries.md` has the grammar; the two
commands that matter:

```sh
slipdock page query-help                 # the vocabulary, from the parser itself
slipdock page query <board> --body -     # what this block would answer, right now
```

**Query, don't list.** A hand-typed list of blocked cards is stale by
Tuesday. Write the question instead, and try it before you save it.

## History

```sh
slipdock page history <page>            # every save: when, who, how, and why
slipdock page diff <page> --rev N       # what one version changed
slipdock page diff <page> --rev N --against M   # how version N differs from M
slipdock page revert <page> --rev N     # put it back; itself a save, nothing is lost
```

## Putting a page on the board

```sh
slipdock page place <page> "In Progress"     # the doc sits in that list, beside the work
slipdock page place <page> Backlog --before 412   # before card #412 (or --before page-7)
slipdock page unplace <page>                 # off the board; it stays in the wiki
```

A placed page is drawn as a card and behaves as one. It shares one position
sequence with the cards, so it sits *between* them rather than after them
all, and it appears in every view — board, swimlanes, table, timeline,
calendar — grouped, filtered and sorted beside the work. In the web app a
click on its **document icon** opens the document; a click anywhere else
opens the card-style panel.

It can do that because a page carries the card's **facets**, under the same
names and with the same vocabularies:

```sh
slipdock page edit W-31 --priority high --flag review --due 2026-10-09
slipdock page edit W-31 --assignee sam@example.com --percent 40 --color amber
slipdock page edit W-31 --start 2026-10-01 --done      # --undone, --no-due, --no-color, …
slipdock page edit W-31 --flag review --off            # take a flag off
```

`--priority` takes the card vocabulary (`none|low|medium|high|critical`),
`--flag` a card flag (`blocked`, `review`, …, repeatable), `--percent` 0–100.
These are the attributes that say *where a thing stands* — what a board
groups, filters and sorts by.

Set them only when they mean something. A reference page with a priority and
a due date is noise; a spec somebody is writing this week is not.

## Comments, a checklist, status and the rest

A page holds nearly everything a card holds. These commands take a page code
as readily as a card number — same command, same output:

```sh
slipdock comment W-31 "the backoff needs a worked example"
slipdock check W-31 "worked example for backoff"   # slipdock tick <item-id> to tick it
slipdock status W-31 at_risk "stalled on the SRE review"
slipdock weblink W-31 https://example.com/rfc --label "the RFC"
slipdock attach W-31 diagram.png                   # prints ![diagram.png](/attachments/…) to put in the body
slipdock vote W-31 2                               # out of the board's one budget
slipdock set W-31 effort=3                         # the board's custom fields
slipdock page read W-31 --json                     # comments, checklist, urls, status, votes
```

**A comment on a page is writing too.** `[[Retry policy]]` in one turns up in
that page's backlinks, naming the page it was written on — so a remark left
on a doc is as findable as a sentence in its body.

What a page has **not** got is the work-shaped pair: blocking dependencies
(`blocked-by`, `blocks`) and typed card links (`link`), both of which are
card-to-card and carry scheduling meaning, and sub-cards. Use `[[wikilinks]]`
and `slipdock page pin` to say what a document is *about*, and child pages for
a subtree.

Prefer the body for anything that is really prose. A comment is for a remark
about the document; a checklist is for the work of writing it. What the
document *says* belongs in the document.

A board can turn these off for its whole wiki (`slipdock set-board <board>
--no-page-card-features`; `page_card_features` in `slipdock board <board> --json`).
The commands still work, but nobody reading the page sees what they write — on
such a wiki, put a remark in a card about the page, not a comment on it.

A board that is mostly its wiki can open on it: `slipdock set-board <board>
--default-view wiki` (`default_view` in the board's JSON). Link people to its
pages, not its lists.

In the web app this is also the foot of every list: a document icon beside
**Add** and a paperclip. The document icon opens the wiki editor with the list
already chosen, so the page is placed there when it is saved. All three are
shortcuts to putting one more thing in a list, and a board can turn any of
them off (`slipdock set-board <board> --no-add-document`).

This is a second, optional axis: the page keeps its place in the wiki tree
either way. Place the documents somebody is working *through* — a spec being
written, a retro waiting to be held. Reference material belongs in the wiki
and nowhere else; a board full of documents is a board you stop reading.

## Publishing, and getting it out

```sh
slipdock page publish <page>              # read-only at a public link; --off withdraws it
slipdock page export <board> --dir D      # the whole wiki as .md files, front matter and all
slipdock page import <board> --dir D      # and back in; --overwrite replaces rather than skips
```

**Publishing freezes the answers.** A published page's live queries show what
they said when you published, and its links become plain text — there is
nobody behind an anonymous request to have permissions. Publish again to
refresh. A draft cannot be published.

Export is the escape hatch: one file per page, in the directory its folder
names and nested as the page tree is, `[[links]]` left exactly as written in
the dialect Obsidian reads.

Import reads directories by one rule, which is exactly what export writes:
**a directory with an `index.md` is a page with children; a directory without
one is a folder.** So a wiki round-trips, and a folder of notes somebody wrote
by hand comes in as filing rather than as pages about nothing.

## Housekeeping

```sh
slipdock page file <page> --folder F    # where it is kept (see Filing, above)
slipdock page mv <page> --parent W-12   # what it is part of; --root, --position N|top|bottom
slipdock page rm <page>                 # archive, with everything under it
slipdock page restore <page>
slipdock page rm <page> --purge         # permanent; owner only; ask first
```

A page written with `--draft` is visible only to people who could edit the
board — the right home for a half-written answer. `--publish` takes the draft
mark off.

## Errors

- `409` / "this page changed since you read it" — read it again, merge, save
  with the new `--base-hash`. Never re-send blindly.
- `404` on a page you expected — it may be a draft, and you may not be a
  writer on that board. Drafts are hidden rather than refused, on purpose.
- `forbidden` — you can see the board but not change it.
