[Slipdock — the manual](../manual.md)

## A board's default view

A board opens on its kanban, but not every board is mostly looked at that
way. A board that is really a handbook wants its **Wiki** first; a backlog
might want its **Table**. Pick **Default view** in a board's settings —
Board, Swimlanes, Table, Timeline, Calendar, Outline, Narrative, Prioritise
or Wiki — and opening the board from the board list, the board switcher
(<kbd>b</kbd>) or Favourites lands there. The view menu still reaches every
view, and the board's own address (`/boards/:id`) still shows the kanban.
A simple board has no Timeline or Prioritise, so if it was set to one of
those it opens on the board until simple is turned off again. Only a
top-level board has the setting: a sub-board is opened from its card. From
the command line it is `slipdock set-board <board> --default-view wiki`, and
over the API `PATCH /api/boards/:board {"default_view": "wiki"}`; a board's
JSON reports `default_view` (`"board"` when none is chosen).

---

← [Simple boards](simple-boards.md) · [Contents](../manual.md) · [Sprints](sprints.md) →
