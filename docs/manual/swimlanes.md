[Slipdock — the manual](../manual.md)

## Swimlanes

The **Swimlanes** button in a board's header switches to a grid view. Every
setting lives in the URL, so a configured grid can be bookmarked or shared.

- **Rows / Columns** — the attribute on each axis: none, list, priority, tag,
  flag, status (open/completed), cover colour, due date, created, last updated.
  Cards with several tags or flags appear in each matching group.
- **Dates** — when either axis is a date, group by days, weeks, months,
  quarters or years. The bucket containing today is marked *now*; past due-date
  buckets are tinted red.
- **Sort** — board order, title, priority, due date, created or last updated,
  ascending or descending, inside each cell. Cards without a value (no due
  date) always sort last.
- **Filter** — search, kind (cards / documents / wiki pages), tags,
  priorities, flags, lists, due (overdue / today / next 7 days / next 30 days /
  has a date / no date), status (all / hide completed / only completed), cover
  colour.
- **Display** — comfortable or compact cards; show empty groups (which also
  fills gaps between date buckets); **List width** — narrow, normal, wide or
  extra wide. The board view's Display menu has the same *List width*, which
  sets how wide every list is drawn (on a phone a list still fills the
  screen). Like the rest of the Display menu it is kept in the URL and in a
  saved view. What a card shows is not in the menu: it is your
  [card views](card-views.md), which **Card views…** opens. **Show all** beside it
  shows every element on the cards' fronts while it is on.

  Your browser also remembers the Display options you last chose for each
  board and each view (board, table, timeline and so on), so leaving the
  board and coming back to its plain address brings them back. They are kept
  in this browser only: another browser or device starts from the defaults.
  A link that names its own display options, and a saved view, use theirs
  instead. Filters are not remembered, and nor is what a card shows: your
  card views are kept on the server, so they follow you to every browser.

  Until you choose otherwise, a card shows only what you need at a glance:
  its tags, title, assignee, due date, priority (high, critical and low;
  medium is the unremarkable middle and stays off the front), flags,
  subcard and checklist progress, and what blocks it, plus its cover and
  image. Show the rest in your card views (start date, % complete, time
  tracked, a description mark, comments, attachments, time in list, ID). A card
  showing both dates draws them as one range, *31 Oct → 5 Nov*. **ID** puts
  the card's number (*#1856*) in the top-right corner of its front, in a
  lighter font than the title.
  Priority is drawn as signal bars everywhere it appears (the card, the
  outline, the table, the calendar and the filter menu): one bar lit for
  low, two for medium, three for high, all four for critical; point at
  them for the name. Point at a start date and it says when in words,
  *Starts in 11 days* or *Started 11 days late* (when the subcards began
  after it), and the card's panel says the same under *Start*. Plain facts
  are plain text; only what needs attention is tinted: overdue, due soon,
  blocked, flagged, waiting on someone. A saved view can name a card view
  of yours (Display → *Card view for this view*), which applies while it is open.
- **Drag and drop** between cells changes the card to match the target cell:
  its list, priority, status, colour or due date (set to the start of the
  bucket), or swaps the source tag/flag for the target one. Created / updated
  axes can't be dragged into. In *board order* a drop between two cards also
  reorders them. A card that has left the cell you dragged it from since your
  tab drew the grid (a runner moved it to Done while a phone slept, say, or
  someone changed its priority or took a tag off) stays as it is now, and the
  grid tells you and redraws.
- **Add** inside a cell creates a card with that cell's attributes.
- Click a row header to collapse it.
- **Dependencies** — an axis with Blocked / Blocks others / No dependencies
  groups, and a filter (blocked, not blocked, blocks others, none). Cards are
  moved between these by editing the card, not by dragging.
- **Views** — save the current configuration under a name. Loading a view puts
  `?view=ID` in the URL; any further change is shown as *modified* with
  *Update* / *Revert* buttons, and only the delta is added to the URL. Views can
  be renamed and deleted from the same menu.

The grid and saved views are also available over the API and CLI (`slipdock swimlanes`, below).

---

← [Getting Started](getting-started.md) · [Contents](../manual.md) · [Card views](card-views.md) →
