[Slipdock — the manual](../manual.md)

## Calendar

The **Calendar** button shows a month (or, from the span menu, a week) with
each card on its due date — or its start date when it has no due date. Drag a
card to another day to reschedule it (a card with both dates keeps its length);
drag it into the *No date* tray to clear its dates. Each chip starts with
the card's title; its flags and priority (bar medium) show once a day is wide enough
(about 15rem), and its tag dots and done tick on wider days still, so a
month at an ordinary window width shows titles only. Point at a chip for the
full title, its dates, priority (bar medium), flags and tags. The *+* on a day adds a
card due that day, and *+N more* expands a busy day. Filters, search, sort and
saved views work as in the other views.

### Moving a card between lists

Dragging is the quick way with a mouse, and was the only way — which on a
phone meant dragging a card across a board showing one list at a time. Two
other routes now do the same job at any size:

- The **→** button on a card (hover on a desktop, always there on a touch
  screen) opens a **Move to** menu of the board's lists. It is a native
  popover, drawn above the list's own scrollbox rather than clipped by it.
- The line directly under the card's title in the card modal
  (*Board › List · #id*) has the list as a picker. It is the only one: the
  sidebar holds the card's other properties.

### Moving a card to another board

Dragging cannot cross a board — the other board is not on the screen — so the
only way there used to be to retype the card and delete the original, losing
its comments, its history and its subcards. **Another board…** at the foot of
the **Move to** menu, and next to **in list** on an open card, opens a picker:
the boards you can write to, then that board's lists. Two taps on a desktop
and the same two on a phone, where the picker is full screen and stands in for
the card while it is open.

What crosses with the card:

- **Subcards, comments, history, checklists, attachments, dependencies and
  links** — all of it, however deep the subcards go. The boards beneath the
  card are re-rooted so their own tags and fields keep resolving.
- **Tags travel by name**, matched on the destination board and created there
  when they are new — for the card and everything under it, because a
  subcard's tags came from the old board too.
- **Custom field values** survive where the destination has a field with the
  same key *and* kind, and are dropped where it does not: a number cannot be
  stored in a date. A **pinned milestone** is unpinned — it is a date on the
  old board's roadmap and stays there.

The flash afterwards says what any of that cost, and both boards record the
move in their activity. Landing in a *done* list completes the card, and a
horizon list schedules it, exactly as a move within one board does. A card
cannot be moved into its own subcards, and an archived card has to be restored
first.

### Changing several cards at once

**Select** in the board view's toolbar turns on select mode. Clicking a card
then picks it out — a ring and a tick — instead of opening it; clicking it
again lets go. To pick out many at once:

- **Shift-click** a card to pick every card from the last one you clicked to
  this one, in the order the board shows them: down a list, then across to
  the next. Cards already picked out stay picked. With nothing clicked yet,
  or when the last card clicked is no longer shown (a filter hides it), a
  shift-click picks just the one card. **Clear**, **Done** and every change
  from the bar start afresh.
- **The tick in a list's header** picks every card the list shows; pressed
  again, once they are all picked, it lets them all go. Cards the filters
  hide, snoozed cards and stand-ins are left out.

A bar along the bottom counts what is picked out and changes all of it in
one go:

- **Complete**, **Reopen**, **Assign me**, **Unassign**, **Archive** and
  **Delete** (which asks first: it cannot be undone).
- **Set…** — add or remove a tag, set the priority, add or remove a flag.
- **Move to…** — any list on this board, or on another board you can write
  to, with everything a single move carries (see above).

Each card is changed as it would be one at a time, so automations, history
and search see every change. One card refusing — a move into its own
subcards, a full account — does not stop the others; the flash names it and
says why. **Done** leaves select mode. From a terminal, `slipdock archive`,
`restore`, `delete`, `done` and `undone` already take several card ids.

---

← [Timeline](timeline.md) · [Contents](../manual.md) · [Time tracking](time-tracking.md) →
