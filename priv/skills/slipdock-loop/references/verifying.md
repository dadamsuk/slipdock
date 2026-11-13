# Verify jobs and audits

Part of the `slipdock-loop` skill: read when the job is of kind `verify`, or you
are asked to verify or audit a card. A pass that builds reads `SKILL.md`'s
**Verified work** instead; step numbers are `SKILL.md`'s.

- **A verify job** (a job of kind `verify`, or a card you are asked to
  verify) is checking, not doing. Claim nothing, move nothing and change no
  code. Never verify a card you built. Read the bar and the evidence: the
  evidence says where to look, not what to believe, so check each claim in
  it (a test named is read and run, a docs place it says it updated is
  opened). Then
  check out the evidence's commit in a clean tree (`git worktree add
  /tmp/verify-<id> <sha>`, so nothing uncommitted counts). Run the suite
  and what the bar names there, then judge four things in order, and
  decide once:
  1. **The ask:** does the bar cover what the card asks for (its
     description, and any request in the comments)? A bar that leaves part
     out is a rejection, even when the work meets the bar. On a bug, the
     check is *would the reporter now see it fixed?*: a card or evidence
     that says the reported symptom or its cause was never seen ("I
     couldn't tell what…", a cause made up in the test) is a rejection
     (`the ask: the reported symptom was never seen`), however good the
     tests.
  2. **The bar,** each part of it.
  3. **The rules** (a board with a handbook): `git diff --name-only
     $(git merge-base origin/<default> <sha>) <sha> | slipdock handbook
     <board> --paths-from -` lists the rules for the diff. A broken `must`
     is a rejection citing its id; `should` misses go in the accept reason,
     each as a finding in a `Findings:` block there (`- rule: ARCH-6
     missed: <how>`).
     **`SPEC-10` is enumerated, not judged**, when the prompt adds a
     docs-places step (the card's paths fall in the rule's scope): list
     the names the change introduces or alters from the diff, grep them
     across the seven places the step lists, and give each place one
     result in the reason: `updated`, `deferred to #N` (only when card
     #N's bar names that place: `slipdock card N`), `n/a` with why, or
     `missing`. One missing is `--check
     rule:SPEC-10=broken:<file>:<name>`, one line per place and name, all
     in this round; all seven accounted for is `rule:SPEC-10=ok`.
  4. **The `Handbook:` line** (a board with a handbook), in the evidence or
     the closing comment, against the docs gate (step 7.1): no line, `no
     change` on a diff that needed an update, or pages named that weren't
     edited, is a rejection.
  **A spike** is judged on its answer, not a pull request: the answer
  addresses the question its bar asks (the ask); the evidence is real
  (numbers, logs, a branch and commit you can look at, not claims); the
  page says what the answer changes in the plan. *Inconclusive*, with
  what was learned, passes; reject only for not really trying or for an
  answer without evidence, never for the answer being "no". There is no
  PR to check and nothing merges, so run no suite unless the bar asks
  for one. On a board that ships by pull request, don't run the suite: its
  CI ran it at that commit. Read the change and the tests the bar names,
  check that the pull request's head is the evidence's commit and that
  every check passed (wait for any still running; a failed one is a
  rejection naming it), and run the suite only if it has no checks. Say where you are at each step with `slipdock job-progress --step
  "…"` (the job in `$SLIPDOCK_JOB_ID`; MCP `job_progress` `step`), never a
  note: checked out the commit, tests running and their counts (or the
  CI result), judging, the decision. The card stays quiet until you decide: `slipdock verify <id> accept
  --evidence-commit <sha> --reason "what you checked"`, or `slipdock verify
  <id> reject --reason "<the check>: <what falls short, specifically>"`.
  A rejection cites the check it fails: a bar item (`bar 2: …`), the ask
  (`the ask: …`), a rule id (`UX-4: …`) or the Handbook line. **Once a
  rule is broken, name every instance**: look for every other place the
  card could have missed the same break (the same list, the same string,
  the same door; a page list copied across the README, a skill and a help
  page is the usual one) and give each as its own `--check
  rule:UX-4=broken:<file>:<line>[:why]` under the one rule, in this one
  rejection, saying in the reason that you looked (`Every instance:
  searched <where> for <what>; found these N.`). One instance named now
  and the next in another round costs the card a whole rework. A bar item
  that adds, rewords or drops a handbook rule is met by a matching open rule
  proposal (an `edit_section` on that page's `## Rules`; `slipdock garden
  <board> --check proposal`): judge its content, not the live rules, and
  name its id when you accept. Never ask the builder to edit `## Rules`
  directly; ask for the proposal to be filed or corrected. Give the
  verdict in parts too, one `--check` each (MCP `verify_card` `checks`):
  `ask=ok|misses`, `bar:2=ok|fail`, `suite=412:0`, `rule:UX-4=ok|broken|n/a`,
  `handbook_line=ok|disputed`, each with `:"why"` if it needs one. A
  rejection names at least one failing part; an acceptance can't carry one
  (a missed `should` rule aside). A rule broken only in lines the diff
  didn't change is not the builder's: give it as
  `rule:UX-4=pre-existing:<file>:<line>`, never `broken` and never a
  rejection; it is kept as a `rule` finding on the card, and an
  acceptance may carry it. On a `schema` or `security` card (profiles
  on) the prompt adds a defect review: read the diff for bugs, not
  style, and give each finding with its file and line,
  `defect:important|nit|pre-existing=<file>:<line>[:why]`; an important
  one is a rejection, a nit or a pre-existing one is reported only.
  On a `fix`, `feature`, `schema` or `security` card (profiles on; never
  `docs`, `spike` or a `--no-code` completion) the prompt adds a
  **mutation step**: in the clean worktree, pick 3 to 5 of the most
  consequential lines the diff added or changed, and on top of those every
  guard or branch the diff adds (a new condition, clause, pattern match or
  early return), once each and named with its line; break each in turn (flip
  `>` to `>=`, drop the branch, return the wrong thing), run only the
  card's `--tests`, never the whole suite (on a pull request board too:
  CI ran the suite, not the mutations), and restore the line. On a `fix`,
  one mutation undoes the fix: the regression test must kill it. Give
  each as `mutant:killed=<file>:<line>:<mutation>`,
  `mutant:survived=<file>:<line>:<mutation>[:the test that's missing]`
  (a rejection, its reason naming the mutation and the test to write) or
  `mutant:pre-existing=…` (a survivor in lines the diff didn't change:
  reported only, kept as a finding), or `mutants=n/a:<why>` when nothing
  in the diff is worth mutating. You can't decide a card you submitted
  yourself (`403`). **A resubmission** (the prompt says the card was
  judged before, at a commit) is judged on what changed: the parts that
  failed, and any part the commits since touch (`git diff --name-only
  <that commit> <this one>`). A part that passed then and nothing since
  touches is carried (`--check bar:1=carried`, or left out), recorded as
  *carried from <sha>*. Never raise again a part that passed or was fixed;
  flag a class of problem once, with every instance of it you find; a rejection names what changed since the
  last. An audit carries nothing.
- **An audit** (a verify job with `audit: true`, on a card already
  accepted) checks the checker. Judge the work as a verify job does,
  `should` rules too, against the original verdict its prompt shows, then
  `slipdock verify <id> agree --reason "…"` or `disagree --reason "<where
  the verdict is wrong>"` with your own `--check` parts. The docs places
  (`SPEC-10`) are enumerated as in a verify job: one missing, a deferral
  to a card whose bar doesn't name the place included, is a disagreement.
  It changes
  nothing on the card: a disagreement is a comment, an alert for the
  board's owner and a rework card the server files from your reason (its
  first line is the title) and failing parts, or a comment on the one
  still open. So the reason's first line says what is wrong. A verify
  job's prompt on that board then lists the recent misses (*What audits
  on this board caught recently*): check those first. An audit's prompt
  never does, so judge it afresh.
