# A card with subcards

Part of the `slipdock-loop` skill: read when the card has subcards (an epic),
before working any of them. Step numbers are `SKILL.md`'s.

## 5. Subcards before the parent

`slipdock card <id>` shows `Subcards: board #N · done/total · lists` when the card
is an epic. Then `slipdock board N` lists them, and every command works on that
sub-board as on any other.

Work the sub-board the same way this pass works the main one — top of its ready
list first, each subcard claimed, commented and closed on its own — and do not
come back up for a new top-level card until they are all done. Subcards can nest;
the rule repeats at each level. Work discovered along the way goes **under the
epic as a new subcard**, never as a new top-level card, and never silently into
the one you are doing.

A subcard is closed without waiting for its build (step 7.4), so **before
claiming the next subcard, look at the latest build on the branch** — once,
without waiting:

```sh
gh run list --branch <branch> --limit 1 --json databaseId,status,conclusion,headSha,url
```

Still running, or passed: carry on. Failed: the subcard whose commit it is
broke it, and the fix comes first. That subcard is done, and the board
refuses an agent reopening a done card, so the fix is a new subcard under the
same epic, on top of its ready list:

```sh
slipdock add <sub-board> "Build failed: #<id> <title>" --column "To Do" \
  --desc "<run, failing job and step, the few telling lines, the url>"   # or --desc - and a heredoc, as in 2a
slipdock move <new-id> "To Do" --top
slipdock link <new-id> relates <id>
slipdock comment <id> "Build failed: <workflow> #<run-id> — fixed on #<new-id>"
```

Claim it, fix it, commit with its id, push, and close it the same way. The
two-attempts rule and **Blocked** apply as they do in step 7.4.

Subcards can be built side by side by subagents, one each. **Wait for every
subagent you started before your turn ends.** In print mode (`claude -p`, as
a runner runs it) the run ends when the turn does, and its subagents are
stopped with their builds half done. Don't end the turn to be told they have
finished: wait for them in it. The same goes for each subagent's own work, so
**every subagent's brief tells it to run everything in the foreground**: its
tests, `mix pre_push` or the project's checks, and its CI watch. A subagent
that starts a background run and ends its turn to wait for it never wakes in
a runner's job, and its subcard is left half built. When they are done, each
subcard is finished and closed, or handed back (`SKILL.md`, **Handing a card back**) with a handoff saying
where its build got to.

The parent closes last, when its rollup shows every child done and the build
of the last push is green (step 7.4: it waits for that build), with a comment
summarising the set rather than repeating each child's write-up. Subcards can
be added while you work, so list the sub-board again just before. The board
refuses an agent closing (or submitting) a card while a subcard is open — not
done and not archived; one awaiting verification counts as finished — and the
refusal names them: finish them, or archive the ones that don't belong. Nor
can an agent reopen a done card (untick it, or move it out of Done): if one
needs more, add a card for that and link it.
