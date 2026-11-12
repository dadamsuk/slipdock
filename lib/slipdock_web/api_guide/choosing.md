
## Choosing what to do next

Depth first, from the top. Unless the person told you which card to work
on, this is how to pick one.

**1. Pick the board.** `GET /api/boards`. If more than one could plausibly
be meant, ask instead of guessing.

**2. Read it whole.** `GET /api/boards/<id>` returns every list, in order,
with its `category` and its cards in list order — one call, everything you
need to choose. Snoozed cards are not in it: they are not ready until the
day they wake. If `paused` is set, take nothing and stop.

**3. Pick the list to draw from,** in this order:

a. a `doing` list that already holds an unfinished card — work in progress
   is finished before new work is started;
b. the **ready** list: the `todo` list that means "ready now" (*To Do*,
   *Now*, *Ready*, *Selected*, *Next*);
c. the **backlog**: any other `todo` list (*Backlog*, *Later*, *Icebox*),
   and only when (b) has nothing eligible.

Ignore `done` and `dropped` lists. A board with one `todo` list makes this
trivial. Older boards often carry no categories at all — then go by name and
position, left to right; the last section of this guide has already worked
that out for each of your boards. Ask if it is genuinely unclear.

**4. Drop the ineligible.** From that list's cards, discard any where:

- `completed` is true, or `archived_at` is set;
- `blocked` is true, or any `blocked_by` entry is neither `completed` nor
  `archived` — the thing it waits for is still open;
- `flags` contain `blocked` or `waiting` — somebody has said by hand that
  this is not ready;
- `assignees` has someone else on it, unless you were asked to pick their
  work up — or to pair on it.

**5. Order what is left.** Highest priority first
(`<%= @priority_order %>`), then `position`
ascending — the top of the list wins a tie, because that is where the person
who owns the board put the next thing. Two exceptions worth respecting: a
card already overdue (`due_date` today or past) outranks priority, and a
card that `blocks` several others is worth doing before its peers.

**6. Descend before you move on.** If the card you picked has a `sub_board`,
it is an epic: `GET /api/boards/<sub_board.id>` and run steps 3–6 again
inside it. Keep descending until you reach a card with `sub_board: null` —
that leaf is the task you actually do. Then work *that epic's* remaining
subcards to done before going back up for the next top-level card. An epic
with no sub-board and no obvious single action is a sign it needs breaking
up (see above), not a sign to improvise.

**7. Nothing eligible?** Say so, and say why — everything done, everything
blocked on X, the backlog is empty — and stop. Do not invent work, and do
not take a card you ruled out in step 4 because it was the only one left.

A first pass in one call, with the obvious exclusions applied:

```sh
curl -s -H "Authorization: Bearer $SLIPDOCK_TOKEN" <%= @base %>/api/boards/1 | jq '
  [ .board.columns[]
    | select(.category == "doing" or .category == "todo")
    | {list: .name, category, position,
       cards: [ .cards[]
         | select(.completed == false and .blocked == false
                  and (.flags | index("blocked")) == null
                  and (.flags | index("waiting")) == null)
         | {id, title, priority, position, due: .due_date,
            epic: (.sub_board.id // null)} ] } ]'
```

Order the handful that come back yourself — it is a short list and the
tie-breaks above need judgement.
