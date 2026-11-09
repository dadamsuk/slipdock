[Slipdock — the manual](../manual.md)

## Dependencies

Open a card and use the **Dependencies** section: pick *Blocked by* or
*Blocks*, search for another card, and click it. The search covers every
board you can open, this one's cards first; a card on another board shows that
board's code, here and in the list of dependencies. So a subcard can wait on a
subcard of another epic, or on a card on a different board altogether. You need
to be able to edit the card that waits and to see the one it waits for. A card
is *blocked* while any card it depends on is open (not completed, not
archived); blocked cards show a red lock badge with the count, and cards that
hold others up show an arrow badge. Self-links and anything that would form a
cycle, across however many boards, are refused. Removing a card removes its
links. Somebody who can see one end of a dependency but not the other sees
*A card you can't see* in its place: the card still counts as blocked, but its
title and board stay private. Each board's history records the dependency, and
names the card on the other board only by number.

When the last open card a card depends on is completed or archived, the card
**unblocks itself**: if it is flagged *blocked* the flag comes off, with a
comment naming the card that freed it, so it goes back into the ready list
(runners, *take the top card* rules and agents working the board all pass over
a flagged card). Flag it again if it is still waiting on something else. An
automation can start from the same moment: the trigger *a card's last blocker
is done* (`card_unblocked`) — to move the card back to the top of the list,
say, or tell whoever owns it.

---

← [The overseer](the-overseer.md) · [Contents](../manual.md) · [Incidents](incidents.md) →
