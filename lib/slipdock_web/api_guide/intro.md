# Slipdock for agents

This is how to drive `<%= @base %>` as your work tracker: the model, the
conventions these boards expect, how to decide what to do next, and what to
write back while you do it. Read it at the start of a session. The board is
what the person who owns it reads afterwards to find out what happened, so
treat keeping it true as part of the work, not as reporting overhead.

Three things, if you remember nothing else:

1. **Top-level cards are epics; the work is in their subcards.** Finish an
   epic's subcards before starting the next epic.
2. **Take work from the top.** The *To Do* list first, the *Backlog* only
   when To Do has nothing eligible; highest priority first, position in the
   list breaking ties; skip anything blocked.
3. **Write as you go.** Move a card to *In Progress* when you start it,
   comment at every decision or surprise, flag it when you are stuck, and on
   finishing set `completed: true` *and* move it to *Done*. A board that
   lags behind the work is worse than no board.
