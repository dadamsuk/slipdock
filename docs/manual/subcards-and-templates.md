[Slipdock — the manual](../manual.md)

## Subcards and templates

Open a card and click **Add subcards** in the Subcards section, then pick a
template. The card gets a **sub-board**: a real board with the template's
lists, named after the card and sharing the parent's colour. Everything a
board can do works inside it — drag and drop, swimlanes, saved views, the
API and the CLI — and sub-boards nest to any depth. The card modal shows the
subcards grouped by list with a progress bar, lets you tick them off and add
them from one row (the title, then the list it goes in),
and its line under the title (*Board › List · #id · created*) has the one
**Open board** link, with how many are done; the card itself carries a `done/total`
badge. The sub-board's header shows a breadcrumb back through every parent.

Tags are shared by a whole board tree: they live on the root board, so a tag
created on a sub-board is available everywhere under that root. Renaming a
card renames its sub-board. Deleting a card, or **Remove subcards**, deletes
the sub-board and everything on it, files included: the attachments of every
card beneath it, its wiki pages' images and its meeting recordings are removed
from disk, as are those of every card when a list is deleted with its cards.
The board index lists root boards only.

**Templates** are named lists of columns (name, optional WIP limit, colour).
Seven ship by default (Slipdock, Simple, Checklist, Bug triage, Research,
Roadmap — Now · Next · Later · Done, for the top of a tree — and Sprint
planning, below); manage them at `/templates`, pick one when creating a
board, or save any board's current lists as a template from its settings.

The ones that ship are **built in**: everybody sees them and nobody, an
admin included, can change or delete them. A template you make — at
`/templates`, from a board's settings, or by saving a new board's lists —
is **yours**: only you see it in a picker, and only you can edit or delete
it. Its name has to be new among your own templates and the built-in ones;
somebody else may have one called the same. Deleting an account deletes
that person's templates (boards already made from them keep their lists).

Or set the lists out when you create the board: pick **Custom lists…** in
the **Lists** menu and type them one per line. A list named like To Do, In
Progress or Done is given that role (the rest can be set in the board's
settings); tick **Save these lists as a template** to keep them for next
time, under a name of your own or the board's. A template name that is
already taken stops the board being made too, so you can pick another.

---

← [Incidents](incidents.md) · [Contents](../manual.md) · [Simple boards](simple-boards.md) →
