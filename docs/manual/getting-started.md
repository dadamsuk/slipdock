[Slipdock — the manual](../manual.md)

## Getting Started

The first time an account signs in it gets a board called **Getting Started**,
and lands on it rather than on an index with nothing on it. It is built by
`Slipdock.Onboarding`, and it is both halves of the same job: a new install
that shows a blank page teaches nobody anything, and whatever is put there to
fix that may as well be the tour.

What is on it:

- **A card per feature**, in the To Do list, in the order somebody meets them:
  opening a card, adding one, flags and tags and priorities, dates and the
  eight views, subcards, the wiki, search and Ask, automations, the AI
  assistant, sharing, and the CLI and API. Each says what to try and where it
  is.
- **An epic** — "Break a big job into subcards" — which actually has a board
  of its own, with four subcards, one of them genuinely blocked by another, so
  the roll-up, the breadcrumb and the dependency badge are real rather than
  described.
- **A card in Done**, a card in In Progress carrying a checklist, a comment, a
  flag and dates, and two in the Backlog. Every list has something in it: a
  board with an empty Done column is the one part of a new install that reads
  as broken when it is only new.
- **A working automation** — *when a card lands in Done, comment on it* — on
  the board's Automations tab. It emails nobody and waits on no clock, so the
  first automation anybody sees is one they can trigger in five seconds.
- **Three wiki pages**: *Welcome to your wiki*, pinned to the card that sends
  you there, with two pages nested under it that are the two shapes worth
  having — a decision and a runbook. The welcome page is written in the markup
  it is explaining: `[[links]]`, a wanted link, a `[[!children]]` directive and
  a live ```` ```slipdock ```` query block that answers itself when you read it.

The board is nobody's permanent furniture. The last card says so: archive it
from the board index when the tour is done, which keeps everything on it and,
on a metered server, hands the card allowance back.

**Who gets one.** Somebody who owns no boards. An owner of real boards is not
somebody who needs a tutorial, so that case is skipped.

**Switching it off.** `SLIPDOCK_WELCOME_BOARD=0`. The manual half keeps
working either way:

    mix slipdock.welcome you@example.com [--force]   # from a checkout
    docker compose run --rm slipdock welcome you@example.com [--force]
    slipdock welcome [--force]                       # as yourself, over the API
    curl -s -X POST -H "$H" B/api/boards/welcome

which is also how an account that archived the tour, or one made before the
tour existed, gets one.

---

← [Features](features.md) · [Contents](../manual.md) · [Swimlanes](swimlanes.md) →
