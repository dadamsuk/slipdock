# Waiting for the build

Part of the `slipdock-loop` skill: step 7.4 of `SKILL.md`, read after a push to
a branch CI builds. On a board that ships by pull request the build to watch
is the pull request's instead (`SKILL.md`, **Verified work**). Step numbers
are `SKILL.md`'s.

4. **Wait for the build — for the pass's top-level card only.** A build takes
   minutes, and an epic's subcards would each sit idle through one. So:
   - **A subcard** does not wait. Its `Build started` comment is enough: go to
     step 5 and close it. Its build is checked before the next subcard starts
     (step 5, in `references/subcards.md`). Its wrap-up
     says `CI: started — <workflow> #<run-id> <run url> (checked before the
     epic closes)`.
   - **The top-level card** — the epic, once every subcard is done, or a card
     with no subcards — waits for the build of the last push, as below. A green
     build of the last push covers every subcard pushed before it, since CI
     tests the whole tree; it is what lets the epic close.

   Waiting:
   ```sh
   gh run watch <run-id> --exit-status --interval 10 > /dev/null
   ```
   Use `--interval 10` and drop the output: the default redraws every 3 seconds
   and fills the context, and with the output dropped a shorter interval
   costs nothing and reports the result sooner. **Run it in the foreground**, with the longest timeout
   the tool allows; if that runs out first, run the same command again, until
   the build has finished or ~30 minutes have gone by. Never run the watch in
   the background and end your turn to wait for it: a pass is often run
   headless (`claude -p` from cron), and there the session exits the moment the
   turn ends, taking the watch with it. The notification never comes, and the
   card is left in progress with `Build started` as its last word. When the
   build finishes, comment on the card whichever way it went:
   - **Passed:** `Build passed: <workflow> #<run-id> in <duration> — <run url>`.
     Go to step 5.
   - **Failed:** `Build failed: <workflow> #<run-id> — job <job>, step <step>`,
     followed by the few lines of `gh run view <run-id> --log-failed` that show
     the cause, and the url. The card is not done. Fix it as part of this card
     (on an epic whose subcard broke it, as a `Build failed` subcard filed as in
     step 5): reproduce locally if you can, commit with the card id again, push, and go
     back to step 3, so the card gets a new `Build started` comment and a new
     result. After **two** failed fix attempts, or a failure that is clearly
     outside this card's change (infrastructure, secrets, a flaky external
     service), stop. Hand the card back as **Blocked** (`SKILL.md`, **Handing a card back**), with the
     failing run linked in the comment.
   - **Cancelled, or still running after ~30 minutes:** comment that it was
     cancelled or is still running, with the url, and close the card anyway.
     The next pass's CI check (step 2a) catches it if it later fails.
