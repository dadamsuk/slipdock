[Slipdock — the manual](../manual.md)

## Snoozing cards

Most open cards on a board that lives for years are not actionable *this
week*: they are waiting for a date, a person or a quarter. **Snooze** hides a
card until a day, then brings it back at the top of its list.

**Snoozing.** On the card, under **Snooze**, press **Snooze…** — or on the
board press `z` over a card (the one the keyboard is on, else the one under
the pointer, else labels to pick one). The picker offers **Tomorrow** (`z`),
**Next Monday** (`m`), **In a week** (`w`) and **Next month** (`n`), so `z z`
snoozes until tomorrow; or pick a day of your own, add a note ("waiting for
the vendor's quote"), and tick **Tell me when it wakes**. A day means
midnight in your timezone. A card in an in-progress list is offered a move
back to the ready list as it goes, and one due before the day you pick says
so, with *past due* against the presets that would sleep through it. In
select mode, **Snooze…** snoozes every card picked out. A completed card
can't be snoozed.

**While it sleeps** it is left out of:

- the board's lists — each list's foot says *💤 3 snoozed*, and clicking it
  shows them in place, faded, with the day each wakes, until you hide them
  again;
- swimlanes, the table and the outline, unless you turn on **Show snoozed**
  in the view's display options (saved with a view, like the rest);
- My work, the runners' pick from the top of a list, `--deps ready`, and
  the agents' guide's "open" counts, which show "snoozed N" instead;
- the stale, due-soon, overdue and starts-soon automation triggers: an
  overdue card that is snoozed is a deliberate choice, not news.

It still appears in search (marked 💤 with the day it wakes), on the calendar
and the timeline by its own dates (faded), on its own link, and in roll-ups —
a snoozed subcard still counts as open, so an epic is never done because its
remaining work is asleep. A sprint shows its snoozed cards: a sprint is a
deliberate commitment.

**Waking.** On the day, the server's clock (once a minute) clears the snooze,
moves the card to the top of its list and writes "woke up (snoozed by Ann on
Tue 3 Nov: waiting for the vendor's quote)" in the activity log; with **Tell
me when it wakes**, an alert goes up on the board too. **Wake now** on the
card wakes it by hand. It also wakes when **someone else** comments on it or
assigns it to someone new — a snoozed card people are talking about is no
longer asleep (the API's `wake_on_activity: false` keeps it asleep). An
automation can start from it: the trigger *a snoozed card wakes up*
(`card_woken`). Archiving a card clears its snooze, and an export to another
server keeps one that is still ahead.

From a terminal and over the API:

```sh
slipdock snooze 12 next week --note "waiting for the quote"   # or 2026-11-02, mon, in 3 days
slipdock snooze 12 13 14 tomorrow --notify
slipdock wake 12
slipdock cards ops --snoozed only                              # or include
```

```
POST   /api/cards/:id/snooze   {"until": "2026-11-02", "note": "…", "notify": true, "wake_on_activity": true}
DELETE /api/cards/:id/snooze
GET    /api/boards/:board/cards?snoozed=exclude|include|only
```

A card's JSON carries `snoozed_until` and `snooze` (until, note, who, when,
notify, wake_on_activity), both `null` when it isn't snoozed. Over MCP,
`get_card` shows it, `update_card` takes `snoozed_until` (a date, datetime or
phrase; `null` wakes it) and `snooze_note`, and `list_cards` takes `snoozed`.
Quick add takes `snooze: mon`.

---

← [Recurring cards](recurring-cards.md) · [Contents](../manual.md) · [Tidying up](tidying-up.md) →
