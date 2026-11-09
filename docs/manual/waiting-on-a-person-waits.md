[Slipdock — the manual](../manual.md)

## Waiting on a person (waits)

A card that can't go on until somebody answers something — a decision, a
credential, an approval — gets a **wait**: what it needs, who it waits on (a
named person, or anyone), when it was opened and, optionally, a short list of
answer choices. A card has at most one open wait. It flags the card
`waiting` and comments the question, so the board and every filter that
skips waiting cards already know; unlike the bare flag, it has a clock, an
owner and a way back.

While one is open it sits beneath the card's title — *Waiting on Dana:* and
the question, who asked it and how long ago — with a button for each choice,
a box for an answer in words, **Answer**, **Skip** and **Withdraw**.

A wait can ask **several questions** at once. They are shown numbered, each
with its own answer box, and **Send answers** sends them together; a box left
empty is kept as unanswered. With an AI model set (Account → AI model), the
✨ button beside a box suggests an answer from the card: its description,
checklist and comments, and the other answers typed so far. It only fills
the box, and nothing is sent until you answer. **Skip** skips every question:
the wait closes as *skipped* and the card moves on as it would on an answer.
A question an agent wrote as one numbered block (`1. … 2. …`) is split into
the series too.

To ask questions yourself, press **Ask** in the toolbar at the top of the
card. Write one question per box (**Add a question** for another, up
to 20), choose who they are on (or anyone), and press **Ask**. Questions
asked before stay on the card under **Questions asked before**, each with its
answers, who answered and when, or how it ended without an answer. The answer is
posted on the card as a comment from whoever answered and clears the
`waiting` flag if the wait set it. Taking the `waiting` flag off by hand
withdraws the wait, with a comment naming who did. Completing or archiving
the card closes its wait with that reason. Anyone who can change the card
can answer, from the card, [My work](roll-ups-the-outline-and-my-work.md), the
CLI, the API or MCP; an agent can't answer a wait it opened itself, and a
person can always answer or withdraw their own.

```sh
slipdock wait 12 "Which region?" --on dana@example.com --choice eu --choice us
slipdock wait 12 --withdraw
slipdock answer 12 --choice 1                  # or: slipdock answer 12 "eu, for the data rules"
slipdock wait 12 --question "Which region?" --question "How many seats?"
slipdock answer 12 --answer eu --answer 12     # one per question, in order ("" leaves one)
slipdock answer 12 --skip                      # skip the questions: the card moves on
slipdock waits 12                              # every question the card has asked, and the answers
slipdock work                                  # what is waiting on you, oldest first
slipdock work --dismiss 12                     # off my own list until the reason changes
```

Over the API, `POST /api/cards/:id/wait` (`needs`, `questions`, `on`,
`choices`) opens one, `POST /api/cards/:id/wait/answer` (`answer`, `answers`
one per question, `choice` counted from 1, or `skip: true`) answers or skips
it, `DELETE /api/cards/:id/wait` withdraws it and `GET
/api/cards/:id/waits` lists every one the card has had; a card's JSON
carries the open one as `wait`. Over MCP it is `update_card` with `wait`
(`questions` for several; `null` withdraws) or `answer_wait` (`answers`,
`skip`), and `get_card` with `waits: true` for the history.

**Who gets asked.** Each wait says what kind of question it is: `product`,
`ux`, `security`, `release` or `other` (`other` when it doesn't say), shown
beside the question on the card. A board can route each kind to people of its
own, on the board's [Agentic Building](the-header-and-the-avatar-menu.md#agentic-building) page → *Who gets asked*: the first person named for a kind
is who the wait is on, and the others are told by email. Each must be on the
board. A wait that names its person (`--on`) goes to them; one with a kind
goes to the person its kind is routed to, on its own board or the nearest
board above it, else to the board's owner. A wait with no kind and no route
for `other` waits on anyone, as before. The server's own questions route the
same way: the [rejection limit](verified-work.md)'s wait asks as `release`, and
an audit that disagrees is emailed to `release`'s people beside its alert.
Someone routed who leaves the board comes off its routes, and the open waits
on them go to the owner, with a comment on each card. The table starts empty:
nothing to set up.

```sh
slipdock set-board slipdock --route product=dana@example.com --route release=lee@example.com,sam@example.com
slipdock set-board slipdock --no-route product     # back to the owner
slipdock wait 12 "Which pricing tier ships first?" --kind product
```

Over the API, `PATCH /api/boards/:board` with `wait_routes` (`{"product":
["dana@example.com"], "ux": []}`, an empty list taking a route off; a board's
JSON carries them as people) and `question` on `POST /api/cards/:id/wait`;
over MCP, `update_board` `wait_routes` and `update_card` `wait` `question`.

**When an agent waits, and when it carries on.** A wait is for readings
that differ materially in cost or in what you see, for the decisions your
Playbook or board routes to a person (product, UX, security, release), and
for anything a rule says is a person's step (merging, changing a handbook
rule, deploying). A locked bar item that a later decision or rule has made
moot is not one: the agent reads it the obvious way, says so on the card
(what it read, why, and the decision or rule it cites) and the verifier
judges that reading, accepting it when it was noted and rejecting it when
it wasn't. A wait that offers choices and a proposed answer is an approval
and should be rare; it names the choice the agent proposes (`--default N`,
`default` over the API and MCP), shown as *(proposed)* on its button, so your
answer can be one click.

**A moot wait clears itself.** An agent sent a card with an open wait first
checks it is still live: answered elsewhere, the bar or description edited
since, the cited rule or decision now in place, the card decided since. A
moot one is withdrawn by whichever agent finds it, with a comment saying
why (`slipdock wait 12 --withdraw --reason "…"`, `DELETE
/api/cards/:id/wait?reason=…`, `update_card` `wait: null` with
`wait_reason`). An agent withdrawing a wait it didn't open is refused
without the reason.

**An approval's proposal stands after** a time you choose, if you want it
to: on the board's [Agentic Building](the-header-and-the-avatar-menu.md#agentic-building) page under *Who
gets asked*, `slipdock set-board slipdock --wait-default-after 4h` (`90m`,
`2d`; `off`), `PATCH /api/boards/:board {"wait_default_after": "4h"}` or
`update_board` `wait_default_after`. It is off until set. Once on, a wait of
kind `other` that offers choices and proposes one, unanswered for that long,
is answered with its proposal by the server: the card says so, the person it
was on (or the owner, for a wait on anyone) is told, and the card moves on as
it would on your answer. A product, UX, security or release question, and a
wait that proposes nothing, always waits for a person, however long it takes.

```sh
slipdock wait 12 "Read bar 2 as the one copy W-31 settled on?" --choice Yes --choice No --default 1
slipdock wait 12 --withdraw --reason "Answered on #40: the bar was edited since"
slipdock set-board slipdock --wait-default-after 4h
```

**Spikes answered: resume planning.** When planning stops to answer a
question by building, each question is a `spike` subcard of the epic. When
the last open one is accepted (an archived spike counts as answered), the
server opens one `product` wait on the epic, "Spikes answered (#a, #b):
resume planning", naming each spike and the wiki page that answers it.
Nothing resumes by itself: you resume planning, and the plan skill reads
the answers and writes the Spec. An epic already waiting on something
gets no second wait, and a spike with no epic above it opens none.

Agents are told to open a wait, say what they need and what kind of question
it is, and stop, rather than flag the card and hope. A wait opened from a [runner](runners.md) job
**parks** the job, and answering it sends the card to the same rule again
with the question and the answer on top of the prompt.

**Waiting on you.** My work opens with everything that needs you, oldest
first, each with why and for how long: open waits on you (a routed question
among them), and on anyone on cards you own or are assigned; your cards flagged `review` or `waiting`;
cards the runner gave up on, or whose newest job failed, on boards you own;
and, for a board's owner, cards in an in-progress list for over an hour with
nobody on them, and cards still in a [Scheduled](recurring-cards.md) list after
the end of their due day. A card awaiting verification on a board you own
is on you only when no runner will verify it: while a verify job for it is
claimed or running, or for 15 minutes after its submission while one is
queued or a runner of the board's verify pool is online, it stays off, and
it comes back if no verify job has started by then. With no verifier it is
on you at once, and you can accept or reject it by hand whenever you like. A wait's choices and answer box are right there. The header
shows how many on every page (refreshed within a minute; on a laptop the count
is in the alerts bell's, and its panel's first row comes here), `slipdock whoami`
and `GET /api/me` carry it as `waiting_on_you`, and `slipdock work`, `GET
/api/work` and the `plan-my-day` prompt list them.

**Where you look from the top.** The same items show on the boards, so a
question on a subcard isn't hidden under its epic. An epic's tile carries a
chip, `⏸ 2 waiting on you`, counting what in its tree (its subcards, at any
depth) is on you, and a glance line naming them with their reasons,
`Waiting on you: #2063 (a question), #2075 (3 rejections)`, in place of the
percentage. Waits on other people in the tree appear in the line only (`and
1 on someone else`), never in the chip, so the chip means "you, now". The
chip opens the sub-board kept to the cards waiting on you (`?waiting=me`,
with *Show all* to clear it). The board header shows `Waiting on you: N`
for the board's tree, which opens My work kept to that board
(`/work?board=<id>`). Both follow a wait as it opens and is answered.
Open the epic and its subcard list marks the same rows: each one waiting on
you carries a badge with its reason (*to verify*, *a question*), one waiting
on someone else a quieter mark naming who it waits on, and the line's #ids
above the list jump to their rows.
`slipdock card <epic>` prints the same line, and `slipdock board` prints the
tree's count and each epic's line. `GET /api/cards/:id`, `GET
/api/boards/:board` and MCP `get_card` / `get_board` carry `waiting_on_me`:
`count`, `cards` (each the same item `GET /api/work` gives, with `short`,
its reason in a few words), `on_others` and `line`. On a board it is the
whole tree's, and each epic in the lists carries its own.

**Told when it happens.** A wait addressed to you raises an alert in the
header that only you see, and emails you, when somebody else asks or an
agent asks under your own token. A card past its board's rejection limit
asks its person with such a wait, so it alerts them the same way (*Past the
rejection limit*). A wait you open yourself in person, or one on anyone,
alerts nobody. Both are on by default. Turn either off in account settings,
under *When something waits on you* (*Alert me in the header*, *Email me*).
The `flagged` rule preset is unchanged.

**Taking things off your list.** Some items are things you don't mean to
act on: a failed job on a card you'll never pick up, or a board you are one
step short of archiving. Two ways off, both yours alone. Nobody else's list
changes, and nothing on the card or board changes either.

- **Dismiss an item**: the × on its row in My work, `slipdock work --dismiss
  <card>`, `POST /api/work/dismissed` (`card`), or MCP `update_card` with
  `waiting_list: "dismiss"`. A dismissal holds on the card *and* what put it
  there: the failed job, the wait, the flag's run, the submission, the time it
  went into the list unowned. So the same cause stays off, and a new one
  brings the card back: a second failed job, a new wait, the flag taken off
  and put on again. If the card has another reason too, it shows for that one.
- **Mute a board**: *Mute on my Waiting on you* in the board's `…` menu,
  `slipdock work --mute <board>`, `POST /api/work/muted` (`board`), or MCP
  `update_board` with `waiting_list: "mute"`. Nothing from the board or any
  board under it shows on your list. Muting is not archiving: the board
  works as before, for you and everyone else. A strip on the board (and on
  each one under it) tells you it is muted and why it is quiet, with
  Unmute. Only you see it.

The hiding is never silent. My work's section says `3 waiting · 2 dismissed
· 1 board muted` under its heading, and *Show* opens what you dismissed
(each with **Undo**) and the boards you muted (each with **Unmute**).
`slipdock work` prints the same line. `GET /api/work` carries
`dismissed_count`, `muted_count` (cards a mute keeps off) and
`muted_boards`, and `whoami` carries `waiting_hidden`. Only a dismissal whose
cause still stands is counted.

```sh
slipdock work --dismiss 684            # off my list, for this cause
slipdock work --dismissed              # what I dismissed, still standing
slipdock work --undismiss 684          # back on
slipdock work --mute old-ops           # the board's tree off my list
slipdock work --unmute old-ops
```

Over the API, `GET /api/work/dismissed` lists the dismissed items and
`DELETE /api/work/dismissed/:card` undoes one. `DELETE /api/work/muted/:board`
unmutes. Over MCP, `update_card` takes `waiting_list: "undismiss"` and
`update_board` takes `waiting_list: "unmute"`. Read access to the card or
board is enough, and `waiting_list` goes on its own in the call. Dismissing
by rule is the board's own switches, and nothing is ever dismissed for you.

### Desktop notifications

A wait opened on you, a wait routed to you and an @mention of you each email
you, and can also show a desktop notification, through the browser's
Notification API. It is **off by default**, and set per browser: **Account →
Preferences → Desktop notifications on this browser** turns it on, which asks
the browser for permission, and the choice is kept in that browser's local
storage (the browser's permission is per browser too). Blocked for the site,
or a browser without notifications, and the toggle says so.

They arrive through a Slipdock tab that is open, in the background too: every
signed-in page listens on the person's own topic (`Slipdock.Notify`, which
also sends the email). With no tab open nothing shows, on purpose: there is no
Web Push and no service worker. Each one carries its own id as the
notification's tag, so several open tabs show one between them. Clicking it
brings the tab forward and opens the card. Nobody gets one for their own
doing, nor for a card they can't read, and a tab in front that is already
showing the card stays quiet. Email is unchanged.

Only the web app has this. The REST API, the CLI and the MCP tools have
nothing to set: a toast needs a browser, and the setting lives in it.

---

← [Profiles](profiles.md) · [Contents](../manual.md) · [Flow: the pulse, a card's state and its age](flow-the-pulse-a-cards-state-and-its-age.md) →
