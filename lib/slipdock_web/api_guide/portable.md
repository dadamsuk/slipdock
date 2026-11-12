
## Moving boards between servers

```sh
curl -s -H "$H" B/api/export                         # every tree you own
curl -s -H "$H" "B/api/export?boards=del,ops"        # just these
curl -s -H "$H" "B/api/export?archived=all"          # and what is put away
curl -s -X POST -H "$H" -H 'content-type: application/json' \
     B/api/import -d @boards.json
```

One JSON document holding whole board trees: lists, cards, subcards, tags,
checklists, comments, status updates, web links, custom fields and their
values, what waits on what, and the wiki. `slipdock export [<board>...]
[--out FILE]` and `slipdock import <file.json>` on a shell.

**This is not the wiki export above.** That one writes Markdown, for
reading your writing somewhere else; this one moves a board, and only this
one can be read back into a board.

Three things to know before using it.

**It only ever carries boards you own.** A board shared with you is
somebody else's to hand on. Asking for one by name is a 403.

**An import never merges.** A document always becomes *new* boards, even
when a board of that name is already here — deciding per card whether "the
same card" means the same title is how an import quietly destroys work. A
board code that is taken is reissued (`del` → `del-2`) and the answer says
so. So importing the same file twice gives two copies, which is a fact
about the tool rather than a bug to work around.

**Automation rules do not fire on an import.** Four hundred cards arriving
would otherwise run every rule four hundred times. An import is history
arriving, not things happening.

**A document is checked before anything is built.** A body may be at most
8 MB (the Account page's upload too); a sub-board may be claimed by one card
only and never be the root; and no one kind of row — lists, folders,
checklist items, comments and so on — may run past
<%= @max_rows %> in a tree. Any of those is a 422 and nothing
is imported.

What a document does **not** hold, each for a reason: attachments (bytes
rather than structure — they stay on the server they were uploaded to),
votes (a person's budget spent, which means nothing on another server),
wiki page history and activity (a record of one server's past, which
another cannot honestly adopt), and public share tokens (a secret that
would otherwise be valid in two places). `leaving_behind` in the export
response says how much of each was left, and says nothing when there was
nothing.

Two things cannot travel verbatim and are handled rather than ignored.
Page codes (`W-31`) are unique across a server, so imported pages get
fresh ones — and `[[W-31]]` inside the imported bodies is rewritten to the
code that page now has, so a wiki still links to itself. A board's
shortcut key is also server-wide, so it does not come with the document.

One thing genuinely does not survive: `#412` written inside a **page body**
points at a card id on the server the document came from, and there is
nothing in the document to match it against. Card-to-card links and
dependencies *are* preserved — those travel as refs — but a card id typed
into prose is not. A dependency on a card in another board tree (one not
under the same root) cannot travel as a ref: the export's warnings count
them, and an import drops any whose other card is not in the file and
says how many.

People travel as email addresses, because an id from another server names
nobody. An imported board is yours alone until you share it, and a card
is only ever assigned to somebody who can open it, so everybody but you
lands unassigned and is named in the answer ("… can't see this board
yet") — the same words whether or not they have an account here — rather
than failing the import on the last card. Status updates are signed as
you, with their original author written into the text.

The card limit is answered once, for the whole document, before anything is
built: a file that will not fit is refused outright rather than stopping
half way.

### From Trello

`POST /api/import` (and `slipdock import`) also takes a **Trello board's
JSON export** as it is — recognised by its shape, or named with
`?from=trello` (`--from trello`); an unknown `from` is a 422 rather than a
guess. The answer carries `"source": "trello"`. Open lists, cards (archived
ones archived), labels as tags, checklists, comments, dates and attachments
as web links come across; a list named like *Done* or *Doing* gets that
category. Members do **not**: Trello's export has no email addresses, so
cards arrive unassigned and `skipped` says so — tell the person rather than
assigning anyone yourself. Archived lists and custom fields stay behind,
and are named in `skipped` too. The rules above — new boards only, no rules
firing, the limit answered first — apply unchanged.
