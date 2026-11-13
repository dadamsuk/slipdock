**Shipping by pull request** (`ship_via: "pull_request"`, said on the
board's line). Never push the default branch: push a branch named
`card-<id>` and open a pull request from it (`gh pr create`, the card id
in its title), and complete the card with the pull request's URL in
`evidence_pr` and its head commit in `evidence_commit` (`slipdock done
ID --pr URL --evidence-commit SHA`, `complete_card` `pr` and `commit`):
the merge needs both, so a board asking for evidence refuses the
completion without the PR, and a PR without its commit, a resubmission
after a rejection too (`422`). **An epic** (a card whose sub-board holds cards)
has no pull request of its own to name: each subcard ships and merges
its own. Once they are all accepted and merged, complete the epic
without `--pr` (`slipdock done ID --evidence -`, the evidence on
stdin as lines: a line per subcard's PR, a line for the last merged
build), and accepting it completes it with nothing to
merge (so does one naming a pull request a subcard already merged).
Only work done on the epic itself goes on its own branch, with a pull
request named by `--pr`, which the acceptance merges. **A card that
changes no code** (a sweep, a handbook reconcile, a card that only
reads and files) has no branch and no pull request, and never a token
one: complete it with why in `evidence_no_code` (`slipdock done ID
--no-code "<why>" --evidence -`, what you did on stdin as lines,
`complete_card` `no_code`), never beside `--pr` (`422`). The verifier judges the claim
against the card's ask instead of checking out a commit, and accepting
it completes it with nothing to merge. The build to watch is the
pull request's (`gh pr checks <branch> --watch --fail-fast`), and it is
the full test run: before pushing, run the tests you added or changed
and the project's own pre-push checks (what its `CLAUDE.md`,
contributing guide or handbook lists; else formatting and a compile
that fails on warnings), not the whole suite, and complete the card
once its checks pass (with no checks on it, run
the suite yourself). A verifier doesn't run the suite again either: it
reads the change and checks that the pull request's head is the
submitted commit and its checks passed. A rejected card's next attempt pushes the same branch,
so the same pull request updates. A claimed job's prompt and the
card's `shipping` (in `get_card`) say all this for the card in hand.
**A card tagged `security`** gets a neutral pull request (`shipping`
has `neutral: true`): the title `Maintenance (#<id>)` rather than the
card's, `--body "Card #<id>."` rather than `--fill`, and commits, title
and body that say what changed in general terms, never the hole, an
exploit or the affected endpoints. The detail stays on the card until
the fix is deployed; the closing comment may link it after that.
Don't merge it: accepting the card sets `verify_state: "merging"` and
queues a `merge` job for a runner (one idle now first, else the one
that accepted it), and the merge completes the card
(its `merge_sha`). A failed merge sends it back rejected, the merge's
reason as the rejection: rebase the branch and complete it again.
A pull request already merged at the accepted commit completes the
card with that merge commit; one merged at another head leaves it
merging and says which head, and neither counts as a rejection. A
person can say they merged it by hand (`verify_card` `merged`).
