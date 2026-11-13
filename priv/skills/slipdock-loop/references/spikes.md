# A spike

Part of the `slipdock-loop` skill: read when the card is a spike, before
building. Judging one is in `verifying.md`.

- **A spike** (tagged or profiled `spike`, on any board; the prompt says
  *This card is a spike*) answers its bar's question by building, and its
  code is never merged. Spend one sitting. Build the prototype on
  `card-<id>` and push it so the evidence can point at it, but never open
  a pull request (close any you opened) and never push the default
  branch. Write the answer as a page pinned to the epic (`slipdock page
  new <board> "Spike: <the question>" --card <epic>`): the question, the
  answer or *inconclusive*, the evidence (numbers, logs, the branch and
  commit, not claims) and what the answer changes in the plan. Then
  complete it with `slipdock done <id> --no-code "spike: answer on W-…,
  prototype on card-<id>" --evidence "…"`, with the `Findings:` block:
  naming a PR is refused, and accepting it merges nothing. *Inconclusive,
  with what was learned* is a finished spike; a guess is not. A spike
  holds no lane, so it needs no paths. When the last spike under an epic
  is accepted, the server opens a `product` wait on the epic to resume
  planning: that is a person's, not yours.
