[Slipdock — the manual](../manual.md)

## Simple boards

Not every board is a project. A shopping list, a household to-do list or a
reading list has no use for start dates and health, and a card that offers
them all is a card that looks harder to fill in than it is. Tick **Simple
board** in a board's settings and it becomes a plain to-do list:

* the card leaves out **% complete**, **start date** and date precision, the
  dates rolled up from subcards, **health** and health reports, **time
  tracking**, **votes** and **Dependencies**;
* tiles drop the matching badges, and the **Display** menu stops offering
  them;
* the view menu leaves out **Timeline** and **Prioritise**.

What stays is what a to-do list needs: the title and description, the list,
assignees, priority, the due date, Completed, flags, tags, the checklist,
attachments, subcards, docs, links, comments, the cover and any custom
fields. Nothing is deleted — a card that had a start date still has it, and
unticking the setting brings everything back. Subcards made on a simple
board are simple too; each board keeps its own setting after that. From the
command line it is `slipdock set-board <board> --simple` (or `--no-simple`),
and over the API `PATCH /api/boards/:board {"simple": true}`.

---

← [Subcards and templates](subcards-and-templates.md) · [Contents](../manual.md) · [A board's default view](a-boards-default-view.md) →
