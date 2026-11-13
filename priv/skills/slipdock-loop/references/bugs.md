# A bug card

Part of the `slipdock-loop` skill: read when the card reports a bug, before
building a fix.

## A bug: reproduce what was reported

A bug card is fixed when the person who reported it would now see it fixed,
not when a test you wrote passes. So before building a fix:

- **Post the *Picked up* comment first**, then reproduce, and post the
  repro as **its own comment** (`**Reproduced.**` or `**Not reproduced.**`):
  the screen, the size or data, the steps, and what you saw.
- **Reproduced means the reported symptom, on the reporter's scenario**:
  the screen, control and size the card names, showing what the card says
  goes wrong. Something else that fails nearby is not it.
- **A clean repro that doesn't show it means ask, never make one.** Don't
  add conditions (a wider element, odd data, another size) until something
  fails, and never fix a cause you invented. Open a wait (`--kind other`,
  or `ux` for a screen) that says what you tried and what you saw, and asks
  for a screenshot or the steps: which screen, which control, which size.
  Then hand the card back as in **Handing a card back**.
- **A UI bug with no screenshot or steps**, whose symptom you couldn't see,
  gets them asked for the same way, before any work starts.
