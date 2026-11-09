[Slipdock — the manual](../manual.md)

## Runners

A rule's **Send to runner** action (`runner` in a spec) sends a card to a
coding agent on a machine of your own. It queues a **job** for a **pool**
of runners; a runner of that pool, on the same board tree, takes it, runs
the agent, and reports how it went. What happens to the card after that,
through verification and CI to the deploy, is the help page **How work
flows** (`/help/agents/flow`).

```json
{"type": "runner", "pool": "default", "kind": "claude",
 "prompt": "optional — by default the card's number, title, link and description"}
```

The prompt may use the same `{{card.*}}` placeholders as any action. Every
job's prompt, a rule's own included, ends with a paragraph saying it runs
unattended: nobody will answer questions, so choose inputs from the card and
say what was chosen, or open a [wait](waiting-on-a-person-waits.md) saying what is
needed and stop (the answer starts a fresh job); if the board is paused, finish
the card and take no other. A claimed job's prompt then adds what the card
carries: its bar, its [paths](lanes.md) (naming the ones shared on the board) and,
on a board whose lanes advise, a *Lanes* block naming each card in progress
whose paths overlap. The
**Send cards to a runner** preset is the usual rule (it is offered once the
board has a runner): when a card
arrives in a list, send it to a pool. It and *Work a list with a runner*
both take an optional **Prompt** (#1156), the action's `prompt`; left blank,
the job gets the card's title, link and description.

**Working a list in order.** *Send cards to a runner* fires as cards arrive,
so cards already in the list are never sent and the queue runs oldest job
first. To have a runner work a list the way a person would — top card first,
one at a time — use the **Work a list with a runner** preset (or *the top
card of …, one at a time* in **Connect a runner**). Its trigger is
`list_top`:

```json
{"trigger": {"type": "list_top", "column": "To Do", "unassigned": true},
 "actions": [{"type": "runner", "pool": "loop"}]}
```

Whenever nothing the rule queued is still open, it sends the top open card
of the list, in the list's order, skipping cards that are completed,
archived, stand-ins, waiting on an unfinished card or flagged `blocked` or
`waiting` — and, with `unassigned: true`, cards somebody has taken — plus
any the rule's conditions rule out, any card a job is already open on
(queued, claimed or running), whichever rule queued it, and, with lanes
holding, any card whose paths overlap a card in progress (see
[Lanes](lanes.md)): a job it already sent that a lane holds, and nobody has
taken, is withdrawn so the next card that could start goes instead. It looks again whenever its job ends, a
card on the board changes or the list is reordered, the rule is saved or
switched on, and every few minutes besides. A card whose job just ended and
which is still at the top (the runner gave up on it) is passed over for ten
minutes (`feed_cooldown_seconds`), so it doesn't go straight back out;
**Run now** sends the top card at once regardless. A `list_top` rule must
have a `runner` action, and the list must exist.

**Two runners on one list.** Because a card with an open job is passed
over, two `list_top` rules on the same list — each sending to its own pool,
one per machine say — work it side by side: each sends the top card the
other hasn't. Leave `wait_while_doing` off on both, or each holds the other
back, and turn on lanes so the two don't work in the same files.

**Waiting while anything is in progress.** A `runner` action with
`"wait_while_doing": true` queues jobs that are not handed out while any
other open card that a runner job is working on is in an in-progress list
(a list with the *In progress* category) on the job's board — the job's own
card doesn't count, and nor do cards on its sub-boards. A card counts while
a job is open on it (queued, claimed or running, a verify or merge job still
to finish included) or on the epic it is a subcard of; a card in progress
with no open job, moved there by hand or left behind, doesn't hold the
runner, and no reason names it. The health monitor and the gardener still
report it as left in progress. The job stays `queued`, no try is counted, and the
next claim after that list clears takes it. `slipdock jobs` and the API show
the reason (`waiting_on`), and an empty claim says which job is held back.
*Work a list with a runner* turns it on by default (its **Wait while
anything is in progress** field); *Send cards to a runner* leaves it off. A
board with no in-progress list refuses the option when the rule is saved.

**Putting back a card left in progress.** A job can end — done, failed,
cancelled, timed out — with its card still in an in-progress list: the
agent crashed, ran out of time, or simply never closed it. Nothing works
on that card any more, so it holds no runner back, but its work is left
half done. A `runner` action on a `list_top` rule with `"requeue_stuck": N` (0
to 10) has the server deal with it when the job ends: the card gets a
comment saying why and which retry it is, and goes back to the top of the
rule's list (unassigned, if the rule only sends cards nobody has taken), so
it is the next one sent — the cool-down doesn't apply to it. After N
retries it is flagged **blocked** and left in progress, with a comment, for
somebody to move or close; with no job open on it, it holds no runner back
meanwhile. Only the job's own card
is touched, never one somebody moved to in progress by hand, and never by a
job cancelled before a runner took it; a job whose lease lapsed and was
handed out again counts once, when it finally ends. A card awaiting
verification, or accepted and waiting for its merge, isn't stuck, and the
card is checked with its row locked, so a merge finishing at the same
moment is never undone. Completing the card
starts its count again. The job records what was done (`recovery`:
`requeued` or `gave_up`). *Work a list with a runner* puts a card back once
by default (its **Put a card left in progress back, N times** field; 0
turns it off); `slipdock runner new … --top --requeue-stuck N` sets it from
the command line.

**Hearing when a job goes wrong.** A rule with the trigger `job_finished`
runs once for each runner job that ends, on the job's card, so the usual
actions — an alert, an email, a webhook — can tell you about it:

```json
{"trigger": {"type": "job_finished", "outcome": ["timeout", "requeued", "gave_up"], "pool": "loop"},
 "actions": [{"type": "alert", "title": "Runner job {{job.id}} {{job.outcome}}: {{card.title}}", "severity": "warning"}]}
```

`outcome` is any of how the job ended (`done`, `failed`, `cancelled`,
`timeout`) and what its rule then did with a card left in progress
(`requeued`, `gave_up`); leave it out to hear every ending. `pool` narrows
it to one pool's jobs. A job whose lease lapsed and was handed out again is
heard once, when it finally ends. Its text may use `{{job.id}}`,
`{{job.status}}`, `{{job.outcome}}` (the recovery if there was one, else the
status), `{{job.recovery}}`, `{{job.pool}}`, `{{job.kind}}`,
`{{job.runner}}`, `{{job.attempts}}`, `{{job.exit_code}}` and
`{{job.error}}`, and a webhook is sent the same fields as `job` beside
`card`. The ready-made rule *A runner job times out or a card is given up*
fills this in, and **Connect a runner** offers it as a checkbox
(`slipdock runner new … --alert`).

**How it is kept safe.** Runners pull: they dial out and ask for work, and
the server never connects to them, so nothing needs a port, a tunnel or an
exception to the outbound-address rules webhooks live by. And the server
only ever sends data — the job's id, its kind, the card and the prompt.
What a kind *runs* is in the config file on the runner's own machine, and a
kind with no definition there is refused without running anything. A rule
can choose which kind of job to queue; it can never choose a command.

**Jobs.** A job goes `queued → claimed → running`, then `done`, `failed`,
`cancelled` or `timeout`. A runner holds a claimed job on a 90-second
lease, renewed by a heartbeat every 20 seconds or so; if the lease runs out
(the machine slept, the network went), the job goes back in the queue for
another runner, and after three tries it fails and the card is flagged with
a comment. A rule never has more than one open job for a card, so a card
moved in and out of a list does not pile up work. The card's **Runner jobs**
section shows each job, which runner took it, when, and the tail of its log;
**Cancel** stops a queued job at once and asks a running one to stop.

**Parked on a question.** A job whose agent needs something only a person
can give opens a [wait](waiting-on-a-person-waits.md) and stops (`slipdock
wait <card> "…"` inside the job, `update_card` `wait` from a session, or
`slipdock finish-job <job> --status waiting --needs "…"` to ask and park in
one step). The job ends `parked`, and never comes back by itself. A
`list_top` rule puts the card back on top of its list, flagged waiting, so
the next card goes meanwhile; one question never holds up the list. When
somebody answers, the card is sent to the same rule again — one fresh job,
with the question, the answer, who answered and the handoff at the top of
its prompt. If that can't happen (the rule is off or gone, the card was
completed or moved to another tree, the queue refused), the card says so in a
comment and the wait records why.

**Pausing.** **Pause** in the Runners panel holds the whole board tree, or
one pool, with a reason you have to give. While it is paused no job is
claimed and no list sends a card; queued jobs stay queued and running ones
finish. Every board in the tree shows a banner with who paused it, when and
why; `slipdock board`, `slipdock cards`, `get_board` and `list_cards` carry
it too, so an agent working without a pool sees it and stops. **Resume**
wakes the runners and rules at once. Agents can pause (`slipdock pause
<board> [--pool P] --reason "…"`, `POST /api/boards/:id/pause`, MCP
`manage_automation` `pause`), but only a person resumes (`slipdock resume`,
outside an agent).

**WIP limits that hold automated work.** WIP limits only warn people. Turn
on **WIP limits hold automated work** on the board's [Agentic Building](the-header-and-the-avatar-menu.md#agentic-building) page (`slipdock
set-board <board> --automation-wip`) and, while the first in-progress list
is at its limit, runner jobs and list sends for cards not already in
progress wait. Jobs that verify or merge a card don't: they finish work
rather than adding to it. People can still drag cards in.

**Held work says why.** A queued job that isn't being handed out says one
reason, the same in the card's jobs, `slipdock jobs`, an empty claim and the
card's state line: *paused by David: bad deploy*, *WIP full: In Progress
3/3*, *#123 is in progress*, or *No runner online for pool dev*.

**Connect a runner**, in the board's Automations panel, is the way in: it
opens a dialog of its own. Pick
where the work should happen — a Linux or macOS machine, a Windows machine,
Claude Code on your own machine in a `/loop`, or Claude on a schedule (a
Claude Desktop scheduled task, or a routine in Anthropic's cloud) — and a few
options (the pool, the agent, its working directory — `/tmp` unless you say,
`~\AppData\Local\Temp` on Windows — permission mode and timeout, how to keep
it running; hooks are under **Advanced**), and it gives you exactly what to
paste: the installer's one-liner with the token in it, and behind two links the
runner script it installs and the config it will write, with **Verify the
script** for the installer's checksums; the PowerShell line, the same way; the `claude mcp add`, skills and `/loop`
lines; or the connector, prompt and schedule for a routine, warning that a
routine needs the code on GitHub and this server reachable from the internet.
It can also add the rule that sends a list's cards to the pool, or use one
you have. A runner on a machine costs nothing while it waits; the Claude
scenarios need no install but every check for work is a Claude turn. The
answers are kept on the runner (never the token), so **Setup** shows the
steps again, **Change Settings** changes only what you change, and **Make
a new token** replaces a lost one.

**The Slipdock tools.** A job runs Claude with `-p`, where nobody can approve
a tool, so a Claude runner is set up to allow every tool of the Slipdock MCP
server without asking: **Let it use the Slipdock tools**, on by default, adds
`--allowedTools` for the servers it names (`claude_ai_Slipdock`, the claude.ai
connector, and `slipdock`, one added with `claude mcp add`; the name on a
machine is in `claude mcp list`). The installers take it as `--mcp-servers
A,B` / `-McpServers 'A,B'` and write it to the config as `ALLOWED_TOOLS` /
`$AllowedTools`; `''` turns it off, and then the agent has no access to the
board. Give a Claude runner the project's folder as its working directory, too:
Claude Code loads a project's own commands, skills and `.claude/settings.json`
only from where it starts, and the wizard warns while it is blank or still the
default.

**Subagents finish their builds.** In print mode Claude Code stops a run's
background tasks 10 minutes after its last turn, and the run ends when the
turn does. A pass that hands subcards to subagents and ends its turn to wait
for them loses them mid-build: the job ends done, the subcards stay in
progress with their work uncommitted. So a Claude runner's config exports
`CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0` (`$env:` on Windows), which waits for
them however long they take; Codex and custom agents don't get it. And the
`slipdock-loop` skill has a pass wait for every subagent it started before its
turn ends, and never end with a subcard it moved in left in progress with
nothing working on it: it finishes the subcard or hands it back with a
handoff.

**Instructions and hooks.** The wizard also takes standing instructions — how
much to write on the card (quiet, normal or verbose) and anything else you
would otherwise add by hand — which are put after every job's prompt, and two
hooks: a command run before each job (the job runs only if it succeeds) and
one run after each, however it ended, with `$SLIPDOCK_STATUS` (`done`,
`failed`, `cancelled` or `timeout`) and `$SLIPDOCK_EXIT`. They are written
into what the wizard generates and kept on the machine; the server never
sends them at job time. For the shell runner they become `JOB_INSTRUCTIONS`
(in a quoted heredoc with a random delimiter, so nothing in the text is read
as shell) and `before_job`/`after_job` functions in its config; for a `/loop`
they go in its prompt — the hooks either as instructions Claude is asked to
follow (best effort) or as Claude Code hooks in `.claude/settings.json` that
run after `claim_job` and `finish_job` (reliable, and the wizard says which
you are getting). A cloud routine takes the instructions only: it runs on
Anthropic's machines, so there is nothing for a hook to run on — and ChatGPT
the same, on OpenAI's. **Change the
answers** on a runner shows a diff of what changes, and re-running the
one-liner on the machine puts it in place, keeping the token it has.

**A worktree per job.** Runners side by side on one repository share its
working tree, so one can sweep another's files into its commit. With *A git
worktree per job* ticked (`--worktree` to `install.sh`, `-Worktree` to
`install.ps1`, `slipdock runner new … --worktree`, or by hand `WORKTREE=1` and
`WORKTREE_REPO=<repo>` in the shell config, `$Worktree = $true` and
`$WorktreeRepo` in the Windows one), the runner makes a worktree before each
job — `git worktree add <repo>-lanes/card-<id>` on branch `card-<id>`
(`WORKTREE_DIR` / `$WorktreeDir` to put them elsewhere) — and runs the job,
its `before_job` and its `after_job` there, with `$SLIPDOCK_WORKTREE` set
to it. Afterwards a clean worktree is removed (and its branch deleted if it
is merged; kept otherwise), and one with uncommitted changes is kept, which
the job's log says; the next job on that card reuses it. A job with no card,
or a directory that isn't a git repository, runs in place, saying so; if the
worktree can't be made the job fails without running. Off by default: with
the setting off nothing changes.

**Keeping runners current.** Every claim says which script the runner is
running (the SHA-256 of its own file, as `/runner/SHA256SUMS` lists it), and
the Runners panel marks one that isn't this server's as *out of date* (or
*old script* when it is too old to say). It also marks *no merge* on a board
that ships by pull request when a runner doesn't take merge jobs.
`slipdock runners` shows the same in its SCRIPT column, and `slipdock runner`
on its *script* line.

**Skill and CLI drift.** Installed copies of the slipdock skills can be older
than the server's, and so can a machine's `slipdock` CLI, so a pass can
follow stale instructions. Every claim also says what the machine has:
the SHA-256 of each `slipdock*/SKILL.md` under `~/.claude/skills`
(`SKILLS_DIR` / `$SkillsDir` in the config for another place; line endings
count as LF) and of the CLI (`SLIPDOCK_CLI` / `$SlipdockCli`, else the
`slipdock` on the PATH; on Windows the escript beside `slipdock.cmd`). The
server compares them with the skills it packages and the escript
`/cli/SHA256SUMS` publishes. The Runners panel marks a runner *skills
drifted* or *old CLI*, its details say *Skills* current, drifted (with the
names) or unknown and *CLI* current, old, none or unknown, `slipdock runners`
shows a SKILLS · CLI column and `slipdock runner` a *skills* and a *cli* line,
and the API's runner has `drift` (`skills`, `drifted_skills`, `cli`). A
runner that drifts raises one alert on its board, which clears itself once
the runner reports everything current. A skill the server doesn't package,
or one not installed, isn't drift. The server never changes anything on the
machine itself, but a runner that keeps itself current (below) also puts the
server's skills in its skills directory before every job but a merge (#2048),
so its skills are never a hand-edited second copy: `SKILLS_UPDATE=0` /
`$SkillsUpdate = $false` keeps them as they are, `SKILLS_UPDATE=1` /
`$SkillsUpdate = $true` turns it on without the self-update, and a skill
folder that is a symlink is left alone. Elsewhere, run the install one-liner
again. With *Keep the runner current* ticked (the default for
new installs; `--no-self-update` to `install.sh`, `-NoSelfUpdate` to
`install.ps1`, `slipdock runner new … --no-self-update`; by hand
`SELF_UPDATE=1` or `$SelfUpdate = $true` in the config), a runner whose
script isn't the server's updates itself **between any two jobs** (#1925):
after a claim comes back empty, and after each job's finish is reported,
before it claims the next. The server names its script (`X-Runner-Latest`)
on every claim, empty or not, and on every finish, so a busy queue, or an
epic the board sends again a second after each pass, still lets it update,
and a deploy during a long job reaches the job after it. A job is never cut
off for it, and once a newer script is known the old one claims nothing
more. It fetches the new script and `SHA256SUMS`, replaces itself only if
the download's SHA-256 matches both the published sum and the version the
server announced, then starts again in place. A failed fetch or a mismatch
keeps the running script, which carries on taking jobs, says so in the log,
and that version isn't tried again until the runner restarts. So a
self-updating runner never needs restarting by hand to pick up a new
script: one still marked *out of date* after a job has ended has an update
that failed, and its log says why. The config is
never touched, so a runner installed before this has no such line and stays
as it is until it is installed again. `SELF_UPDATE_URL` (`$SelfUpdateUrl`)
fetches from somewhere else than the server.

**Having Claude write the hooks.** What a hook should do — which notifier
to call, what to keep from each pass — differs from one machine to the
next, so rather than ship one, **Connect a runner** (Advanced → Hooks →
*Have Claude write this hook*, for the shell and Windows runners) and
`slipdock runner setup <board> <runner> --hook-prompt` give you a prompt
to paste into Claude Code on the runner's machine. It states the contract
a hook works under and asks you the site-specific questions, then has
Claude write the hooks and a test for them. What every runner needs —
putting back a card a job left in progress, and alerting on it — is the
server's (`requeue_stuck` and `job_finished`, above), so the hooks never
move cards. The prompt points at a worked example, one server's own hooks
and their test, served at `/runner/examples/after-job-hook.sh` and
`/runner/examples/after-job-hook-test.sh`, and a pass-log script for them,
`/runner/examples/passlog.sh` (all from `priv/runner/examples/`). That script
writes `Pass <card> (<YYYY-MM-DD HH.MM>)` into the card's folder with
`slipdock page new … --card`, so nothing in the title repeats the card. The
pass log is **opt-in**: the example hook writes no page unless
`SLIPDOCK_HOOK_PASSLOG` is set to that script's path. Each job's live log is on
the server already, deleted a while after the job ends unless someone keeps it
with **Keep this log** (above), which writes the same page for the jobs worth
keeping; a page for every pass made hundreds nobody opened. For the shell
runner the prompt reads:

````text
Write the before-job and after-job hooks for the Slipdock runner on this machine.

The runner takes jobs from a Slipdock board and runs a coding agent on each card. It is the shell runner, slipdock-runner; its config, ~/.config/slipdock-runner/config (config-NAME for a runner installed with --name NAME), is shell, and it calls the functions before_job and after_job, if the config defines them, around every job. Write the hooks as one script, ~/.local/bin/slipdock-hook, taking `before` or `after`, in bash or POSIX sh.

The contract every hook works under:

- The runner sets these for both hooks:
  - $SLIPDOCK_JOB_ID: the job's number
  - $SLIPDOCK_JOB_KIND: the job's kind (claude, codex, …)
  - $SLIPDOCK_CARD: the card's number
  - $SLIPDOCK_CARD_URL: a link to the card
  - $SLIPDOCK_STATUS: how the job ended: done, failed, cancelled or timeout (after-job only)
  - $SLIPDOCK_EXIT: the job's exit code (124 timed out, 130 cancelled) (after-job only)
- Exit 0, always. A before-job hook that fails stops the job from running, and an after-job hook runs before the runner reports the job finished, so neither may block, hang or fail it: wrap every step so a failure is logged and skipped, and put a time limit on anything that calls the network (well under a minute in all).
- Keep your own log file. What a hook prints goes into the job's log, whose tail the board shows as the job's output, so never print secrets there.
- Don't move, flag, complete or comment on cards. Putting back a card a job left in progress is the server's job (the rule's "Put a card left in progress back, N times", requeue_stuck), and so is alerting on it: a rule with the trigger job_finished (outcome timeout, requeued or gave_up) can raise an alert, send an email or call a webhook. A hook that moves cards races the server and can stall the runner.

What to write — ask me before you start, then write it:

1. Which notifier I use, if any: PushOver, ntfy, Slack, email, or something else, and where its credentials live (an environment variable or a file only I can read — never in the hook itself). Send an alert when a job times out or fails, with the card's link.
2. What to keep from each job: by default nothing. The runner already sends each Claude job's transcript to the server as its live log, which the board deletes a while after the job ends, and Keep this log on the card (`slipdock job <id> --keep`) keeps the ones worth keeping as a page in the card's folder. Only if I want a page for every pass, a record of it can be made from its Claude Code transcript: in the before-job hook, touch a marker file named after the job; in the after-job hook, take the newest .jsonl in the folder under ~/.claude/projects named after the job's working directory (every / and . turned into -) written since that marker that mentions $SLIPDOCK_CARD_URL. (Or have the job function pass claude a --session-id of its own and look that file up.) It can be summarised into a page for the card (`slipdock page new <board> "Pass $SLIPDOCK_CARD (<YYYY-MM-DD HH.MM>)" --file F --card $SLIPDOCK_CARD`, which files it in the card's folder and pins it there; the title says nothing the folder already says, and a pass that writes several files uses a folder `Pass <n>/`) or kept on disk. Ask me which, if any.
3. A test script for the hooks, run against fake notify and pass-log commands and a folder of fake transcripts, that checks each status, a missing environment, a failing notifier and the exit code, and that the hooks never touch the board.

A worked example to start from — one server's own hooks, with their test and a pass-log script:

https://your-server/runner/examples/after-job-hook.sh
https://your-server/runner/examples/after-job-hook-test.sh
https://your-server/runner/examples/passlog.sh

When it's written and its test passes, show me the two lines for the runner's config — before_job() { ~/.local/bin/slipdock-hook before; } and after_job() { ~/.local/bin/slipdock-hook after; } — or the commands to type into the wizard's hook fields (Advanced → Hooks), and remind me that the hooks run as the runner's user, with its PATH.
````

**Runners** belong to a board tree and a pool. The board owner makes them:
each has its own token (`sdr_…`), shown once, that can take and report on
that pool's jobs and nothing else — it is not an API token and opens no
other door. Revoking a runner ends its token at once. A Claude session can
take jobs too, with the API token it already has, over MCP (`claim_job`,
`job_progress`, `finish_job`) or the CLI (`slipdock claim-job`); it shows in
the runner list as *label (session)* — from its first claim on; until then a
pool a rule sends to shows there as *waiting for a runner*. A claude.ai
connector keeps the tool list it was added with, so one added before the job
tools existed has none of them: disconnect and connect it again. A session
told to take jobs that finds no job tools stops and says so. A session reports between steps of its
own work rather than from a background loop, so it holds its job on a
20-minute lease instead of 90 seconds.

| CLI | What it does |
|---|---|
| `slipdock runner new <board> [name] --pool P [--scenario …]` | The **Connect a runner** wizard: prints exactly what to paste for `server` (the default), `windows`, `loop`, `cloud` or `chatgpt` (the connector, and a one-job prompt for a chat or a ChatGPT scheduled task; jobs of kind `chatgpt`, and `--commit` refused, as it has no repository), with `--agent`, `--command`, `--kind`, `--cwd`, `--permission-mode`, `--no-slipdock-tools`, `--mcp-servers A,B`, `--timeout`, `--service`, `--where desktop\|cloud`, `--repo`, and what a job does to its card and repository, in every scenario and each off unless given: `--in-progress` (move it to the doing list), `--assign` (assign it to the session), `--commit` (only ever in a git repository), `--push` (needs `--commit`), `--move-done`, `--complete` and `--percent-100`, each with a `--no-` form. Off ones are said in the prompt (or a runner's standing instructions) as don'ts. `--verbosity nothing` (the default) means no comments on the card at all. A working directory spelled the Windows way (`C:\…`, `~\…`) gets PowerShell steps, the skills from `/install.ps1`. For a runner of its own (server, windows) it makes one and prints its token, once; `--column LIST` adds a rule sending that list's cards. |
| `slipdock runner setup <board> <runner> [options]` | A runner's steps again, from the answers saved on it (the token left out); with any of `runner new`'s options, including `--verbosity`, the seven `--[no-]in-progress` … `--[no-]percent-100` toggles, `--instructions`, `--before-job`, `--after-job` and `--hooks prompt\|hook`, saves them and prints what changes. With `--hook-prompt`, prints the prompt that has Claude write the runner's hooks. |
| `slipdock runner token <board> <runner>` | A new token for a runner, the old one ended, with its steps written out for it. |
| `slipdock runner ls <board>` / `slipdock runners <board>` | The board's runners: pool, last seen, current job. |
| `slipdock runner show <board> <runner>` | One runner in full: what kind it is, who made it and when, last seen, the API token a Claude session works through, the job it holds now, how many of its jobs ended each way, its latest jobs (`--limit N`, 10 by default) and the rules sending cards to its pool. On the Automations panel, clicking a runner's name shows the same. |
| `slipdock runner rm <board> <runner>` | Revokes a runner. |
| `slipdock jobs <board> [--status S]` / `slipdock jobs --card ID` | Jobs, newest first. `S` is `open` or a status. |
| `slipdock job <id>` | One job: status, runner, its latest step, prompt, log tail. |
| `slipdock job <id> --follow [--interval SECS]` | Watches a job: its live log as it arrives, one line per message, tool call or result, until the job ends (exit 0). |
| `slipdock job-log <id> [--follow] [--json]` | The job's live log so far; `--json` prints one entry per line. |
| `slipdock job <id> --keep` | Keeps an ended job's log: written as a page `Pass <card> (<date>)` in the card's folder, so it never expires. |
| `slipdock cancel-job <id>` | Stops a job. |
| `slipdock claim-job <board> --pool P` | Takes the next job as this session. |
| `slipdock job-progress [<id>] [--step S] [--message NOTE]` | Renews the lease. `--step` says what the job is doing now: kept on the job (its `step`, shown on the Runners panel and in `slipdock job`/`jobs`), never on the card. The note is also a comment on the card (`--message -` reads it from stdin, line breaks and all). Without an id, the runner job in `$SLIPDOCK_JOB_ID`: the agent a runner started may report on its own job. Prints `ok` or `cancel`. |
| `slipdock finish-job <id> --status done\|failed\|cancelled\|timeout [--summary S]` | Ends a job this session claimed. |

**The shell runner** (`slipdock-runner`) is a POSIX `sh` script that needs
`curl` and nothing else — no `jq`, no Python, no root. It long-polls for a
job, runs the config's `job_<kind>` function with the prompt in
`$SLIPDOCK_PROMPT` (and `$SLIPDOCK_JOB_ID`, `$SLIPDOCK_CARD`,
`$SLIPDOCK_CARD_URL`), heartbeats with the tail of its log every 20 seconds,
and reports the exit code. While the job runs it also sends the agent's
Claude Code transcript about once a minute, so the job has a live log on the
server (see **A job's live log** below). A cancel from the board, or a job over its
`JOB_TIMEOUT`, stops the job and everything it started. One runner works one
job at a time; run more for more. Install it with

```sh
curl -fsSL https://your-server/runner/install.sh | sh -s -- \
  --url https://your-server --token sdr_... --pool default --agent claude --cwd ~/src/app
```

which writes `~/.local/bin/slipdock-runner`, its config at
`~/.config/slipdock-runner/config` (mode 600, yours to edit — it is shell,
and each `job_<kind>` function in it is a kind of job this machine will run)
and a systemd user unit (Linux) or launchd agent (macOS), and starts it.
`--cwd '~/…'` (or `-Cwd '~\…'` on Windows) is the runner's own home even
in quotes, and is written into the config as `"$HOME"/'…'` (`Join-Path $HOME
'…'`); another user's `~bob/…` is refused — give a full path.
`--agent codex` or `--agent custom --command '…'` run something else;
`--service none` and `--no-start` leave starting it to you.

**Several runners on one machine** — one per board, say — each need a name
of their own: `--name NAME` (`-Name NAME` on Windows). Runner NAME has its
config at `~/.config/slipdock-runner/config-NAME`, its own systemd unit
`slipdock-runner-NAME` (launchd `us.slipdock.runner.NAME`; on Windows
`config-NAME.ps1`, `runner-NAME.log` and the task *Slipdock runner (NAME)*),
and installing it leaves the others running. The setup steps name each new
runner after its board's code and its pool, as in `--name slipdock-loop`, so
setting up a second board on the same machine just works. Installing with no
name over a config that is another runner's — another server or pool — is
refused rather than replace it; `--replace` (`-Replace`) replaces it anyway,
keeping the old one beside it as a `.bak`. A runner set up before runners
had names keeps none: set up again, it updates the unnamed one.

The installer is
the same file for everyone; its SHA-256 is at `/runner/SHA256SUMS` to check
before running it.

**On Windows**, `slipdock-runner.ps1` does the same in Windows PowerShell
5.1, which every Windows has, or PowerShell 7: the same protocol, a
dot-sourced `config.ps1` whose `Job-<Kind>` functions are the kinds of job
the machine runs (kind `two-words` is `Job-TwoWords`), the prompt only ever
in `$env:SLIPDOCK_PROMPT`, the job in a child process whose whole tree is
stopped on cancel or timeout, and `Before-Job`/`After-Job` and
`$JobInstructions` as in the shell config. Install it from PowerShell with

```powershell
& ([scriptblock]::Create((irm 'https://your-server/runner/install.ps1'))) `
  -Url 'https://your-server' -Token 'sdr_...' -Pool default -Agent claude -Cwd 'C:\src\app'
```

which writes `%LOCALAPPDATA%\slipdock-runner\` (the runner, and the config
with an ACL leaving it readable by you alone) and a per-user Task Scheduler
entry, *Slipdock runner*, that starts it at logon, and again within 5 minutes
if it ever stops — no admin rights. Its log is `runner.log` beside the config:
an error the runner hits is written there (the task's window is hidden), and a
job it was running is stopped and failed rather than left behind. `install.ps1` and `slipdock-runner.ps1`
are in `/runner/SHA256SUMS` too.

**A job's live log.** While a job runs, both runners send its agent's
Claude Code transcript to the server about once a minute, and the rest as it
ends, so what the agent is doing can be read before it finishes: `GET
/api/jobs/:id/transcript` answers it as JSON Lines. The runner finds the
transcript as the newest `.jsonl` in a project folder under
`~/.claude/projects` (`$CLAUDE_CONFIG_DIR/projects` if that is set) written
since the job started that mentions the card's link. Each send is only the
lines the server hasn't got, at most 512 KB, with any line over 32 KiB (a big
tool result) replaced by a line saying how long it was, and with this
machine's Slipdock tokens taken out — the runner's, `$SLIPDOCK_TOKEN` and the
CLI's saved ones; the server takes out the shapes of other secrets as well. A
log stops at 8 MB, with a last line saying so. A send that fails never stops
the job: the next one catches up. Set in the config:

| Shell (`config`) | Windows (`config.ps1`) | Default | |
|---|---|---|---|
| `TRANSCRIPT_EVERY` | `$TranscriptEvery` | 60 | seconds between sends; 0 sends nothing |
| `TRANSCRIPTS` | `$Transcripts` | `~/.claude/projects` | where Claude Code keeps its transcripts |
| `TRANSCRIPT_SEND` | `$TranscriptSend` | 524288 | the most one send carries, in bytes |
| `TRANSCRIPT_LINE` | `$TranscriptLine` | 32768 | a longer line is sent as a note of its length |

**Watching a job.** A job's live log shows on the card, under the job in
*Runner jobs*, and on the Automations panel under the runner's current job
(click the runner's name): one line per message, tool call or tool result of
its agent, each with its time, newest at the bottom. It updates by itself as
the runner sends more. A line with more to it (a tool call's input, a
command's whole output) opens when clicked. A running job's log is open; a
finished one's is folded under *Live log* until clicked. A page holds the last
300 lines and says how many earlier ones there are.

From a terminal, `slipdock job <id> --follow` prints the same lines as they
arrive and stops, exit 0, once the job has ended (`--interval SECS` between
reads, 10 by default); `slipdock job-log <id>` prints what is there so far.
Over MCP, `job_log` reads it, `from` an earlier call's `next`. Both read
`GET /api/jobs/:id/log?from=N`.

**Logs evaporate unless kept.** A job's live log is deleted a set time after
the job ends. Two board settings say how long, under *Runner job logs* on the
top board's [Agentic Building](the-header-and-the-avatar-menu.md#agentic-building) page (a sub-board's jobs
follow its top board, and its page shows them read-only), or with
`slipdock set-board <board> --job-log-hours N --failure-log-hours N`:

- **Keep job logs for** (24 hours by default): a job that ended well.
- **Keep failure logs for** (168 hours, 7 days): a job that failed, timed out
  or was cancelled, and one whose work turned out a failure after it ended:
  its card rejected (the verifier's own log too), flagged `stuck` by the health
  monitor, or put back on its list because the job left it in progress. The
  failure time runs from then, so a build rejected a day after it ended keeps
  its log a week from the rejection.

The job itself, its summary and its last output stay; only the log goes, and
the job then says when it went. Under each ended job the card says when its
log will be deleted. **Keep this log** there (`slipdock job <id> --keep`, MCP
`keep_job_log`, `POST /api/jobs/:id/keep`) writes it as a wiki page in the
card's folder, pinned to the card and titled `Pass <card> (<date>)` like the
after-job hook's pass log: a line saying which job it was and how it ended,
then everything the agent said. The page then stays like any other, and the
job links to it. Keeping it again gives the same page. Anyone who can edit the
card can keep its log; a running job's log can be kept once it has ended.

The runner protocol and the session endpoints are in the agent guide
(`slipdock guide runners`).

---

← [Automations and alerts](automations-and-alerts.md) · [Contents](../manual.md) · [Wiki](wiki.md) →
