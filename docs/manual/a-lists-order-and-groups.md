[Slipdock — the manual](../manual.md)

## A list's order and groups

A list draws its cards in the order they were dragged into. **List settings
→ Order** gives it an order of its own instead:

- **Sort by** — *Created*, *Last updated*, *Start date*, *Due date* or
  *Priority*, with a **Direction**: earliest / lowest first, or latest /
  highest first. Cards without the date go last either way; cards that tie
  keep their dragged order between them. A start date sorts as the card's
  start, or its due date when it has no start.
- **Group by** — *Flags*, *Tags*, *Start date* or *Due date*, each group
  under a small heading with its count; groups with nothing in them are left
  out. Flags and tags go in their usual order (the board's tag order), and a
  card with several is drawn once, under the first of them. Dates group
  relative to today: *Overdue* (or *Started*), *Today*, *This week*, *Next
  week*, *Later*, and *No date*.

Sorting is only how the list is drawn. A sorted list keeps itself in order,
so dragging inside it has nothing to rearrange — cards still drag in from
and out to other lists. The dragged order is kept underneath and comes back
when the list is set to *Board order* again. A grouped list that is not
sorted can still be arranged by hand within each group. A small icon by the
list's name says when it has an order of its own; hover it for which.

Filters still apply, inside each group. From the command line and the API:

```sh
slipdock set-column slipdock "To Do" --sort due_date --group flag
slipdock set-column slipdock "To Do" --sort priority --descending
slipdock set-column slipdock "To Do" --sort position --group none   # back to the default
```

A list's JSON carries `sort_by`, `sort_dir` and `group_by` (`PATCH
/api/boards/:board/columns/:id` sets them). The cards in it keep their
`position`, which is still what "the top of the list" means to an agent.

---

← [At the foot of every list](at-the-foot-of-every-list.md) · [Contents](../manual.md) · [Quick add](quick-add.md) →
