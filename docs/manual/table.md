[Slipdock — the manual](../manual.md)

## Table

The **Table** button shows one row per card. Click a header to sort by it
(again to flip the direction), choose which columns to show under
**Display** (list, priority, assignee, flags, tags, due, done, checklist,
comments, dependencies, subcards, cover, created, updated, id; title, list,
priority, assignee, tags, due and done to start with), and pick **Group by**
to split the rows into collapsible groups by any attribute, including date
buckets. List, priority, start and due dates, % complete, cover colour,
done and custom fields are edited in place: at rest a
cell reads as plain text, and its control (the select's caret, the date's
calendar and clear) appears when you point at the row or Tab to the cell.
Tab moves through the editable cells row by row. Due is one date coloured
by its state (overdue, due soon, done); a card with no due date of its own
shows its subcards' latest in muted italics. Tags stay on one line, the
first two and *+N*, with every tag in the tooltip, so rows are all one
height. On a phone the stacked rows keep their controls showing. The title
opens the card; to rename it without opening, point at the row and click
the pencil beside it, type, and press Enter or click away (a blank title is
refused). Assignees, tags and flags are picked the same way: point at the
row and click the button in the cell (a pencil, or *+* when it is empty) to
open the list of the board's people, its tags or the flags, and click each
one to put it on the card or take it off; the list stays open while you
pick several. A wiki page placed on the board takes one assignee. The
derived columns (checklist, comments, dependencies, subcards, health,
votes, time, created, updated) only show their values. The filter menu, search, density and saved views are shared
with the swimlane view, and a saved view remembers which of the two it was
made in. `slipdock table <board>` prints the same thing in the terminal.

**Arranging the columns.** *Display* lists the columns in the order the
table draws them: drag one by its grip (or focus the grip and press ↑ or
↓) to move it, and tick or untick it to show or hide it. The title is one of them: it can
go anywhere, or be hidden (with every column unticked the table still shows
the title). Drag the right edge of a heading to make the column wider or
narrower (←/→ when the edge has focus); double-click it to put the column
back to its own width. The order and widths are part of the view, like the
filters: they are in the link, a saved view keeps them, and comfortable and
compact tables each have their own. The CSV export follows the order.

**Custom fields as columns.** Each of the board's custom fields can be a
column (*Display*), and a writer edits its values in place, as on the card.
Whoever may change the board's fields (a writer of the tree's top board,
as in board settings) has a **+** at the end of the header. It opens the
field editor board settings' Fields tab uses: a name, a type (Text unless
you pick another) and that type's settings, such as a choice's options or
a number's least and most. The field is added as a column with its first
cell ready to type in. A formula is set up on the Fields tab.

---

← [Card views](card-views.md) · [Contents](../manual.md) · [Timeline](timeline.md) →
