[Slipdock — the manual](../manual.md)

## Right now

What is happening on a board's tree at this moment, on one page: the board's
**Right now** page (`/boards/:id/now`). On a board with
[Agentic Building](the-header-and-the-avatar-menu.md#agentic-building) on it is one click from the board page:
the pulse line (*2 in progress · 1 waiting · …*) opens it, and with the pulse
off a line of its own says what is on (*1 runner working · 2 cards in
progress · 1 queued*) and opens it. The delivery line under it (the rocket)
opens the long-term numbers, the Visualise view, once there are deploys.
The Agentic Building page has a
*Right now* tile too: the runners working, with the cards in progress and the
jobs queued under it.

The page covers the board's whole tree (its root and every sub-board, since
runners take work from all of it), read again every few seconds:

- **Runners**: each one at work, online or not, and the jobs it holds now,
  with the card, how long since it was claimed and the latest step its agent
  reported.
- **In progress**: every open card in an in-progress list (a list with the
  *In progress* category, or with no category and a name that says so, like
  the Simple template's *Doing*),
  and every card a runner is building (a claimed or running job other than
  a verify, merge, overseer or probe job), wherever it sits, so a card whose agent never moved it
  still shows, marked *Not in a doing list* (`in_doing: false` in the API and
  MCP, *(not a doing list)* after its list in `slipdock now`). Longest there
  first, with where it sits (the board and list, and the epic
  whose sub-board holds it), its state line (*Building · Mac Studio · 7m*,
  *Waiting on Dana*), the runner loop holding it, and what holds it: waiting
  on a person, verifying, merging, blocked, in review or stuck (red: the
  health monitor's flag, an incident for a person). A card held by none of
  those but longer in its list than usual says so in amber, *Past usual
  stay*, as its tile's age chip does.
- **Queued**: the jobs waiting for a runner, oldest first, each with its pool
  and why it is held, if something holds it (a pause, a full WIP limit, a lane,
  no runner online).
- **Idle runners**, at the bottom of the page: the runners holding no job,
  online or not, so the working ones lead it. A runner that takes a job moves
  up into **Runners** the next time the page is read.

Anyone who can read the board and its tree's root board can look; it changes
nothing. The same snapshot from the CLI, the API and MCP:

```
slipdock now <board>           the counts, then each runner at work with its jobs'
                               steps, the cards in progress (where each sits, its
                               state, what holds it, the runner on it, how long),
                               the queue and, last, the idle runners
slipdock now <board> --json    the API's JSON, as it is
GET /api/boards/:board/now     runners (each with its jobs), in_progress, queued, counts
```

MCP: `get_board` with `now: true`.

---

← [The health monitor](the-health-monitor.md) · [Contents](../manual.md) · [The overseer](the-overseer.md) →
