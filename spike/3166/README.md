# Spike #3166: which parts of the runner harness earn their cost

Never merged. The scripts read a snapshot of the `slipdock` board taken
2026-11-14 with the CLI (cards of the board and its 96 sub-boards, and the
jobs of every card touched since 2026-11-03), and count, per harness part,
the cards about it and the job-hours spent on them.

- `harness_cost.py DIR` → `harness_cost.json`: cards and job-hours per part,
  job-hours by kind, merge and audit outcomes.
- `rejections.py DIR` → `rejections.json`: why the verifier rejected,
  bucketed by keyword on the verdict text.

The answer is on the board's wiki page *Spike: which parts of the runner
harness earn their cost*.
