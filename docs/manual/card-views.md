[Slipdock — the manual](../manual.md)

## Card views

A card view is what you see of a card: each element of its front (cover,
tags, due date, the handoff note and the rest), each section of the opened
card, and each property and group of its sidebar (assignees, priority, the
dates, health, who created and last changed it, time, votes and the rest).
Card views are yours alone, and kept on
the server, so they follow you to every browser; nobody else's cards change.

They come in three levels, each above the one before: **global** (every
board), a **board**, and one **list** on it. Below them all are the built-in
defaults. A level states only the elements it changes, each one *Inherit*,
*Show* or *Hide*, and everything else comes from the level below. So hide
comments globally, show them on one board, and hide them again on that
board's Done list.

A **named card view** is a set of elements you can apply at any level (the
level's **Apply** select), with the level's own choices on top. **Save**
makes one from what the level shows now; a named view can be renamed and
deleted, and a level that applied a deleted one keeps its own choices. A
saved view can name one of yours too (Display → *Card view for this view*,
or `card_view=NAME` in the URL); while that view is open it sits above the
list level. Saved views are shared and card views are not, so someone
without a card view of that name sees their own levels.

Open the editor from the Display menu's **Card views…** (the board's level),
**Card view…** in a list's `⋯` menu (that list's), or **Edit card views** in
your account settings, or go to `/card-views` for the global level
(`?board=B`, `?board=B&list=L`, `?view=ID` for a named one). Its two tabs are
the **Card front** and the **Opened card** (its sections, and its sidebar's
properties and groups).
Each element says whether it is shown and which level decided it; a sample
card shows the front, and the opened card's sections are marked on or off.
**Inherit all** clears a level. Deleting a named view says how many levels
applied it; they inherit instead.

A hidden section that needs you doesn't vanish without a word: when your
card view hides a rejected verification or a question waiting on a person,
the opened card says so at the top, and **Show them** shows the hidden
sections on that card.

The list level applies on the board and swimlanes views; the timeline,
calendar and outline use the board's level. The board's own settings always
win: a [simple board](simple-boards.md)'s hidden fields and a list's own *time
in list* and *front image* switches stay off whatever a card view says, so a
card view can only hide more. **Show all**, in the Display menu, is yours
for one board: while it is on, every element of the card front shows there
(not the ones the board hides), and off again puts your card views back.

The handoff note is two elements: *Handoff note (2 lines)* puts the next step
and the start of the note on an open card's front, *Handoff note in full* all
of it. Both are off until you show them. Agents' output (the API, MCP, the
CLI) never follows card views.

From the command line, `slipdock card-views` lists yours (`--elements` lists
every element and its default), `slipdock card-view new|show|edit|rm` works
the named ones, `slipdock card-view level|set|clear [--board B] [--list L]`
a level (`set --apply VIEW|none --show a,b --hide c --inherit d --reset
--show-all on|off`), and `slipdock card-view applied --board B [--list L]
[--view SAVEDVIEW]` says what applies and why. Over the API they are
`/api/card-views` (below); over MCP, the `card_views` tool.

---

← [Swimlanes](swimlanes.md) · [Contents](../manual.md) · [Table](table.md) →
