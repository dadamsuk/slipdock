[Slipdock — the manual](../manual.md)

## Quick add

The table and outline views have a one-line add row: type a title, press
Enter, and the input is ready for the next card. Commands mixed into the
line are recognised as you type and shown as chips:

- `due: tomorrow`, `start: next mon`, `by friday`, `due: in 2 weeks`,
  `due: 1 oct`, `due: 2026-10-01`, `+3d`, `eow`, `eom`
- `#high` (a priority), `#blocked` (a flag), `#todo` or `#in-progress`
  (a list), `#docs` (a tag) — matched loosely, in that order
- `@dan` (an assignee, by name or email prefix)
- `every: mon`, `every: weekday`, `every: 2w`, `every: month 1`,
  `every: month last fri`, `every: 3d after` — makes the card
  [recurring](recurring-cards.md). Here and in the header's quick add
- `snooze: mon`, `snooze: next week`, `snooze: 2026-11-02` — adds the card
  [snoozed](snoozing-cards.md) until then (the same dates as `due:`). Here and
  in the header's quick add
- `; seen on Safari only` — everything after the first semicolon becomes
  the card's first comment, as written (commands in it are not read). This
  works in a list's own "Add a card" box and in the header's quick add too

Anything not recognised stays in the title. In a grouped table each group
has its own row and new cards take the group's value; in the outline the
**+** beside a card opens an "Add a subcard" row beneath it.

### From the header, in plain English

The **Quick add…** box in the header bar of every page (or the `q` key)
opens the same one-line form, wherever you are. It puts the card on your
default board and list — set them under *Quick add* on Account ›
*Settings*,
otherwise it is the first list of the first board you can write to.

With an OpenRouter key configured the line is read by the model as well
(`SLIPDOCK_AI_QUICK_MODEL` picks a cheaper or faster one than the rest of
the AI features use), so it takes prose rather than syntax:

    call the printers about the banners friday, urgent, waiting on them
    draft the Q1 plan on the Marketing board, start monday, #docs, @dan

Dates, priority, flags, tags, the assignee, and the board and list when
the line names one, all come out of it; what it understood is shown as
chips beside the card it made, with a link to open it. Only boards you
can write to, and their own lists and tags, can be chosen — a name the
model invents is dropped rather than created. If the model is off (the
checkbox on Account › *Preferences*) or unreachable, the typed syntax above is
still read, and the card still goes in.

The code lives in `Slipdock.QuickAdd.Capture` (the catalogue of what may be
picked, matching names back to rows, writing the card),
`Slipdock.QuickAdd.Model` (the one model call) and `SlipdockWeb.QuickAddHook`
(the header box on every authenticated page).

---

← [A list's order and groups](a-lists-order-and-groups.md) · [Contents](../manual.md) · [Emailing your board](emailing-your-board.md) →
