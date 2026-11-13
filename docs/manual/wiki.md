[Slipdock — the manual](../manual.md)

## Wiki

The board answers *what are we doing*. It cannot answer *how does this work*,
*what did we decide and why*, or *what shape is the thing* — and those are the
answers that otherwise get rediscovered every few months. Each board has a
wiki for them at `/boards/:id/wiki`, reachable from the view menu: Markdown
pages in a tree of their own, with the board's permissions, the board's API
and no second system to keep in step.

**Writing.** A page's body, a card's description and the comment box are
written in a Markdown editor with a live preview, the way Obsidian's is: a
line shows formatted — headings, **bold**, links, lists, task boxes, tables,
images — until the cursor is on it, and then shows its Markdown to edit.
Enter carries a list or a quote on to the next line, Tab indents a list item
(Escape, then Tab, leaves the editor), Ctrl-F finds in the text, and pasting
or dropping an image attaches it as before (one that can't be taken — over
50 MB, or not a PNG, JPEG, GIF or WebP — is refused with the reason, and the
rest of the text saves as usual). In a card's description, Escape
finishes editing. What is saved is the Markdown, exactly as typed.

**Auto-save.** The page editor keeps your work as you type, every few seconds,
and says *Auto-saved* beside the buttons. That copy is yours alone: it is not
a revision, nobody else sees it, and search and sync know nothing of it until
you press **Save**. Come back to a page you left mid-edit and it opens as you
left it, with **Discard it** to start again from the page; if someone has
saved the page since, Save shows you their version to merge, as it always
does. New pages you never saved are listed under **Unsaved work** on the
wiki's front page and on the New page screen. **Cancel** throws the work away,
and anything left untouched goes after 30 days.

An image can go into a new page straight away, before it has a title or a
save. It is held in a temporary auto-save folder, and shown only to you, until
Save makes it an ordinary attachment of the page; one you delete from the text
first is not kept. Held images don't count towards the board's storage until
then, and each person can hold up to 500 MB of them.

The editor for a page shared with you keeps your work the same way, and takes
pasted images. You may not be able to open its board, so what you left
unsaved is listed under **Unsaved work** on **Shared with me**, for as long as
the page stays shared with you to edit. If someone has saved the page since,
Save shows you their version to merge.

A page has three names, and they do different jobs. Its **code** — `W-31` —
is short, globally unique and stable across renames, so it is what belongs in
a commit message or a link. Its **slug** comes off the title and is what the
URL reads as. `board-code/slug` names a page on another board. All three are
accepted anywhere a page is asked for.

**Folders.** A page sits on two axes, and keeping them apart is what stops a
wiki turning into a maze. Its **parent page** says what it is *part of* — the
rollback half of the runbook, the appendix of the spec — and reading the parent
should make you want to read the child. A **folder** says where it is *kept*:
"Design", "Contracts", "Meetings", holding documents that have nothing to do
with one another except that somebody files them together. Conflating the two
forces anyone who just wants somewhere to put things to invent a parent page
that is about nothing, and then read past it forever.

So folders are their own thing: a tree of names on the board, nested to any
depth, made and renamed and moved from the wiki's own sidebar, with the pages
filed in each drawn inside them. Both axes are optional and neither implies
the other — a child page can be filed in a different folder from its parent,
and most pages are in no folder at all, which is the root rather than a limbo.

**A folder is a place you can be.** Clicking one in the sidebar opens it at
`?folder=`: what is filed in it, the folders beneath it, and the things you do
to a folder — write a page here, make one inside, rename or move it, delete it
— gathered in one place rather than only on a hover menu.

**A page's actions come first.** Above its folder and title, one row holds
everything you do with the page: the heart (a favourite), its code (the `#`
button: point at it to see `W-31`, click it to copy the code), **AI tools**,
**Edit**, **History**, the `⋯` menu and **Page details**. Edit is the one
tinted button; on a drawing that is **Edit drawing**. Page
details opens just beneath that row, above the folder: when the page was
created and updated, who it is shared with, the folder it is filed in, the
list it sits in on the board, its public link, tags and front matter. It
starts closed on every page, and stays open while you file or place the page.

**Icons and colours.** A folder or a page can wear an icon and a colour, so
the things you reach for most stand out. A folder's **Edit folder…** (on its
own page or its tree menu) and a page's editor both offer the icon set and the
palette, each with a *None*. They show on the wiki's main page — the folder
cards, a folder's listing, Recently changed and a page's heading — and in the
tree too, unless a writer turns **Icons and colours** off under the tree's
*Show in the tree* menu; that choice is the board's, for everyone reading it.
A page's colour is the same colour it carries on the board. From the command
line: `slipdock folder new <board> <name> --icon star --color amber`,
`slipdock folder mv <board> <folder> --icon book-open` (or `--no-icon`,
`--no-color`) and `slipdock page edit <page> --icon flag --color rose`.

**Opening and shutting the tree.** A folder's chevron opens or shuts it, and
so does a page's when it has pages under it. The double chevron at the top of
the sidebar shuts every folder at once, and opens them all again once they
are all shut. An empty folder has no chevron, there being nothing in it to
show. Which folders you had open is kept for you on the server, per board and for
your wiki, so the tree opens the same way next time, on any machine, and
following a link to another page doesn't spring it open or shut. The
crosshair at the top of the tree shows where you are again after you have
shut or scrolled it away. On a
first visit a small wiki (300 pages or fewer) opens with every folder open,
and a bigger one opens only the folders on the way to where you are. The
folders leading to the page or folder you are on always open, and the tree
scrolls to it, so what you just went to is never hidden.

**The keyboard.** Click a row and the tree takes the keyboard: the arrows walk
it, right opens a folder and steps into it, left shuts it or goes up to the
folder it is in, Enter opens the row, F2 renames it, Delete archives a page or
deletes a folder (both ask first), Space shows the highlighted page's
preview (and Space again puts it away), and typing a few letters jumps to the
next row that starts with them. The page-wide shortcuts stand down while it
has the keyboard.

**A page's preview.** Rest the mouse on a page in the tree for a moment and a
card beside the tree shows what is in it without opening it: its summary, the
start of its text (headings kept, code and embedded files left out, encrypted
text a 🔒), its tags, how many pages are under it, which board it is on when
that is another board, and who changed it last and when. Moving
off the page puts it away. A touch screen has no hover, so there a tap opens
the page as before.

**Wider, narrower, or out of the way.** On a wide screen the « at the left of
the wiki's bar folds the tree away, and » brings it back. Drag the tree's right
edge to make it wider or narrower (180–640px, 320px to start with, so a
name of about 28 characters shows whole a folder down); the edge can be focused with Tab
and moved with the arrow keys, Home and End, and a double-click or Enter puts
the width back. Both are remembered in this browser, not on the board. A name
too long for the width ends in …, and pointing at the row shows it whole.

**A column, or the full width.** A page is read in a column of comfortable
width, about 68 characters, and everything in it keeps to that one measure: the
text, the headings and their rules, tables and the cards at the foot. A table
with more columns than fit scrolls sideways inside the column. The arrows button beside the « widens it to fill the whole space beside
the tree, and pressed again puts the column back. The choice holds on every
page and is remembered in this browser. Editing always uses the full width.

**Recent.** The *Tree · Recent* switch, the folder and clock icons beside
*All pages* at the top of the tree, turns it into a flat list of the board's pages, the most recently edited first (up to 100),
each with the time it was edited (the day, if not today). The filter bar
narrows it as it narrows the tree, and it keeps itself up to date as pages
change. The choice is remembered in this browser. The same list from a
shell is `slipdock page ls <board> --recent`; `?recent=true` on the API, or
`recent` on MCP's `list_pages`.

**On a phone** the tree is a drawer: **Pages** in the wiki's bar slides it in
over the page, opened to where you are, and a tap outside it, Esc, or opening
a page shuts it again. Its rows are taller for a finger, holding one opens its
menu, and the `⋯` on each row is always shown.

**Big wikis.** The tree is built for thousands of notes. It loads one folder at
a time, when you open it, and never a page's text. Only the rows on screen
are drawn, so a folder of 5,000 notes scrolls like one of fifty. A big
folder's rows arrive 500 at a time as you scroll down to them, and the page
you are reading is always loaded, however far down its folder it is.

**Jumping to a note.** `Ctrl-O` (`Cmd-O`) on a wiki opens the note switcher:
a few letters of a note's title, an alias or its path, matched in order
the way editors' switchers match, across your whole wiki (see *Keyboard*).

**The whole wiki.** **Wiki** opens your whole wiki at `/wiki`: its tree down
the side, your Knowledge Base and then every board a folder at the top of it,
and pages addressed by their paths, the same as the files on disk —
`/wiki/Projects/Roadmap`, with `.md` or without, case aside.
A page opens inside the view, under the wiki's breadcrumbs, with a quiet
*on Handbook* saying which board holds it (the top of the wiki names none): its permissions, history and
comments are that board's, and editing, history and new pages behave as on a
board's wiki (a new note made in a folder lands on that folder's board).
Folder **Move…** and dragging across boards work in its tree. A search or a filter runs across every board in it, keeping
only the paths that hold a match. **Settings** (`/wiki/.settings`)
is Wiki settings, where its keys are set.
Board wiki addresses keep working. Beside the tree, the wiki lists the
notes edited most lately rather than folder cards: at its top, across
every folder and board; with a folder (or a board) open, only what is
in it and the folders inside it, newest first, each saying which folder it
sits in.

**A board's wiki** is your wiki from the board's folder down, like a chroot:
its own folders and pages, and the sub-boards of its epics in their folders
under `Cards`, by name when the tree is sorted by name, and nothing above.
A sub-board's wiki shows only its own part. There is no switch between trees:
the board's tree is the right part of your wiki already.

Opening a page of another board from a board's tree keeps that tree and its
breadcrumbs: Roadmap opened from Handbook's tree opens at
`/boards/<project work>/wiki/roadmap?in=<handbook>`, with a
quiet *on Project Work* beside the breadcrumbs that opens it in Project Work's own
wiki. The filter bar and the tree's search cover what the tree shows, so
from Handbook they find Projects pages, and from Project Work they don't find
Handbook's. A board you can't open isn't in your tree.
Organising works across it on the boards you can write to: a page dragged
onto *Projects* moves to Project Work, after asking.

**Dragging rows about.** With a mouse, a writer drags a page, a folder or a
file straight from the tree: press on its row and move. A press that moves
less than a few pixels is still a click and opens the row, so reading is
never a filing change. Both axes are rearranged in the same tree — a page
dropped in a folder is *kept* there and belongs to no page; a page dropped
on a page becomes *part of* it, filed where that page is filed; a folder
dropped in a folder moves under it, and cannot be dropped inside itself; a
file (an image, a PDF, a drawing) dropped in a folder is filed there, and
dropped on anything else goes to the folder that row is in — a file is never
part of a page, stays on its own board, and is refused where a file of the
same name already is. Drop on the middle of a row to put something inside
it, or on its top or bottom edge to put it beside it. In a folder sorted
*as arranged*, order is what you dragged: positions are packed afterwards so
a tree arranged by hand stays arranged. A folder sorted by name (the
default) or by date keeps that order: what is dropped beside a row is filed
there but takes its a-z place, and the tree says so; choose **Sort: As
arranged** to order it by hand, and it comes back as last arranged. Rest a drag on a shut folder and it opens, so you can drop deeper
without opening it first. A file moved here moves on disk at the next sync.

**Organise mode.** The pencil at the top of the wiki's sidebar gives every
row a handle to drag by, with a reminder of what a drop does. It is how a
touch screen drags (a finger on a row scrolls, and resting on it opens its
menu), and works the same with a mouse.

**A row's menu.** Right-click a row, or press its `⋯`, for what can be done
to it. Anyone can open it, open it in a new tab, or copy its link. A writer
can also:

- make a new note, folder or drawing in a folder (a drawing is an empty
  Excalidraw note, `….excalidraw.md`, as Obsidian's plugin writes one), or
  a new note inside a page;
- rename it, move it, or file a page in another folder as well (see
  *One page, several folders*);
- tag a page, archive a page, or delete a folder;
- **Delete…** a page for good, history and all. It asks first, saying how
  many pages under it are kept (they move to the top of the tree), and only
  the board's owner can confirm; anyone else is told so and can archive it
  instead. Deleting the page you are reading takes you back to the wiki;
- sort a folder: as arranged, by name, last changed first, or newest first,
  with its folders always before its pages, or **Same as the top** to have
  it follow the top's order (a folder does until it is given one of its own);
- **Organise…** a folder (see below).

**Organising a folder.** A folder's **Organise…** sorts what is filed in it —
its pages (with any pages under them) and its files — in one of four ways,
shows where each item would go with a tick box beside it, and files the
ticked ones when you press **Organise**. Folders that aren't there yet are
made on the way.

- **By date** puts each item in a dated folder under a parent you choose
  (the folder itself unless you pick another; empty for the top of the
  wiki): a note written on 12 October 2026, organised into *Meetings*, goes
  to *Meetings/2026-10* under the same name. One folder per month, year,
  year then month (*2026/10*) or day. A note's own `created:` or `date:`
  front matter is its date when it has one, since a note brought in from
  Obsidian was only *added* the day it was imported; choose **When it was
  added here** to ignore it.
- **AI suggestions** asks a cheap model (Claude Haiku by default, or the
  model you picked under Account → AI model) to read the board's folders,
  with a few example titles from each, and the titles in this folder, and
  suggest a home for each. It may suggest a new folder inside an existing
  one, never a new top-level folder; anything else is dropped. Nothing is
  sent until you press **Suggest destinations**.
- **By tag** puts a note in a subfolder named after its first tag
  (`#project/acme` makes *project/acme*); untagged notes stay.
- **Flatten** brings everything filed in the folder's subfolders, however
  deep, back up into it. The emptied subfolders stay.

Only the folder's own board is organised; to move things to another board,
use **Move…**. A file whose name is already taken where it would go
is left where it is, and the message says so. From the command line:
`slipdock folder organise <board> <folder> --by date --parent Meetings
--dry-run`.

Right-click the tree's background for the same things at the top of the
wiki, including how the top is sorted. The top is sorted by name until
someone chooses otherwise, so a wiki reads a-z, ignoring case, folders and
pages alike, including folders a sync adds later. With a token,
`slipdock set-board <board> --wiki-sort modified` or `PATCH /api/boards/:board/tree
{"sort": "modified"}` sets it, and `GET /api/wiki/sync` carries what a client
needs to draw the same order.

**Picking several.** Ctrl-click (Cmd-click on a Mac) picks rows one at a time
and Shift-click picks every row from the last one. A bar above the tree then
moves, archives or tags them all at once, and a row's menu acts on all of
them. Esc lets go.

**Moving a page to another board.** A page can move to any other board in
the same wiki you can write to: drag it there in the wiki's tree, or
use **Move…** from its menu. Before it moves you are shown what it takes and
what it can't. It keeps its code (`W-31`), history, comments, checklist,
links and its other folders, and the pages under it go with it. Tags and
custom field values go where the other board has one of the same name (or
key), and pinned cards stay pinned where the card is in that board's tree.
Whatever has no match is listed and stays behind, as do its place in a list,
an assignee who can't open that board, and its parent page. On a shell,
`slipdock page mv <page> --board B [--folder F] [--dry-run]`.

**Moving a folder to another board.** In the wiki, a folder's **Move…**
offers every board in the wiki you can write to and its folders, and
dragging a folder onto another board in the wiki's tree does the same.
Either way you are shown what goes first — how many folders, pages and files,
what can't be carried, what stays behind, pages landing beside one of the
same title — and nothing moves until you confirm. Pick several rows (pages
and folders together) and **Move** them as one, with one combined report; a
page inside a folder you also picked goes with the folder, once.

A folder moves to any board you can write to, with its
subfolders, every page at home in them (and the pages under those pages) and
the files kept in them, in one go:
`slipdock folder mv <board> <folder> --board B [--parent F] [--contents]
[--dry-run]`. The folders keep their names and order, under `--parent` on the
other board or at its top; with `--contents` only what is *in* the folder
moves, landing straight there, and the emptied folder goes. Each page keeps
its code, history, comments, checklist and links, and carries its tags,
field values, pins and assignee the way a single page does. `--dry-run`
reports it all first, folder by folder: how many pages, what can't be
carried, any page that stays behind (one filed there under a parent page
that isn't moving), filing in other folders that can't follow to a board in
another wiki, and pages landing beside one of the same title. It is
refused, with nothing changed, when a folder of that name is already where
it would land, or when you can't write to both boards; and it happens all at once
or not at all. A synced copy of the wiki sees each moved note as the same file at its
new path. Over the API it is `PATCH /api/boards/:board/folders/:folder` with
`to_board`; over MCP, `manage_wiki` with `action: "move_folder"`.

**Searching the tree** matches a page's title and summary *and* a folder's
name, and hides everything that doesn't match. A folder that matches brings
what is in it, because somebody typing the name of a folder is asking where
things are. A page that matches keeps the pages and folders above it, shown
faded, so you can see where it lives. A word starting with `#` matches a tag:
a note's own `#tags` (nested ones too, so `#area` finds `#area/sub`) or one of
the board's tags by name, so `retry #ops` is pages tagged *ops* with *retry*
in their name. By default it does not read the words inside the pages; under
the search, **Match the words inside pages here too** turns that on. That is
a plain match on the text. Search (`/search`) reads bodies and matches by
meaning: **Full text search for: _what you typed_** is one click to the same
words there, already narrowed to this board.

**Two kinds of tag.** A page has the board's tags, the ones its cards wear,
which **Tag…** in the tree puts on one page or a selection and `slipdock page
edit <page> --tag T` sets from the command line (over the API, `add_tags`,
`remove_tags` and `tags` on `PATCH /api/pages/:id`; over MCP, `update_page`). A
tag has to exist on the board first, and a name that isn't there is refused. A
note also has tags of its own (`note_tags`), from its front matter
and inline `#tags`: those are edited in the text, and nothing above touches them.

**Picking a folder is a tree you type at.** Everywhere the app asks which
folder — filing the page you are reading, the Folder field in the editor, the
"Inside" of the New folder dialog — it shows the filing as a tree and narrows
it as you type, matching anywhere in the path, so "dec" finds `Design/
Decisions` and the arrow keys and Enter pick it without the mouse. A folder
you cannot choose, like the one you are moving, is greyed rather than hidden.

**One page, several folders.** A page has one **home** folder and can be
**also filed in** others, like a symbolic link: every one opens the same
page, with one body and one history. The other folders can be on any board
in the same wiki. Listing a folder includes the pages also
filed there, marked `also: true` over the API, and each page appears once.
Archiving or moving a page keeps its other folders; taking it out of one
never archives it; deleting a folder takes only its placements. In the
wiki's tree the page shows in each folder it is filed in, with a link marker
on the extra ones. Its menu there has **Also file in…** to add one, and the
extra row's menu has **Take out of this folder**. Only readers who can open
the page's own board see it in the other folders.
`slipdock page file <page> --also F` (or `--not-in F`) — F a folder on its
board, on `--board B`, or a wiki path such as `/Projects/Notes` — and
`{"also": F}` / `{"not_in": F}` on `POST /api/pages/:id/folder` (MCP:
`update_page`'s `also` and `not_in`) do it; a page's JSON lists them as
`also_in`.

**One folder, several places.** A folder can be also filed in other folders
the same way (#808): it appears there with its whole subtree — pages, files,
drawings and subfolders — and there is still one folder with one set of
contents, at home under its parent. The rules are the pages': the other
folder is on its board or on a board in the same wiki, you need write on
both, and it is never its home parent. Nor is it ever inside its own subtree,
whether the way down runs through home parents or through other placements;
moving a folder home under one filed inside it is refused the same way. In
the tree the placed folder follows the folders at home there, with the link
marker; it opens and shuts there on its own (each place keeps its own open
state), shows only what the reader may open, and is not dragged about — nor
is anything inside it, there. Its menu has **Open**, **Open in a new tab**,
**Take out of this folder** and **Copy link**, and what is inside it has the
same without **Take out**; any folder's menu has **Also file in…**. A row seen
from another folder like this, a page's extra row too, is renamed, moved,
archived or picked for the selection bar from its home row: **F2**,
**Delete** and Ctrl- or Shift-click pass it by. The folder's page says where
else it is filed. Listing a folder
(`page ls --folder`, `list_pages`' `folder`) includes the pages anywhere
under the folders placed there, marked `also`. A synced copy of the wiki
writes the folder once, at home. Moving it to another board drops the
placements the move leaves outside one board or wiki, and says which
(`folder_filing_dropped`); deleting either folder takes its placements.
`slipdock folder file <board> <folder> --also F` (or `--not-in F`; both
repeat; `--board B` for a folder on another board in the wiki, or a wiki
path), `{"also": F}` / `{"not_in": F}` (with `in_board`) on
`PATCH /api/folders/:id` or `/api/boards/:board/folders/<path>`, and the MCP
tool `file_folder` do it. A folder's JSON lists them as `also_in`;
`slipdock folder show <board> <folder>` and `folder ls` print them.

### Sharing pages and folders

A page or a folder can be shared on its own with somebody who has no reason to
see the rest of the board (#813): **Share…** on the page's ⋯ menu, or on a
page's or folder's menu in the tree, adds a person by email (a stranger is
invited, as for boards) or one of your groups, **read only**, **can comment**
or **can edit**, and lists and takes back what is there. Only the board's owner and writers can
share; somebody a thing was shared with cannot pass it on. A shared page or
folder wears a small people mark in its owner's tree, and Page details says how
many people and groups have it.

**Sharing a folder shares everything at home in it** — its pages, files of every
kind, drawings and subfolders, to any depth. What is only *also filed* in a
shared folder from elsewhere is **not** shared by that: it shows only to people
who can already read it, so filing a page into a shared folder never quietly
shares it.

**A shared page brings what it embeds.** An image, a file or a drawing the page
embeds with `![[diagram.png]]` shows for whoever the page is shared with, even
when it lives in a folder that isn't shared (#832) — it is served to them
through the page, and to nobody else. Only embeds count: a file the page merely
links (`[[Report.pdf]]`) stays as readable as it was. And only embeds written by
somebody who could see the file themselves: somebody the page was shared with
to edit can't write `![[secret.png]]` into it to read the owner's other files.
Images pasted into a page are the page's own, and always go with it. A published
page (`/w/…`) still shows no embeds.

**Shared with me.** Whatever has been shared with you appears under **Shared
with me**, below every one of your wiki trees and on the Wiki page,
grouped by whose it is; a shared folder opens to its whole subtree, and the
section is hidden when nothing is shared. It follows the shares live: one given
appears, one taken back goes, and a page open when its share is taken back sends
you back with a word. A page opens in the Shared view (`/shared/pages/:id`),
which never shows the board it is on, its cards or its other pages — a link in
it to anything you can't open reads "a page you can't see". Files and drawings
open in their own viewers as ever, and go back to Shared with me.

**What a share to edit lets you do.** Somebody with **can edit** on a shared
folder edits and renames what is in it, makes pages, files, drawings and
subfolders inside it, and moves things about within it. New things are the
owner's: on the owner's board and counted against the owner's limits, with you
as their creator. They cannot delete, archive or restore anything; move
anything out of the share, to the top of the wiki or to another board; move the
shared folder itself or organise its folders; share it on or publish it at a
public link; or encrypt it. A page shared on its own is edited and renamed, not
moved. These rules hold in the API, the CLI and MCP as well as in the browser:
each refusal is a `403` with a code (`shared_no_delete`, `shared_no_move_out`,
`shared_no_reshare`, …) and says why. Writers on the board keep everything they
always had.

**Filing a shared item in your own tree.** **Also file in…** on a page or
folder in the Shared view files it in a folder of one of your own boards — the
one time something is filed outside its own board or wiki. You need to read it
through the share and write the folder. It shows there only to people who can
read it (others on your board see nothing), opens in the Shared view, and comes
out again with **Take out of this folder**, which never touches the share.
Taking the share back takes the placement away too; sharing again doesn't bring
it back.

**In a synced wiki** a shared item filed there syncs as **stubs**, never its
content: `Title.md` holding one line, a link to it in Slipdock (`name.png.md`
for a file), and a shared folder as a directory of stubs mirroring its subtree.
They follow renames and moves inside the share, and go when the share or the
placement does. An edit to a stub is not sent: the next sync puts it back and
says so (`↺`). The owner's own sync is unchanged.

`slipdock page share <page> <email|group> [--write] [--off]`, `slipdock folder
share <board> <folder> …` (nobody named lists who has it), `slipdock shared`;
`POST`/`GET`/`DELETE /api/pages/:id/grants` and `/api/folders/:id/grants`,
`GET /api/shared`; the MCP tool `share` and `list_pages` with `shared: true`.

**Filing never destroys writing — unless you say so.** Deleting a folder
deletes the folder: its subfolders move up to its parent and its pages go back
to the board's root. Deleting one that holds something asks which you meant,
and the other answer — the folder *and* everything in it, pages and history —
is the board owner's to give, as purging a page is. A folder cannot be moved
inside itself. A folder named as a path — `Design/Decisions` — makes every
level it needs, and making the same path twice makes it once, so an agent
filing a document never has to build the filing cabinet in a separate call.

**Deleting a page.** Archiving is the reversible one and is what the page's
actions menu offers first; **Delete permanently** below it is the owner's
purge — the page, its whole history and its attached images, gone, with the pages *under* it kept
and lifted to the top of the tree rather than going silently with it. The same
menu downloads one page as Markdown, front matter and all.

**The Wiki view** at `/wiki` (from the Home page, the account menu, or the
command palette) is the same thing over every board the reader can open: each
board a top-level folder, its folders and pages inside, with a search that
narrows the lot by title and summary. It is read-only on purpose — making and
moving folders belongs on the board that owns them, where the permissions and
the rest of the wiki's tools already are, and a folder's name there links
straight to it on its own board.

Bodies are CommonMark with the GitHub extensions — tables, task lists,
strikethrough, autolinks, footnotes — rendered by comrak (`:mdex`) and
sanitised, so raw HTML in a body never becomes raw HTML on the page. Headings
get ids, so a section can be linked to. Those, a footnote's and a block's
(`^a1b2`) are the only ids on a page: an `id` written in raw HTML is dropped,
since an id names a property of the page's `window`.

The editor is **raw Markdown with a live preview**, deliberately and for good:
the source stays diffable, greppable and identical to what an agent reads and
writes over the API, which a rich-text layer could not promise. Pasting or
dropping an image into it attaches the image, the way it does on a card.
The editor opens as one pane across the whole width of the page: headings,
lists and code take their shape as you type. **Preview** beside Save puts the
rendered page beside it (and takes it away again), and your browser remembers
which you chose.

**References.** Inside a body, `[[Retry policy]]` links a page on this board
(by title, then slug), `[[retry-policy|how it works]]` gives it link text,
`[[QVM/Retry policy]]` reaches another board, `[[W-31]]` (or a bare `W-31`)
uses a page's code, and `[[board:QVM]]` / `[[view:QVM/Blocked work]]` reach a
board or a saved view. `@name` mentions someone on the board.
`[[!toc]]`, `[[!children]]` and `[[!backlinks]]` expand when the page is read.

Typing `[[` in any editor (a page, a card's description, a comment) opens a
page picker: the pages changed most lately first, then whatever matches what
you type after the brackets, whether a title, a folder (`specs/bil`), an alias
or a code (`W-31`, which puts that page first). Arrow keys pick, Enter or Tab
writes the link, Escape closes it. The link it writes is `[[Retry policy]]`
when the title alone finds the page from where you are writing, and
`[[W-31]]` otherwise (another board's page, a title two pages share, or one
with `/`, `|` or `#` in it).

The picker reaches your whole wiki: on a board somebody else shared with
you, that board's owner's pages you can open come first, then your own wiki's,
each showing whose wiki it is in. A page from another wiki or board is linked by its code, and `[[W-31]]` finds that page
wherever it is, for anyone who may open it; to anyone else it reads as
plain text. The card's attach box offers the same pages, and so does
`slipdock page switch <board> <letters> --all` (`?vaults=all` on the API, a
name kept from before).

As in Obsidian, `[[Retry policy#Backoff]]` goes to a heading of a page and
`[[Retry policy#^a1b2]]` to a block — a paragraph or list item ending in
` ^a1b2`, which is an address and is not shown — and `[[#Backoff]]` to a
heading on the page itself. `![[Retry policy]]` **embeds** the page where it
is written, and `![[Retry policy#Backoff]]` or `![[Retry policy#^a1b2]]` just
that section or block: drawn for whoever is reading, one level deep (an embed
inside an embed is a link), and on a published page only named. An embed of a
file (`![[diagram.png]]`) stays as written for now. The API's Markdown
render quotes what an embed shows.

`#412` (or `[[#412]]`) is a **card chip**, drawn from what the card says at
the moment the page is read — its title, its list, whether it is done — so a
card renamed or finished after you wrote about it is never stale in your
prose. A number that matches no card you can open stays literal, so
"#1 priority" survives, and a chip for a card the reader cannot open degrades
to plain text rather than telling them it exists.

A reference inside backticks or a fenced block is not a reference: the wiki's
syntax is applied to the *parsed document's text nodes*, not to its source, so
that is a property rather than a promise.

**Wanted pages.** A `[[link]]` to a page nobody has written is not an error —
it renders as an invitation to write it, carrying the title through, and the
wiki's index lists every one, most-wanted first. That is the classic way a
wiki grows and a good work queue. Writing the page brings every link that was
waiting for it to life, and because a link is stored by id once it resolves,
renaming a page can never break the links into it.

**Sections.** A page can be addressed by heading — `Deploy/Rollback` is the
`## Rollback` under the `# Deploy` — and read, replaced or appended to one
section at a time. Two writers touching different sections never collide, and
an append cannot clobber anything at all, so it takes no hash and never
refuses. That is the write an agent keeping a `## Log` should use. An append
lands at the end of the section's own text, before its first subsection; text
that brings a heading of its own goes after the subsections, so it can't take
them over.

**Live queries.** A fenced ```` ```slipdock ```` block in a page is a question,
answered when the page is *read* rather than when it was written — so a
hand-typed list of blocked cards, which is wrong by Tuesday, becomes one that
never is:

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

It is evaluated **with the reader's permissions, every time** — never the
author's — so a document cannot become a way to see cards you could not
otherwise open: a board the reader cannot read is dropped before a single
card is looked at. The block compiles to the same `Slipdock.Swimlanes.Config`
the board views use, and anything a config cannot express is handed to the
automations' own condition vocabulary, so there is one filter language rather
than two. `board:` takes `this`, `tree` (the board and everything beneath it)
or another board's code; `saved_view: "Blocked work"` embeds a view you
already made; `card: 412` with `view: progress` rolls one card's tree up;
`assigned: me` is the reader's own work.

Views are `table`, `list`, `board`, `count`, `progress`, and `timeline` /
`calendar` as presets of the first two. A block that cannot be answered
renders as a note on the page with the reason and the block beneath it: a
document with one bad query is still worth reading.

In a sentence, `{{count: flag=blocked}}`, `{{progress:412}}`,
`{{card:412.due_date}}`, `{{board.name}}` and `{{today}}` answer inline. An
expression the app does not understand is left exactly as written — which is
also what keeps a template page, whose `{{card.title}}` is filled when a page
is *made* from it, readable before it is used.

**Backlinks and pins.** Every page shows what links to it. A page can be
*pinned* to a card — "this is the spec for that" — which is a person's
judgement rather than something the prose says, so it survives a rewrite.

**On the board.** A page can be put in one of its board's lists and dragged
about like a card — the spec sitting in "In Progress" beside the work it
describes, the retro waiting in "To Do" to be written. It shares one position
sequence with the cards, so it sits *between* them rather than after them all,
and moving a card past it works the way moving a card past a card does. It is
a second, optional axis: the page keeps its place in the wiki tree either way,
and taking it off the board changes nothing about the page.

**A page has the card's facets.** Priority, flags, tags, an assignee, start
and due dates with the same fuzzy precision, a done tick, a percentage, a
cover colour — the same field names and the same vocabularies, so nothing in
the view layer has to ask which it is holding. These are the attributes that
say *where a thing stands*, and they are what a board groups, filters and
sorts by.

**And nearly all of its contents.** Comments, status updates ("this spec is
at risk"), a checklist, web links, votes out of the board's budget, and the
board's custom fields. Not a second set of tables — the *same* tables, with
each row belonging to exactly one of a card or a page and the database
enforcing it. So there is one way to write a comment, one set of readers, and
the same components draw both panels.

What stays card-only is the work-shaped pair: blocking **dependencies** and
typed **card links**, which are card-to-card joins carrying scheduling
meaning, and **sub-cards**. A page has richer ways of pointing at things —
`[[wikilinks]]`, backlinks and pins, which say what a document is *about* —
and child pages, which is what its subtree is for. Ask a page for the rest
and you get an empty list, not an error.

A comment on a page is writing too: `[[Retry policy]]` in one turns up in
that page's backlinks, naming the page it was written on — exactly as a
comment on a card does.

So a placed page is drawn as a card, and behaves as one everywhere. It has a
cover strip, its priority bars, its assignee's avatar, its due chip; it
appears in **every** view — board, swimlanes, table, timeline, calendar — and
is grouped, filtered and sorted beside the work. Drag it into the "Critical"
row and its priority changes, exactly as a card's would. The one difference
is the small **document icon** where a card's tick box would be: clicking it
opens the document, and clicking anything else opens the card-style panel —
priority, assignee, dates, flags, tags, list, and the comments, checklist,
status updates, links, fields and votes — with **Open the document** in it.
Two gestures, no ambiguity. The document's own page carries the same sections
below the prose, which is where most of that conversation actually happens.

A wiki that is only documents can do without them. Untick **Card features on
wiki pages** in the board's settings and every page in that board's wiki — its
own view and its panel on the board — leaves out the status, checklist, links,
fields, votes and comments. It is one switch for the whole wiki, and nothing
is deleted: tick it again and they are all back. From the command line it is
`slipdock set-board <board> --no-page-card-features` (or
`--page-card-features`), and over the API `PATCH /api/boards/:board
{"page_card_features": false}`.

A draft on the board is visible only to people who could edit it, and a page
counts towards nothing — not the card count, not the WIP limit. Deleting a
list leaves its pages behind, unplaced rather than deleted.

**Both ways.** A card's panel has a **Docs** section listing every page that
mentions it, pinned first, with **Write it up** to start one — pre-titled,
pinned, and filled in from a template page when the board has one, and on disk
named as the card's folder is, `Cards/<short>/<short>.md` — and a
picker to attach a page somebody has already written, which is the commoner
case. It lists the pages changed most lately as soon as you click into it,
and finds one by title, folder or code, in your wiki, as the `[[`
picker does. The page, in turn, has a **Cards this is about** section with the same
pin toggle and the same picker, so the two are one click from each other in
both directions. A pinned link is a person's judgement rather than something
the prose says, so replacing every word of a page never detaches it from its
card. From the other side, selecting a passage of a page offers to make a card
of it: the first line becomes the title, the rest the description, and the link
is written into both ends, so a document is where a backlog comes from. A
comment on a card can `[[link]]` a page too, and shows up in that page's
backlinks — writing on cards is writing.

**Templates.** A page marked a template is not read as content, it is copied.
Bodies may use the same `{{…}}` placeholders an automation action does —
`{{card.title}}`, `{{board.name}}`, `{{today}}` — plus any values passed in,
and Obsidian's own: `{{title}}` (the new page's title), `{{date}}`
(`2026-03-07`), `{{time}}` (`14:05`), and `{{date:dddd D MMMM YYYY}}` or
`{{time:h:mm A}}` in Moment's format, as Obsidian writes them — so a template
brought over from Obsidian works as it is. Dates and times are UTC.
A board template can carry `pages` as well as lists, so a new board arrives
with its documentation skeleton rather than an empty wiki. A page can also be
a **favourite**, alongside boards, lists, cards and views.

**Every save keeps a revision** — a full snapshot, with the author, the edit's
own message ("why", not "what"), and how it arrived (`web`, `api`, `cli`,
`assistant`, `automation`, plus the API token's name). History lists them,
each with the lines it added and removed ("+4 −1 lines"); the arrow at the
start of a row opens it onto those lines, removed and added, without leaving
the list (a long change shows its first twelve and links the version for the
rest). Any one can be diffed against the one before it or any two compared side by
side (old on the left, new on the right, the changed words picked out, as
GitHub's split view does: tick two in the history and press **Compare selected
versions**, or **Compare with current** from an old one), and any one can be put back —
which is itself a save, so nothing is ever removed. Consecutive saves by the
same hand within ten minutes collapse into one, so an agent appending every
few minutes does not bury the day's real edits.

**A save can carry the hash it was based on.** Every page has a
`content_hash`; send it back and a save that would land on top of someone
else's is refused with both versions to merge, rather than applied. Leave it
out and the last write wins, which the revision makes recoverable but is
still a paragraph gone. Two agents and a person may all be writing the same
runbook.

Pages are archived rather than deleted (with the pages beneath them), and only
a board's owner can purge one. A page can be marked a **draft**, which makes
it visible to people who could edit the board and to nobody else, and it can
be **shared on its own** — a grant on the page reaches it without opening the
board, so "share just this doc" never has to be answered with "move it
somewhere else". A board reachable only through a shared saved view does not
reach pages at all: a view is a window onto cards, and must not leak the
documents beside them.

**Semantic search covers pages too**, in the same index and ranked against
cards: "what did we decide about refunds" finds the decision record and the
card that argued about it, in one list. A page is chunked **by heading**
rather than by a fixed window — a section is what a person wrote as a unit,
and a heading is a free label for it — so a result links to the section
(`…/wiki/runbook#rollback`), editing one section re-embeds one section, and
`--kind pages` narrows the search to documents. A page's title counts for the
keyword boost as well as its body, and a document ranks a shade below a card
of equal score: the card is the live thing and the page explains it. Drafts
are never indexed, and a page the reader cannot open never comes back — the
reader's own permission is re-checked on the way out rather than trusted to
the index.

The assistant has the wiki too: `search_pages`, `read_page` and `list_pages`
alongside its card tools, so "how does X work" and "is there a runbook for X"
are answerable — and it is told to say so when a card and a page disagree
rather than choosing between them.

Over the API: `/api/boards/:board/pages` (GET, with `?tree=true`, `?q=`,
`?parent=`, `?folder=`, `?archived=`, `?template=`; POST to write one) and
`/api/pages/:id` (GET, PATCH, DELETE, plus `/render`, `/sections`,
`/section/*path`, `/append`, `/links`, `/folder`, `/restore`, `/move`,
`/revisions`, `/revisions/:rev?diff=previous` (or `?diff=<revision id>` to compare
with another version) and `/revert`). Reads return the
Markdown source, not HTML — the model edits what it reads — and `/render`
returns it with every reference followed, which is what to read to answer a
question rather than to change the page. Folders are
`/api/boards/:board/folders` (GET, POST), `/api/folders/:id` (PATCH, DELETE —
`?purge=true` takes the pages in it too, owner only; also by any handle at
`/api/boards/:board/folders/*path`), and `/api/wiki` is
every board at once. `/api/boards/:board/tree` is one level of the tree the
way the web's tree loads it — the rows directly in the root, a folder
(`?folder=`) or a page (`?page=`), each with how many rows are under it, and
never a body; `slipdock folder open <board> [<folder>]` prints it. On a shell, `slipdock page ls|tree|read|render|new|edit|
section|append|file|mv|rm|restore|links|pin|wanted|history|diff|revert`, plus
`slipdock wiki` and `slipdock folder ls|open|new|mv|rm [--purge]`.

**Publishing.** A page can be published read-only at `/w/:token`, the way a
saved view can. Its live queries are answered **when you publish** and the
answers kept, and its references — card chips, page links, mentions — become
plain text: there is nobody behind an anonymous request to have the
permissions a live query or a followable link would need, so a published page
is a live copy of its prose and a snapshot of its answers. Publishing again
refreshes them; a draft cannot be published at all.

**Automations reach the wiki.** `create_page` starts a page for the triggering
card, pinned to it and from a template page if one is named, and `has_doc` is
a condition — so "when a card lands in Ready and nothing has been written
about it, alert me" is a rule rather than a habit.

**Out and back in.** `/boards/:id/wiki.zip` downloads the whole wiki as one
Markdown file per page — front matter carrying what Markdown cannot say, the
tree as folders, and `[[links]]` left exactly as written in the dialect
Obsidian reads. A folder of Markdown imports the same way, folders becoming
parent pages, and a title already on the board is skipped and reported rather
than duplicated. This is the escape hatch, and it is deliberate: a wiki you
cannot get your writing out of is one to think twice about putting writing
into.

**Front matter is kept exactly.** A file imported with front matter keeps
all of it — key order, quoting, comments, the blank line before the body —
not just the keys Slipdock reads (`title`, `summary`, `status`, `template`).
The page shows it folded away as **Properties**, and an export writes it back
with only Slipdock's own keys patched in place; a `status: reading` of your
own is left alone. The file a later sync writes gets no key that changes on
every save — no `updated`, no author, and `code` only if asked. Read and
replace it with `slipdock page props <page> [--file F | --clear]`, the API's
`front_matter` field (the YAML between the `---` lines), or MCP's
`read_page` and `update_page`. A change to it alone is a revision in the
page's history like any edit, and `--message M` (the API's `message`) says
why there.

**Aliases.** A page whose front matter lists `aliases` (or Obsidian's older
`alias`) answers to each of them: `[[Retries]]` finds the page whose aliases
include "Retries", case aside, wherever `[[Retry policy]]` would. A page
titled with the word beats one that only answers to it, and a link written
before the alias existed comes alive when it is added. Aliases are read from
the front matter, so they are changed there (`slipdock page props`), and a
page's JSON lists them as `aliases`.

**The wiki keeps the board's bar.** The view selector, the search box, the
filter menu and the display options sit above the wiki the way they sit above
every card view — because a page answers the same filters now that it carries
the same facets. Narrow by priority, flag, tag or due date and the page tree
narrows with it; a page whose parent was filtered out stands at the root
rather than vanishing with it. The display menu is the wiki's own: whether to
list drafts, templates and archived pages at all.

The full specification, and the decisions behind it, is in `docs/wiki.md`.

### Your wiki

<a id="vaults"></a>

You have one **wiki**: everything written on your boards as one folder tree
of Markdown (and other) files, notes, images and PDFs, the way Obsidian keeps
notes. Slipdock doesn't need Obsidian; any editor that works on a folder of
Markdown will do. `slipdock sync` mirrors the tree to a folder on each
computer (see [Syncing your wiki to a folder](#syncing-your-wiki-to-a-folder)).

Nothing about its layout is configured:

```
/Knowledge Base                  → your Knowledge Base, always first
/Handbook                        → the Handbook board's wiki
/Project Work                    → the Project Work board's wiki
/Project Work/Cards/Launch       → the Launch epic's folder, and its sub-board
/Project Work/Cards/Launch/Cards/Press → a subcard's sub-board, one level down
```

**Your Knowledge Base** is the part of your wiki that belongs to no board of
work: notes, references, whatever you keep. Everybody has one, made the first
time it is wanted. It is always the first folder at the top. Underneath it is
a board that is a wiki and nothing else, so its pages have codes, history,
links and sync like any other, but it is on no list of boards, counts against
no limit, and opening its board takes you to its place in the wiki. Quick
notes go to the top of it unless you choose another place.

**Every board you own** is a folder at the top, after the Knowledge Base, in
the order your home page keeps by hand: the boards you placed, by their place,
then the rest, oldest first. A new board shows at once, and renaming a board
renames its folder. Everything in a board's wiki is in its folder. Board
folders are disk names, safe on any machine, and two boards whose names
clash, case aside, are numbered in age order: `Keystone`, `KEYSTONE (2)`.
The root holds boards and nothing else: a file written straight into it, or
into a folder that is no board, is refused.

**An archived board is out of the tree**, the sync listing and the feed. An
archived board is set aside, so its wiki is no longer loaded with the rest.
Open it from the archived boards on your home page and its own wiki shows its
tree as before; restore it to have its wiki back in yours. Links to its pages
still work.

**A board with nothing written** on it or on a board below it, no page and no
file, is left out of the tree too, however many folders it has. Write its first
page from the board's own wiki and it joins the tree. Your Knowledge Base is
always there, written in or not. A synced folder keeps such a board's folders:
the listing marks it `empty` rather than leaving it out.

**Boards somebody shared with you** are not in your wiki. They are in their
owner's. You read them on the board, or under **Shared with me** (see stubs
below).

**Wiki** in the menu, or on the home page, opens the tree from the top, at
`/wiki`. **Settings** at the top of the tree (`/wiki/.settings`) has the
wiki's shortcut and hotkey, its recordings folder, and the folders it is
synced to: every `slipdock sync` token that has listed it or followed its
feed, by the token's label, with when it last did. Old `/vaults/…` addresses
land in the same place under `/wiki`.

The same is on the CLI (`slipdock wiki show`, `set`, `locate`, `tree`), the
API (`GET /api/wiki`, which carries `pages`, `boards`, `mirrors` and
`knowledge_base`) and MCP (`wiki_info`, `manage_wiki`).

**Links across your wiki.** A plain `[[Note]]` looks on its own board first
and then across your whole wiki. Every page there has a path — its board's
folder, the folders below it, the pages it sits under, its title: the layout
an export writes — and a link matches by name (title, slug or alias,
compared as file names are, case aside). When several pages match, the
shortest path wins; write more of it, `[[X/Dup]]` or `[[Projects/X/Dup]]`,
to pick another, the way Obsidian does. A link written relative to its note,
as Obsidian writes them when its new link format is relative —
`[[../Tasks/Inbox]]`, `[[./Plan]]`, or `[[2026/Journal/Note]]` from the
note's own folder — is read from the note's folder. A link or embed naming a
file, `[[Report.pdf]]` or `![[photo.png]]`, finds the wiki file of that name
and links to it, and is not counted as a wanted page. `[[QVM/Page]]` still
means board QVM first. The words are never rewritten, a resolved link is kept
by id so a rename cannot break it, and a page or file written later brings
links on any of your boards to life. Backlinks cross boards with the links.
`slipdock wiki resolve <link>` says which page a link finds; `slipdock wiki
wanted` (or `GET /api/wiki/wanted`, MCP `page_info`) lists the pages wanted
anywhere in it. A board somebody shared with you resolves its links in its
owner's wiki.

**What changed, for sync.** Every change to a page, a folder or a page's
attachment is logged with an increasing **cursor**, on every board. Your
wiki's feed — `GET /api/wiki/changes?since=<cursor>`, `slipdock wiki changes
--since N`, or MCP `wiki_info` with `changes_since` — answers with what
changed on any of its boards after that cursor, each page or folder once and
as it is now (a page's code, title, `content_hash`, home folder, whether it
is archived, and its path), or `deleted`; `more: true` means ask again at
once. Renaming a card, a short name or a board shows as `moved`, with the old
path in `from_path`, on the folder and on everything under it: never a delete
and a create, and a moved file keeps its hash unless its bytes changed.
Archiving a board shows only as that board's change, `archived` (drop its
folder), and restoring it as `restored` (list again). `slipdock sync` moves
the files here, and an edit made here follows them. Without a cursor it
answers with the one to start from. A client can also keep a websocket open
at `/socket/websocket?token=<API token>&vsn=2.0.0` and join the wiki's
`channel` (from `GET /api/wiki`): each change pushes `change` with the new
cursor, so it knows when to ask. The log keeps 90 days
(`config :slipdock, :wiki_changes, retention_days:`); asked from a cursor
older than that, the feed answers `resync: true` and the current cursor,
which means list the wiki again rather than trust the gap.

**Names in trees and lists.** Account › Preferences, or the button at the top
of the tree, chooses full titles or short names for the wiki's tree, card
folders and breadcrumbs. It is yours, everywhere you sign in, and
`slipdock names short` or `PUT /api/me/display` set the same thing. A card
with no short name shows its title, and pages have no short names. A name too
long for its space ends in an ellipsis on screen, with the whole of it on
hover. `slipdock folder ls --short-names` and `slipdock wiki tree
--short-names` do the same in a terminal.

**Tags in notes.** A note's front matter `tags` and every inline `#tag` in
its body are its tags, nested ones (`#area/sub`) included, as Obsidian reads
them: not inside code, headings, links or HTML, and only where `#` starts a
word, so a URL's `#fragment` is not one. They are the note's own, kept apart
from the board's card tags so they never fill the tag picker, stored
lower-case, and shown as chips at the top of the page. A tag whose first part
is all digits stays a card reference (`#412`). List the notes under a tag —
and anything nested beneath it — with `slipdock page ls <board> --note-tag
area`, `?note_tag=area` on the API or `note_tag` on MCP's `list_pages`;
`slipdock page tags <board>` (or `GET /api/boards/:board/pages/tags`) counts
them.

**Moving a board's wiki into another.** An operator can move one board's
whole wiki into a folder of another board of the same person, keeping page
codes, history and files and rewriting any `[[link]]` whose target moves
(each checked to find the same page, and saved as a revision):
`mix slipdock.move_wiki --user EMAIL --from CODE --to CODE --folder NAME
--dry-run` (then `--apply`), or `Slipdock.Release.move_wiki/1` in a release.
The folder holding the board's card folders stays, since a card's pages live
with the card.

### Syncing your wiki to a folder

<a id="syncing-a-vault-to-a-folder"></a>

`slipdock sync` keeps a folder on your computer and your wiki level with each
other, both ways. The server is where the notes live; the folder is a
working copy that stays a valid Obsidian vault, so Obsidian, vim, a script
or anything else that writes a file can add to it, and what they write
becomes a page.

```sh
slipdock sync init ~/Notes                   # bind the folder, then bring your wiki down
slipdock sync ~/Notes                        # one pass, both ways
slipdock sync ~/Notes --watch                # keep at it
slipdock sync from-server ~/Notes            # one pass, only bringing changes down
slipdock sync to-server ~/Notes              # one pass, only sending changes up
slipdock sync service install ~/Notes        # …in the background, starting at login
slipdock sync status ~/Notes                 # what is waiting, and what is in conflict
```

**Files.** A note is `Title.md` in the directory its folder names; a page
with pages under it is `Title/index.md`, with its children beside it. A
title a file name cannot hold (`Retry: why`) is written with the
characters substituted (`Retry- why.md`), and the true title kept in front
matter. A note that arrived with a name of its own — front matter giving it
another title, a name longer than 80 characters or ending in a space — keeps
that name until the page is renamed. Renaming the file renames the page, and the other way round; moving
it to another directory refiles it, making the folder if there is none, and
in another board's folder it becomes a page on that board. Notes made
in the folder are always plain files. A page filed in several folders is
written once, at its home, with `also-in: [Path/One, Path/Two]` in its front
matter; edit that list and the page is filed accordingly. Images, PDFs,
`.excalidraw` drawings and other files are kept at the same path, up
to 250 MB each, and `![[photo.png]]` draws them in the web app too.

**Opening a file.** Click a file in the tree, or a `[[Report.pdf]]` link
in a page, and it opens in the page's place, filling the wiki beside the
tree (on a phone it covers the page); the address stays where it was. The
file has Download, an arrow that opens it on a page of its own
(`/files/<id>`, also where Ctrl/Cmd-click and "open in a new tab" go), and
an X; Escape closes it too, and either brings back the page you were
reading, a half-written edit included. Opening a page from the tree puts
the file away. Images (PNG, JPEG, GIF, WebP,
and SVG, which is shown so it can run nothing) are drawn; a PDF opens in
the browser's own PDF viewer; an HTML file (`.html`, `.htm`) is drawn in a
sandbox: its scripts don't run, its forms don't send and it fetches
nothing, so pictures it links to are left out; audio (`.mp3`, `.m4a`,
`.wav`, `.ogg`, `.opus`, `.aac`, `.flac`) plays in the browser's own
player, the one a card's recordings have, and can be skipped through; a
transcript (`.vtt`, and `.srt`) reads as a conversation, each speaker's
turn under their name in a colour of their own with the time it starts
(a `<v Name>` tag or a `Name:` prefix names them); JSON is a tree whose objects and arrays fold
(the outer two levels open), JSON Lines an array of its lines, invalid
JSON the line and column where it went wrong; CSV and TSV are a table
with the first row as its header, the first 1,000 rows shown; `.txt`,
`.log`, `.md`, YAML, TOML, INI and XML are shown as text. Text over 2 MB,
and kinds with no viewer yet (video, archives), offer the download.
Drawings still open in the Excalidraw editor and whole Meld notes where
the browser decrypts them.

**Archiving or deleting a file.** A file's menu in the tree (right-click,
or a long press) has **Archive…** and **Delete…**, and Delete on the
keyboard asks to archive the highlighted file. Archiving takes it out of
the tree but keeps its bytes, which still count towards the board owner's
storage. Deleting it is for good and gives that storage back; only the
board's owner can delete a file, and a synced copy of your wiki takes its copy away too.

**Over the API.** `GET /api/boards/<board>/files` lists the board's live
files by path (`folder=` keeps to one folder and what is under it), each
with its size, sha256 and the URL it is read from; `GET
/api/boards/<board>/files/<path>` (`Tool/template.docx`) is its bytes,
always as a download (#1156). Both need read on the board, with a token like
the rest of the API. In the CLI they are `slipdock wiki files <board>
[--folder F]` and `slipdock wiki get <board> <path> [--out F|-]`. This is how
an agent reaches a [Tool](tools.md)'s board files.

**What the folder remembers.** `.slipdock/state.json` holds, for each file,
which page it is and the hash both sides last agreed on — never front
matter, so your files stay your own. That is what makes a rename the same
page rather than a delete and a new one.

**One way.** `slipdock sync from-server` brings the server's changes down
and sends nothing: no page written, archived or moved there. `slipdock sync
to-server` is the other half: it sends what changed here and writes nothing
in the folder. Either lists what it left (`· Name.md (not sent)`) as held,
and the folder keeps the version both sides last agreed for each, so the
next pass — one way or both — still finds it waiting. A note changed on
both sides is still a conflict copy under `from-server`, the copy left
unsent; `to-server` touches neither and leaves it for a pass both ways.
Both take `--watch` and `--json`.

**Conflicts.** Every write to the server says which version it was made
against. If a note changed on both sides, the server's version keeps the
name and yours is saved beside it as `Name (conflict 2026-10-12 laptop).md`
— and synced too, so nothing lives only on one machine. Merge it into the
note and delete the copy; `sync status` lists the ones left.

**Deletes.** Deleting a file archives its page (restore it from the wiki's
archive); it is never purged. A page archived on the server is removed from
the folder, unless you had edited it there, in which case your edit goes
back up as a new page. A folder made on the server is made in the folder,
empty or not, and one deleted on the server is removed from it once nothing
but empty folders is left inside — anything else in it (a dot file, a
note you have just written there) keeps it.

**What is left alone.** `.obsidian/`, `.trash/`, every other dot folder and
file, and the temporary and swap files editors write while saving. Add your
own in `.slipdockignore` at the folder's root, one gitignore-style pattern a
line (`*.pdf`, `Private/`, `drafts/*.md`).

**Watching.** `--watch` looks at the folder every second and sends a change
once the folder has been still for two seconds, so an editor that saves
through a temporary file has finished. It asks the server's change feed
every ten seconds (`--interval`), and passes anyway every ten minutes.
`sync service install` sets that up as a systemd user service on Linux, a
launchd agent on macOS or a logon task on Windows (`print` shows what it
would write; `uninstall` takes it away).

**One sync per folder.** It replaces Obsidian Sync rather than running
beside it. `sync` warns when Obsidian Sync, Dropbox, iCloud Drive,
OneDrive, Google Drive or Syncthing seems to be syncing the same folder:
two of them undo each other's changes and make conflicts out of nothing.

### Importing an Obsidian vault

An Obsidian vault (the folder Obsidian opens) you already have comes in once
with `slipdock wiki import`, and then the same folder carries on as a synced
mirror:

```sh
slipdock wiki import ~/Obsidian --dry-run   # what would happen; nothing is written
slipdock wiki import ~/Obsidian             # do it
slipdock sync init ~/Obsidian               # then keep it level, both ways
```

Each path goes to the board whose folder holds it (the deepest one
wins), each note becomes a page and every other file — images, PDFs,
drawings, `.canvas` — a file at the same path. A note goes up byte for
byte: its front matter (key order, quoting and comments), tags, aliases and
links, an Excalidraw drawing's `.excalidraw.md`, and Meld's ciphertext,
which is never decrypted. What the import leaves out, it says: whatever
sync leaves alone (`.obsidian/`, `.trash/`, `.slipdockignore`), paths in no
board's folder, files over 250 MB, and paths your wiki already has — the
same bytes count as already there, anything else is listed and left as it
is, never overwritten.

The dry run also reads every note's `[[links]]`, `![[embeds]]` and local
Markdown links, and lists those that would find nothing — by Obsidian's
rules, against the folder and what is already in your wiki: a bare name
finds a note or file of that name anywhere, `Folder/Note` one whose path
ends that way, and an alias counts as a name. It lists what only an
Obsidian plugin draws (Dataview, Tasks, Templater, a Kanban board, a
Canvas), which comes across as the text it is. `--all` shows every line of
a long list, `--json` all of it.

The folder's files are not touched. The import remembers what each became in
`.slipdock/import.json`, so running it again sends only what is new.

**Then sync.** Stop Obsidian Sync (or whatever else syncs the folder) first,
then `slipdock sync init` the same folder. It adopts what the import sent
rather than sending it again: a note still as it was imported takes the
wiki's copy of itself (the same note, perhaps with a `title` key the server
added), a note edited since goes up to the page it became, and one edited on
both sides is a conflict like any other. Nothing is archived or removed by
adopting: a file deleted since comes back down, and one whose page was
archived goes up again. Once a pass has come through without an error the
import record is spent and removed.

### Meeting recordings from Google Drive

A recorded meeting can be one page: the summary, a `## Recording`
section, and the transcript in a ```` ```vtt ```` block under
`## Transcript` (the format is below, in
[Meeting transcripts: what Slipdock expects](#meeting-transcripts-what-slipdock-expects)).
The recording stays on Google Drive and is never
copied here. The page names it in its front matter, as
`recording: gdrive:<path from My Drive>`.

A ```` ```vtt ```` block reads as the conversation, the same as a `.vtt`
file. With a recording, a bar sits under **Recording** and stays in view
as you scroll. It has play, ±10 s, a scrubber and 0.75×–2× speed. The line
being spoken is highlighted and kept in view; scroll away and it stops
following until you press **Follow**. Click a line to play from there. The
search box marks the lines that match (Enter steps through them). While
you're not typing, space plays and pauses, ← and → skip 10 seconds, and
[ and ] change the speed. Moments tagged while recording, written in the
summary as `Tags: #important (0:05) #action (12:40)`, show as chips inline
in the transcript where they were pressed, and the tags in that line become
links to them; click either to play from there.
The **▶ Play recording and transcript** link in
the page jumps to the bar and starts it. Nothing is fetched from Drive
until you press play.

**Naming a voice.** When a transcriber couldn't tell who was speaking and
wrote `Speaker 1`, `Speaker 2`, anyone who can edit the page can click a
speaker's name in the transcript, type who it was and press Enter (Escape
leaves it as it was). The name changes in every line that voice speaks, in
every ```` ```vtt ```` block on the page, and the change is saved as a page
revision, so History shows it and can undo it. Giving a voice the name of
someone already there makes them one speaker, for when the transcriber split
one person in two. A name is up to 60 characters, without `<`, `>` or a
colon. Agents and the CLI do the same by editing the `<v Name>` tags in the
page's body. Where an admin has **Teach it voices** on, naming a voice in the
player also sends that person's longest stretch from the recording to the
transcription server as a voiceprint (*Teaching it voices* under [Recordings](links-and-goals.md#recordings)
has the detail); editing the tags by hand doesn't.

To make it play:

1. **Connect Google Drive** on **Account → Preferences** (read-only). The
   section is only there when the server has a Google client (see
   [Google Drive, for meeting recordings](google-drive-for-meeting-recordings.md)).
2. **Set your wiki's recordings folder** on Wiki settings (e.g.
   `Meeting Recordings`), or `slipdock wiki set --recordings-folder
   "Meeting Recordings"`. The recordings are streamed through the wiki
   owner's connection, for anyone who can read the page, and only files
   under that folder will play. `slipdock drive status` shows where you
   stand.

If a recording won't play, the bar says why: see
[Why it won't play](#why-it-wont-play) below.

#### Meeting transcripts: what Slipdock expects

This is the contract for whatever records and transcribes your meetings: a
recorder app, a script, a transcription service. Write a page like this and
it plays. Nothing here is specific to one tool.

**One Markdown page per meeting**, in this order:

1. The summary, written however you like. Moments tagged while recording go
   on one line, `Tags: #important (0:05) #action (12:40)` (each a `#tag` and
   `m:ss`, or `h:mm:ss` from an hour). Each shows as a chip in the
   transcript where it was pressed, and as a link to it in this line.
2. `## Recording`, holding the line `[▶ Play recording and transcript](#recording)`.
   Leave the whole section out when there is no audio.
3. `## Transcript`, holding the transcript.

**Front matter:**

````markdown
---
title: "Weekly sync: budget"
date: 2026-09-16T12:08:42+01:00
type: meeting
recording: "gdrive:Meeting Recordings/2026-09/2026-09-16 12.08.42 weekly-sync.m4a"
recording_drive_id: 1AbCdEf…   # optional
recording_duration: 3725.4     # optional, seconds
participants: [Me, Alice]      # optional
tags: [budget]                 # optional
---
````

- `title`, `date` (ISO 8601 with its UTC offset) and `type: meeting`.
- `recording: gdrive:<path>`, the audio's path **from the root of My
  Drive**. If your uploader's "root" is really a subfolder (an rclone remote
  with `root_folder_id`, say), put that folder's path in front.
- `recording_drive_id` (the Drive file id) is only an optimisation: without
  it Slipdock finds the file by its path. Add it once the upload has landed.
- Don't write `code`, `slug`, `status` or `updated`: Slipdock owns them.
- Quote any value that YAML would misread, such as a title with `:` or `#`.

**The transcript** is the whole WebVTT file inside a fenced code block
whose info string is `vtt`:

````markdown
## Transcript

```vtt
WEBVTT

NOTE
Transcribed automatically

1
00:00:01.500 --> 00:00:03.250
<v Alice>Shall we start?

2
00:00:04.000 --> 00:00:06.000
<v Bob>Yes.
```
````

- Every cue needs its timing line (`start --> end`, `hh:mm:ss.mmm` or
  `mm:ss.mmm`). The cue numbers are optional.
- Speakers are `<v Name>` voice tags; a `Name: ` at the start of the text
  works too. Cues in a row from one speaker read as one turn, and each
  speaker keeps a colour. Without either, the lines are shown untitled, in
  time order, and still play and highlight.
- `NOTE` blocks are skipped. A transcript with no cue that has words shows
  "No speech detected." when it says `NOTE No speech detected.`, and "No
  transcript." otherwise.
- Text in cues is shown as text, never HTML (`&amp;` and the like are
  decoded).
- If any line of the VTT starts with three backticks, fence the block with
  four (or more), so it can't close early.

**The audio** stays on Google Drive and is never uploaded to Slipdock, which
streams it from Drive when someone presses play. It has to be audio
(`audio/*`; an `.m4a` that Drive labels `video/mp4` is fine too) and inside
the wiki's recordings folder. Write MP4s with their index at the front
("faststart", `moov` before `mdat`; `ffmpeg -movflags +faststart`), so
playback starts and seeks without fetching the end of the file first.

**How the page gets in**, either way:

- **Through your wiki's folder.** Write the `.md` file into a local folder
  that `slipdock sync` keeps level with your wiki (see
  [Syncing your wiki to a folder](#syncing-your-wiki-to-a-folder)). It arrives
  like any other note.
- **Over the API**, with a write token:
  `PUT /api/wiki/sync/pages` with `{"path": "Meetings/2026-09-16
  weekly-sync.md", "content": "<the whole file>"}`. The answer has the page's
  `id` and `hash`. To add `recording_drive_id` later, `PUT
  /api/wiki/sync/pages/<id>` with the new content and `"base":
  "<hash>"`. A `409` means the page changed meanwhile, and carries it as it
  now stands: add your front-matter key to *that* content and send it again,
  rather than overwriting it. Keep sends that failed in an outbox and retry
  them later.

**Old-style notes**, with a separate `.vtt` file or a play link of the
recorder's own, are left exactly as they are, and don't get the player.

**Playing it outside the browser.** A client holding an API token gets the
audio from `GET /api/pages/:id/recording`, where `:id` is the page's id, its
code or `board-code/slug` (with the `/` written `%2F`):

```sh
curl -H "Authorization: Bearer $TOKEN" -H "Range: bytes=0-1048575" \
  https://your-server/api/pages/W-31/recording -o part.m4a
```

- It streams from Drive as the web player does: `Range` is passed on and the
  answer is 200 or 206 with `Content-Range`, so a player can seek. Nothing is
  stored on the server.
- The rule is the web player's too: **read on the board**. A page shared with
  someone outside the board answers 404, as does a page they can't read, an
  archived page, and a draft, unless they can edit the board.
- A read-only token may play. A token limited to other boards gets a `403`.
- A missing or revoked token gets a `401`.
- A strict `Accept: audio/mp4` gets a `406`, because this is a JSON API route
  and refusals are JSON. Send `Accept: */*` or leave the header out.
- A refusal is a status and a JSON `reason`, the codes in the table below:
  `409` for `not_connected`, `revoked`, `no_folder` and `no_vault`, `403` for
  `outside_folder` and `not_audio`, `404` for `not_found` and `no_recording`,
  `502` for `unavailable`.

#### Why it won't play

The bar names the problem:

| It says | Fix |
| --- | --- |
| Google Drive isn't set up on this server (`not_configured`) | The admin sets `GOOGLE_CLIENT_ID`/`SECRET` ([Google Drive, for meeting recordings](google-drive-for-meeting-recordings.md)). |
| Google Drive isn't connected (`not_connected`) | The wiki's owner connects Drive on **Account → Preferences**. |
| Drive access was revoked (`revoked`) | Connect again on **Account → Preferences** (weekly, in Google's Testing mode). |
| No recordings folder set (`no_folder`) | The wiki's owner sets it in Wiki settings, or `slipdock wiki set --recordings-folder PATH`. |
| This page is in nobody's wiki (`no_vault`) | Its board has no owner; give it one. |
| Not in the wiki's recordings folder (`outside_folder`) | Move the file under that folder, or fix the `recording:` path (from the root of My Drive). |
| That file isn't audio (`not_audio`) | Point `recording:` at the audio, not a video or document. |
| Recording not found on Drive (`not_found`) | The path or `recording_drive_id` is wrong, or the upload hasn't landed yet. |

### Encrypted notes

A note can hold an encrypted passage, written in the format of
[Meld Encrypt](https://github.com/meld-cp/obsidian-encrypt), the Obsidian
plugin. Obsidian, on a synced copy of your wiki, opens Slipdock's, and Slipdock opens Meld's
(every version Meld has written). Encrypting and decrypting happen in your
browser or on your machine, and the passphrase and the plain text never
reach the server.

- **Reading.** An encrypted passage shows as a locked chip with its hint.
  Select it and enter the passphrase, and the text appears in place. It
  locks again after five minutes, when you press *Lock*, or when you leave
  the page or reload. *Remember for this session* keeps the passphrase in
  the tab's memory, so the next passage opens without asking. Nothing
  decrypted can be turned into a card. A whole encrypted note (`.mdenc`)
  opens the same way from the tree.
- **Writing.** The encryption actions are in the editor's `⋯` menu, beside
  Preview; on a page that already holds encrypted text they stand in that
  row instead. *Encrypt* with nothing selected opens a box
  where you type the secret, the passphrase twice and an optional hint.
  Only the encrypted block goes into the page, so the secret is never saved
  or sent. With text selected, *Encrypt* encrypts the selection, and
  *Encrypt whole note* does the whole body as one block. *Decrypt to edit*
  opens the block under the cursor so you can change it, and saves it
  encrypted again with the same passphrase. *Remove encryption* puts the
  plain text back, after asking.
- **History.** Text that was on the page before you encrypted it is still in
  the page's earlier revisions, and the editor says how many. The board's
  owner can choose *Purge them when I save*. Only those revisions are
  deleted, the page as saved is kept, and the purge is written in the
  board's activity. It is the one exception to "nothing is lost to a save".
- **Search** never sees the ciphertext. Listings show 🔒 in its place, and
  the tree marks a page holding some with a lock.
- **CLI.** `slipdock page encrypt <page> [--section S] [--hint H]
  [--purge-history]` and `slipdock page decrypt <page> [--section S]
  [--in-place]` do the same on your machine. They ask for the passphrase, or
  read it from `--passphrase-file` or `$SLIPDOCK_MELD_PASSPHRASE`.

### Drawings

Drawings made with Obsidian's [Excalidraw](https://github.com/zsviczian/obsidian-excalidraw-plugin)
plugin are drawn in the page. Both of its files work: a `.excalidraw.md` note
(compressed or not), which is a page, and a plain `.excalidraw` file, which
is kept with the wiki's other files.

- **Viewing.** `![[Plan.excalidraw]]` or `![[Plan.excalidraw.md]]` shows a
  preview of the drawing where it is written; select it to open the drawing.
  A drawing's own page shows the drawing rather than the plugin's Markdown.
  The preview is drawn by the server with clean lines rather than
  Excalidraw's hand-drawn ones, in the fonts your computer has, and a
  dark-theme drawing is shown dark. Images the drawing holds are drawn too.
- **Editing.** *Edit drawing* on a drawing's page (or selecting a `.excalidraw`
  file in the tree) opens it in Excalidraw itself, the same editor as the
  plugin's. There is no Save button: the drawing saves itself a couple of
  seconds after you stop, and the corner says *Saving…*, *Saved* or
  *Reconnecting…*. Ctrl+S saves at once. The drawing is saved in the format
  it came in — a compressed note stays compressed, its text list is brought
  up to date, and anything else in the note is kept — so the plugin goes on
  opening it. People who can only read the board can open a drawing to look
  round, but not change it. *Edit Markdown* is still there for fixing the
  note by hand.
- **Drawing together.** When two people (or two of your tabs) have the same
  drawing open, each sees what the other draws as it is drawn — whether they
  reached it through the board or through a share. The header shows who is
  there, each in a colour of their own (faded, and marked *viewing*, for
  someone who can only look), and their pointers and selections move on the
  canvas, named, in that colour. Pointers are never saved. Each shape is merged the
  way Excalidraw's own collaboration merges it: if two people change the same
  shape at once, the later change to it wins; nothing else either of them
  drew is lost. A burst of drawing is one entry in the page's history, put
  down to whoever drew last and naming everybody who drew in it. If the
  connection drops, the editor says so, and sends everything it has when it
  is back. A change that arrives another way while the drawing is open — a
  sync from Obsidian, an agent or the API — is merged in the same way
  and shows up in the editor; if it isn't a drawing at all, the editor warns
  you, the change is kept in the page's history, and your next stroke saves
  the drawing back.
- **Search.** A drawing note is found by the words in it: its text, and any
  prose written above the drawing. Its listing shows them too. (A plain
  `.excalidraw` file is not searched; files in the wiki aren't yet.)
- **New drawing.** *New drawing* in a folder's menu in the tree makes an
  empty drawing there, named the way the plugin names one, and opens it in
  the editor.

---

← [Machines](machines.md) · [Contents](../manual.md) · [Moving boards between servers](moving-boards-between-servers.md) →
