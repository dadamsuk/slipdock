[Slipdock — the manual](../manual.md)

## Moving boards between servers

A board as one JSON file that another Slipdock can read back: its lists, its
cards and their subcards, tags, checklists, comments, status updates, web
links, custom fields and the values cards hold in them, what waits on what,
typed links, and the wiki. **Account → Import & export** has a
picker and a download link; `slipdock export [<board>...] --out boards.json`
and `slipdock import boards.json` do the same from a shell, and
`GET /api/export` / `POST /api/import` are the contract under both.

This is not the wiki's Markdown export above. That one is for reading your
writing somewhere else; this one is for moving a board, and only this one can
be read back into a board. Nor is it `/account/export.zip`, which answers "let
me leave with my data" and is written for a person rather than for a machine.

Three things are worth knowing before you use it.

**It only ever carries boards you own.** A board shared with you is somebody
else's to hand on, and an export that quietly swept it up would be a way to
take a copy of their work off the server.

**An import never merges.** A document always becomes *new* boards, even when
a board of that name is already there. Merging means deciding, per card,
whether "the same card" means the same title — and getting that wrong quietly
destroys work, where a second copy is obvious and can be deleted. A board code
that is taken is reissued (`del` becomes `del-2`) and the answer says so. So
importing the same file twice gives you two copies, by design.

**Automation rules do not fire on an import.** Four hundred cards arriving
would otherwise run every rule on the board four hundred times and email
somebody about each. Rules are about what happens here; an import is history
arriving.

The limits, where a server has them, are answered once for the whole document
before anything is built: the cards and pages it would add, and the boards. A
file that will not fit is refused outright rather than stopping half way and
leaving a part-built board, and so is one that arrives after a free trial has
ended.

### What does not travel, and why

| Left out | Because |
|---|---|
| Attachments | Bytes rather than structure; they stay on the server they were uploaded to |
| Votes | A person's budget spent, which does not mean the same thing elsewhere |
| Wiki page history, activity | A record of one server's past, which another cannot honestly adopt |
| Public share tokens | A secret that would otherwise be valid in two places |

The export says how much of each it left behind — and says nothing when there
was nothing, so a board with no attachments does not warn about attachments.

Two things cannot survive verbatim and are handled rather than ignored. A
page's code (`W-31`) is unique across a whole server, because `[[W-31]]`
resolves with no board behind it, so imported pages are given fresh codes —
and then `[[W-31]]` inside the imported bodies is rewritten to the code that
page now has, so a wiki that comes out still links to itself. A board's
shortcut key is server-wide in the same way, so the importing person picks
their own.

One thing genuinely does not survive: `#412` typed inside a **page body**
points at a card id on the server the file came from, and there is nothing in
the document to match it against. Card-to-card links and dependencies are
preserved — those travel as references within the file — but a card id written
into prose is not.

People travel as email addresses, because a user id from another server names
nobody. An address with no account on the receiving server lands unassigned
and is named in the report, rather than failing the import on the last card
because somebody left.

### From Trello

The same upload, `slipdock import` and `POST /api/import` also read a Trello
board: in Trello, **Menu → Print, export and share → Export as JSON**, and hand
that file in as it is. It is recognised by its shape; `?from=trello` (or
`slipdock import board.json --from trello`) says so outright, and the answer
carries `"source": "trello"`. Everything above still holds — a new board every
time, rules not firing, the limit answered for the whole file first.

| Trello | Here |
|---|---|
| Open lists, in order | Lists — one called *Done*, *Doing*, *To Do* and the like gets that category |
| Cards, archived ones too | Cards, archived ones archived; *due complete*, or being in a done list, is completed |
| Labels | Tags — an unnamed label is named after its colour, and labels sharing a name become one tag |
| Checklists | The card's checklist; several are laid end to end, each item prefixed with its checklist's name |
| Comments | Comments, oldest first, each opening with who wrote it on Trello and the date |
| Attachments | Web links |
| Due and start dates | Due and start dates |

What stays behind, and the answer says so when it applies: **members**,
because Trello's export carries no email addresses to match anybody with, so
cards come in unassigned; **archived lists** and the cards on them, since a
list cannot be put away here and dropping its cards into an open one would
bring back finished work; and **custom fields**. Files uploaded to Trello come
in as links that need a Trello login to open. Trello's own export holds only
the most recent thousand actions, so an old, busy board's oldest comments never
reach the file.

Other tools are meant to follow the same way: each is a small reader that
turns its export into this document (`Slipdock.Importers`), so the rules above
apply to every one of them.

---

← [Wiki](wiki.md) · [Contents](../manual.md) · [Accounts and sharing](accounts-and-sharing.md) →
