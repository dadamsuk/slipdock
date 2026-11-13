# Shipping by pull request

Part of the `slipdock-loop` skill: read when the board ships by pull request
and the prompt doesn't give the steps, and for what a job's prompt leaves
out: an epic, a card that changes no code, a `security` card's pull request,
a held card and a failed merge. Step numbers are `SKILL.md`'s.

- **Shipping by pull request** (`ships by pull request` on the board's
  line; the claimed job's prompt and `slipdock card` say so too, under
  *Ships by pull request*). Step 7 changes: **never push the default
  branch.** Commit on the branch `card-<id>` (switch to it if it is on
  origin already: a rejected card's next attempt pushes the same branch, so
  the same pull request updates), rebase it on the default branch, `git
  push -u origin card-<id>`, and open the pull request once: `gh pr create
  --head card-<id> --title "<card title> (#<id>)" --fill`, unless `gh pr
  view card-<id>` shows one open. The build to watch (step 7.3, 7.4) is
  the pull request's: `gh pr checks card-<id> --watch --fail-fast`, so a
  failed check is seen when it fails, not when the slowest one ends. It is
  the full test run: before pushing, run only the tests you added or
  changed and the project's own pre-push checks (what its `CLAUDE.md`,
  contributing guide or handbook lists, often one command that runs what
  CI checks; with none listed, formatting and a compile that fails on
  warnings), never the whole suite as well, and complete the card once
  the checks pass. Complete with
  `slipdock done <id> --pr <url> --evidence-commit <PR head sha>` beside
  the other evidence: the PR merges at that commit, so one without it is
  refused, a resubmission after a rejection too. Don't merge
  it: accepting the card has a runner merge it (the card shows *merging*
  until then, and the merge completes it). On a board with profiles on, a
  `schema` or `security` card an agent accepts is *held* first:
  a person merges it or sends it back, rejected with their reason, which
  is the next brief like any rejection. A `docs` card there gets no
  verify job: the server accepts it on your evidence's suite (give CI's
  result as `--suite`), so a failing suite sends it back. Give the change
  with the completion there (`--diff-base origin/<default branch>`, or
  `complete_card` `changed_lines` and `changed_files`): a migration, a
  security path or a large diff raises the card's profile, never lowers
  it. **An epic** has no pull
  request of its own: each subcard ships and merges its own. Once they are
  all accepted and merged, complete the epic without `--pr` (`slipdock
  done <id> --evidence "<the subcards' PRs, the last merged build>"`);
  accepting it completes it with nothing to merge. Never name a subcard's
  merged PR, and never open a token PR to have one: only work done on the
  epic itself gets `card-<id>` and a `--pr`. **A card that changes no
  code** (a sweep, a handbook reconcile, a card that only reads and
  files) has no branch and no PR either, and never a token one: complete
  it with `slipdock done <id> --no-code "<why>" --evidence "<what you
  did>"` (`complete_card` `no_code`), and accepting it merges nothing.
  A merge that fails sends the
  card back rejected, the merge's reason as the rejection: rebase
  `card-<id>` on the default branch, push, and complete it again. A PR
  already merged at the accepted commit isn't a failure: it completes the
  card with that merge commit. One merged at another head leaves the card
  merging, says which head, and isn't a rejection either.
  **A card tagged `security`** ships a neutral pull request, because the
  repository may be public and the PR is readable before the fix deploys:
  the title `Maintenance (#<id>)`, not the card's, `--body "Card #<id>."`
  instead of `--fill`, and commit messages, title and body that say what
  changed in general terms ("Tighten access checks in board events"),
  never the hole, how to exploit it or which endpoints it hit. The detail
  stays on the card; after the deploy, the closing comment may link it.
  The prompt and `slipdock card` (`security: a neutral PR`) say so.
