# A bug card

Part of the `slipdock-loop` skill: read when the card reports a bug or a flaky test, before
building a fix.

## A bug: reproduce what was reported

A bug card is fixed when the person who reported it would now see it fixed,
not when a test you wrote passes. So before building a fix:

- **First, has it been fixed since?** A flaky test or a bug report names
  a file, a test or a path, and when it failed. Before reproducing, fetch
  and look at what the default branch has done to it since:
  `git fetch origin && git log --oneline --since="<when it failed>"
  origin/<default-branch> -- <the file or path>`. A commit there may
  already be the fix (another card's): read it first, and check whether
  the failure still happens on the default branch's head before writing a
  fix of your own. Your branch can be behind it, so rebase onto it before
  you start.
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
