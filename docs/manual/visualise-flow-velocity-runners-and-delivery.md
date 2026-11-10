[Slipdock — the manual](../manual.md)

## Visualise: flow, velocity, runners and delivery

**Visualise**, in the board's view menu beside Timeline and Prioritise (left
out on a simple board), is one scrolling page of how work moves through the
board, how fast it is finished, how its runners are doing and how it
delivers. Anyone who can read the whole board can open it. Nothing is stored:
it is worked out when you open it, and follows the board as it changes.

- **Pulse** — the last 7 days: throughput, cycle time (P50, with P85), idea to
  production (with delivery metrics on), work in progress against the doing
  list's WIP limit (*At limit* when it is reached), open waits on people and
  how long the last one took to answer, and moves in 24 hours forward and back.
- **Flow through the board** — a block per list in board order: cards now, in
  and out over 7 days (archived, for a done list), a fill bar and the usual
  stay. Lists with no category sit apart, *outside the flow*, except one
  whose name says it is in progress (a Simple sub-board's *Doing*): that is
  the doing list, here and in the Pulse, Aging and Trends.
- **Trends** — over 7, 30 or 90 days (the switch at the top; the choice is in
  the link as `?days=`): cumulative flow, velocity (per week at 90 days, with
  a rolling average), backlog burndown (open cards, an even burn to zero and
  the scope added each day) and cycle time (a dot per finished card, on a log
  scale from a minute to a day, with the P50 and P85 lines).
- **Aging work in progress** — each open card in a doing or the ready list,
  oldest first, its age against its list's usual stay; **Work mix** — how many
  done cards carry each tag, and how many carry none.
- **Agentic runners** — each runner's status and current job, queue wait (the
  card coming into the ready list to its job being claimed), job success,
  waits on people, cards reopened and how its jobs ended; then the last 12
  jobs.
- **Quality** — how well agent work goes over the window: the share of cards
  accepted on their first submission (with no rejection, a failed merge
  counting as one unless it found the pull request already merged, and never
  reopened), rejections per accepted card (and how
  many were reopened, and how many are in rework now), runner jobs that timed
  out, failed, were requeued or given up on per 100 finished jobs, and health
  incidents fixed, flagged, cleared and open. Then **rework by area**: each
  accepted card under the handbook page whose `covers:` take in most of its
  lane paths, or *unmapped* (no paths, no page covering them, or no
  handbook), most rejections first. **Rejections** counts the verifiers'
  rejections in the window by what they failed: the ask, the bar, the rules,
  the suite or the `Handbook:` line, from each decision's verdict in parts
  (one given no parts counts the parts its reason cites, `bar 2: …`; one from
  before verdicts were kept in parts, or naming none, counts as naming no
  part). Beside it, the **disputed Handbook lines** and the audits that agreed
  or disagreed, then the **rules most broken**, each with its page.
- **Delivery (DORA)** — with delivery metrics on: the four DORA numbers, each
  with its band on a Low to Elite scale and the elite target, deploys per day,
  and idea to production in its parts (commit to deploy, start to done, card
  to production), with rework rate and commits shipped. It keeps its own 30
  days, and says so.

The history and runner numbers have doors of their own:
`slipdock flow <board> [--days 7|30|90]`, `GET /api/boards/:id/flow?days=`
and MCP `get_board` with `history: true` give the day-by-day series;
`slipdock runner-stats <board> [--days N]`, `GET /api/boards/:id/runner_stats`
and `get_board` with `runners: true` the runner numbers;
`slipdock quality <board> [--days N]` and `GET /api/boards/:id/quality?days=`
the quality numbers (30 days unless given; `--json` for the whole answer).
`slipdock quality <board> --rules` lists every rule broken in the window
rather than the five most broken: the handbook's **Triage findings** card
reads it to find the rules that need clearer wording or a test.

---

← [Flow: the pulse, a card's state and its age](flow-the-pulse-a-cards-state-and-its-age.md) · [Contents](../manual.md) · [Delivery metrics: deploys and DORA](delivery-metrics-deploys-and-dora.md) →
