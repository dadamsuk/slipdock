---
name: job-scan-setup
description: Stand up an automated job search on a Slipdock board. Has Slipdock build the board from the job-scan Tool, interviews the person for their own search rules, career record and CV baseline, writes those as wiki pages, and wires the trigger that generates application documents. Use this whenever someone wants to set up, configure, install or start an automated job search, job scan, role tracker or application pipeline on Slipdock, when they ask how to get the job-scan skill working, and whenever job-scan itself reports that no configuration exists yet. Also use it to review or extend an existing setup.
---

# Job scan setup

You are standing up a job search that will run every day without supervision. The
work is one board, seven lists, six wiki pages and one automation rule, and Slipdock
builds all of that itself when you call `install_tool`. Your part is the conversation:
finding out what this person wants, and writing it onto the pages.

## Why it is shaped this way

The skills hold **mechanics**: how to search, how to read a posting, how to write a
card. The board holds **the person's content**: what they want, what they will not
look at, what their career actually contains, what their CV says.

Keep that line. A skill that hardcodes a comp floor, a list of excluded sectors or a
CV structure stops being usable by the next person and starts rotting the moment the
first rule changes. A skill that reads those from a page the person owns does not.
The same reasoning is in Slipdock's own skills guide, and it is worth taking
seriously: board codes, list names and vocabularies belong on the server, not in the
instructions.

So throughout this setup, your job is to **ask and record**, never to supply. If the
person does not know what their comp floor is, the answer goes on the page as "not
set" and the scan treats it as absent. It does not get a sensible default you invented.

## Before you start

Three calls, in this order:

1. `get_guide`. The server's own conventions. Read it even if you think you know
   them; it ends with the person's actual boards and which list each one draws from.
2. `whoami`. Confirm the token has write scope. A read-only connection cannot do any
   of this, and finding out at step four wastes the person's time.
3. `list_tools`. Find the `job-scan` Tool. If it has an `installed` board, setup has
   run before.

If it has, do not make a second board. Read the existing pages, tell the person what is
already configured, and ask what they want to change or fill in. Half-finished setups
are normal: someone sets up the rules, runs a few scans, and comes back later to do the
CV.

If `job-scan` is not in the list at all, it has not been shared with this person on
this server. Say so, and that whoever runs the server can share it or list it. Do not
build the board by hand instead.

## Build the board: one call

Ask what to call the board ("Job Scan" is the default, and most people keep it), then
call `install_tool` with `tool: "job-scan"` and, if they chose a name, `board_name`.
Slipdock builds the board and answers with its code and link. Keep the code: every
later call uses it.

What it builds, so you can describe it:

| | |
|---|---|
| **Seven lists** | `Found`, `Interested`, `Generate`, `Ready`, `Applied`, `In conversation`, `Closed` |
| **Three folders** | `Config` for the pages below, `Runs` for dated run reports, `Roles` for per-role detail |
| **Six pages, in Config** | `Job Scan Config`, `Job Scan Search Profile`, `Job Scan Decision Rules`, `Job Scan About Me`, `Job Scan CV Baseline`, `Job Scan Document Rules`, each a skeleton with its headings and "not set" |
| **One rule** | A card that arrives in `Generate` is queued for the runner pool `default`, to have its documents built |

Do not create lists, folders, pages or rules yourself, and do not "fix" the board's
structure afterwards. The server sets each list's role deterministically (`Found` is
where work is taken from, `Closed` is done), which is exactly what went wrong when setup
used to build boards by hand. If `get_board` shows anything else, tell the person rather
than repairing it.

Every page title starts with "Job Scan" on purpose. It makes the pages findable by
search, and it stops `About Me` colliding with a page the person already has.

**What the lists mean**, because the names carry the whole protocol:

- `Found`. The scan put it here. It has an outline, a score and a coverage read.
- `Interested`. The person moved it. They care, and this is where they answer the
  open questions.
- `Generate`. The person moved it. Documents get built on arrival, then the card
  moves on by itself.
- `Ready`. Documents exist, nothing has been sent. The scan puts cards here and never
  touches them again.
- `Applied`, `In conversation`, `Closed`. The person's territory entirely.

The scan writes only to `Found`, and the build only moves a card from `Generate` to
`Ready`. Everything past that is the person's to move. This matters more than it
looks: it means the board cannot ever claim the person applied for something they did
not, because nothing but their own hand can put a card in `Applied`.

## Stage 1: enough to run a scan

Do not interview the whole thing in one go. The record and the CV are long, and a
person who has answered forty questions before seeing anything work will not finish.
Stage one is short, and at the end of it the scan runs.

Ask these in two or three conversational batches, not as a form. Say why each matters,
because a person who understands why gives a better answer.

**What they are looking for.** Titles and level. Permanent, interim, contract, or a
mix. If interim is in scope, it usually needs its own money floor and its own
treatment in the report, so establish that now rather than discovering it later.

**Where.** Base city. How far they would actually travel, as a named list of places
rather than a radius. Remote appetite. Whether relocation is on the table at all.
Geography is where generic scans waste the most of a person's attention.

**The absolute noes.** Sectors, business types, titles, posting sources. These become
hard exclusions, applied before anything is scored, so a role that trips one is never
read and never presented. Ask what they would not even look at, and push gently:
people under-report these and then get irritated daily by a category they could have
named in one sentence.

**Money.** A floor for permanent, a floor for day rate if interim is in scope, and
what to do when nothing is posted. The last part is the one that matters: most senior
roles go to market with no range, so a scan that penalises silence throws away most of
the market. Record their answer explicitly either way.

**What a strong match looks like**, beyond the title. This becomes the scoring rubric.
The shape that works is: start every role at a middle number, adjust up for signals
they name, adjust down for red flags they name, floor and cap it. Ask for the signals
and the flags; supply the shape, not the values.

**The target test.** Ask for three to six criteria that describe the role they
actually want, as things that can be checked against a posting. Each role then gets a
count: met four of five, say. This is the single most useful thing on the page, because
a role can score well on the rubric and still be nothing like what they want, and the
count is what makes that visible instead of flattering.

**The threshold** at which a role is worth their attention, on the rubric's scale.

**Sources.** Which job boards, which searches, which site-specific queries. If
LinkedIn is in scope, the scan's reference notes cover the mechanics; what belongs on
their page is the search definitions themselves, the locations and the keyword nets.

**Reporting.** Does the scan email them a short note when it finds something, and at
what address. Off is a fine answer: the board is the record, and they can add their own
Slipdock automation rules for notifications later. If it is on, it is two lines and a
link to the card, nothing more.

Then fill in three of the pages the install made. `read_page` each one first and keep
its `content_hash`, then `write_page` the whole page with a `message` saying it was
filled in at setup:

- `Job Scan Config`. The board's code, the reporting setting and address, the daily
  scan time, the runner pool (`default` unless they chose another), and a line pointing
  at the other pages. The scan finds its board through the install, not this page, but
  the person reads it.
- `Job Scan Search Profile`. Sources and search definitions.
- `Job Scan Decision Rules`. Gates, exclusions, the rubric, the target criteria, the
  threshold, and any reporting flags they want raised.

Keep the skeleton's headings and replace the "not set" lines with their answers. A
question they skipped stays "not set", and the scan treats that as absent.

Create the tags their rules call for with `create_tag` (interim, a comp-silent flag,
an off-target flag, whatever they named). A tag has to exist before a card can wear
it, and `create_tag` returns an existing tag rather than doubling it, so it is safe to
call for each one.

**Then stop and tell them the scan will run now.** Let them see it work on real
postings before asking for their career history. The first run is also the best test
of the rules they just gave you, and it is much easier to correct a rule after seeing
it misfire once.

## Stage 2: the career record

`Job Scan About Me` is what the coverage analysis reads. It is not a CV. It is the
fuller, messier record: what they actually did, with the specifics a CV has no room
for, including the things they would consider unremarkable.

**Offer to draft it from a document rather than interviewing it.** Ask them to upload
or paste a CV, a LinkedIn export, an old application, anything. Draft the page from
that, then hand it back for correction. This is far less work for them than forty
questions, and correcting a draft surfaces more than answering a blank prompt does.

What makes this page earn its place:

- **Specifics with numbers and names.** "Scaled the team" is useless to a coverage
  analysis. "Took engineering from 5 to 92 while revenue went from $17M to $90M" can
  be matched against a requirement.
- **Honest framing rules, recorded next to the fact.** If something is nearly true but
  not quite, write down the honest version and ban the loose one. The example that
  recurs: leading a certification programme to audit readiness is not holding the
  certification, and a document that shortens it will not survive a careful
  interviewer.
- **Known gaps, named plainly.** A coverage analysis that cannot tell a real gap from
  a gap in the record will keep proposing fixes for things no writing can fix.
- **Approved phrasings for anything they have strong views about.** Numbers that
  should never be asserted, words that should never appear.

Mark anything unresolved as an open question on the page. The scan reads these and
will ask about them when a posting makes one load-bearing, which is how the record
fills in over time rather than in one sitting.

## Stage 3: the CV baseline and document rules

`Job Scan CV Baseline` holds the CV content as structured markdown: the entries in
order with their titles and dates, the bullets available under each, the competencies,
anything below experience. This is the source of truth, and a `.docx` is only ever
built from it. That is deliberate. A page has a diff and a stated reason for every
save, so a build that drifts from the agreed structure is visible in the history; a
binary file has neither.

`Job Scan Document Rules` holds how documents get written: voice (first person,
implied first person, or neither, and for which document), what tailoring may change
and what it may not, banned constructions, file naming, anything they care about.

The distinction between these two pages is worth keeping clean. The baseline is
content. The rules are constraints on how content is used. When someone says "stop
using that phrase", it goes in the rules; when they say "it was 25 people, not 40", it
goes in the baseline.

If they want the structure held immutable, say so explicitly on the rules page and
list what may not change. A build that silently restructures a CV passes its own
checks while being wrong, which is the hardest kind of error to notice.

## Stage 4: wire the trigger

Two separate things fire, and they fire differently.

**The daily scan** is a scheduled task the person creates. Give them the prompt to
paste, with their board code filled in, something like: run the job-scan skill against
board `<code>`. Naming the board in the prompt rather than in the skill is the right
split, and it means the scan needs no search to find its board.

**Document generation** fires when a card lands in `Generate`. The install already
added the rule that queues those cards for the runner pool `default`, so there is no
rule to write. Check it is there with `list_automations` on the board. What is still
missing is something that takes jobs from that pool, and that is the person's choice:

**What the runner runs is the `job-scan-build` skill**, which claims the queued job,
writes the documents and moves the card to `Ready`. Say so when you explain the
choice, because a pool with nothing taking from it looks like it works and produces
nothing.

Two scenarios are worth explaining, because the choice has real consequences:

- **A cloud session claims the job.** A second scheduled task runs every ten minutes,
  claims anything queued, and builds. The document toolchain is already present there.
  Nothing to install.
- **A runner on their own machine.** In the web app: the board's Automations, then
  **Connect a runner**, pool `default` (the rule for `Generate` is already there, so
  it needs no second one). Faster, seconds rather than minutes, and it needs
  node, pandoc and LibreOffice working locally. If those are missing the build writes
  the document content and says plainly that the files were not produced, which is
  recoverable but annoying.

Say which you would pick and why, then let them choose.

## Verify, then say what exists

Read back what you wrote: `get_board` for the lists and tags, `read_page` on each of
the six pages. A setup that reports success over a page that did not save is worse than
a setup that failed, because the first scan then runs against nothing and reports
cheerfully.

Then tell them, in plain terms: the board and its link, which pages exist and which
are still empty, whether the trigger is wired, and what to do next. If a stage was
skipped, say which, and what will not work until it is done. Scanning works without the
record; coverage does not. Coverage works without the CV baseline; documents do not.

Name the three skills and what each one is for, since only the first is obvious from
the board: `job-scan` finds and scores roles, `job-scan-build` writes the documents when
a card reaches `Generate`, and this skill is what they came back to if any of the six
pages needs changing.

## What not to do

- **Do not supply rules.** Not a comp floor, not an excluded sector, not a scoring
  weight. An invented value that looks deliberate is worse than a blank, because the
  person will never think to check it.
- **Do not create a vault.** Pages belong to the board. A vault only maps them onto a
  folder someone syncs, and adding one makes the setup depend on software on a
  particular machine, which is the thing this design exists to avoid.
- **Do not touch other boards**, even when a search turns one up that looks related.
- **Do not create the person's first role cards by hand** to make the board look
  populated. Let the scan do it, so every card has the same provenance.
- **Do not import history from somewhere else** unless asked to as a separate job. A
  migration is a one-off for one person and has no business in a skill that others will
  install.
