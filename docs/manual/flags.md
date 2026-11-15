[Slipdock — the manual](../manual.md)

## Flags

A card can carry any of six flags: **flagged**, **blocked**, **needs
review**, **waiting**, **starred** and **stuck**. Each shows on the card's
front and when it is open, and each says who clears it.

### Who clears a flag

A flag on a card is drawn one of two ways, so a glance says whether you need
to do anything about it:

- **Filled**, with a solid icon (and a raised hand on the open card): nothing
  on the board will clear it by itself, so a person has to act.
- **Outline only**, and *clears itself* on the open card: something already in
  motion takes it off.

Hover a flag (or read it with a screen reader) for who clears it. Which way a
flag goes depends on the card:

| Flag | Filled: a person acts | Outline: clears itself |
|---|---|---|
| Waiting | always: a question waits on someone's answer | |
| Flagged | always: put on by hand, taken off by hand | |
| Stuck | always: the health monitor's own fixes ran out | |
| Blocked | blocked on nothing the board tracks | while a blocker card is still open: the board takes it off when that card is done |
| Needs review | flagged by hand; awaiting verification with no verify pool; or accepted and held for a person to merge | awaiting verification on a board with a verify pool (a verifier agent decides), or being merged |
| Starred | neither: a bookmark that asks nothing | |

The API's and MCP's card carries the same answer as `flag_attention`, one
entry per flag (`attention` `person`, `auto` or `none`, and `why`), and
`slipdock card` prints it beside each flag.

---

← [Waiting on a person (waits)](waiting-on-a-person-waits.md) · [Contents](../manual.md) · [Flow: the pulse, a card's state and its age](flow-the-pulse-a-cards-state-and-its-age.md) →
