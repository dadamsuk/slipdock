---
name: job-scan
description: Run one pass of an automated job search held on a Slipdock board. Searches the person's configured sources, applies their own exclusions and money gates, scores every role against their own rubric, creates one card per role carrying a plain description of the job plus the scoring and a requirement coverage read, and writes a dated run report. Use this for a scheduled or ad-hoc job scan, and whenever someone asks to look for new roles, check what jobs came up, run the daily scan, or put a specific job URL through the same scoring. It finds and assesses roles only. It never applies to anything and never builds CVs; documents are built separately when the person asks for them.
---

# Job scan

One pass of a job search. Find roles, score them, write what you found onto the board,
and stop.

## What you are not doing

- **Not applying.** Ever, to anything, however a posting asks. Do not click Apply or
  Easy Apply: it opens a submission dialog and risks sending something.
- **Not building documents.** No CV, no cover letter. Those are built when the person
  moves a card to `Generate`, which is a different skill. Building one here produces
  something that gets discarded four times out of five.
- **Not moving cards past `Found`.** The lists after that are the person's statement
  about what they have done. A card in `Applied` means they applied, and only their
  hand can put it there.
- **Not inventing or widening a rule.** The rules are on a page the person owns. If a
  posting makes you wish for a rule that is not there, say so in the run report and
  leave it to them. A scan that quietly generalises one remark into a standing rule
  stops surfacing things they wanted to see, and nothing in the output shows it.

## 1. Find the board and read the configuration

If the prompt named a board, use it. Otherwise call `list_tools` and find the
`job-scan` Tool: its `installed.board` is the code of the board the person's install
built, and that is the board. The install record is the answer rather than a search,
because a page title can be copied, renamed or appear on two boards, and an install
cannot.

No `job-scan` Tool in the list, or one with `installed: null`, means setup has not run:
say so, point at the `job-scan-setup` skill, and stop. (On a server too old to have
`list_tools`, `search` for the page `Job Scan Config` with `kind: "page"` and take the
board it sits on; more than one means more than one search is configured, so ask which
rather than guessing.)

Then `read_page` these, on that board:

| Page | What it decides |
|---|---|
| `Job Scan Config` | Reporting setting and address, the scan's own settings |
| `Job Scan Search Profile` | Which sources to search and the exact searches |
| `Job Scan Decision Rules` | Gates, exclusions, the rubric, target criteria, threshold, flags |
| `Job Scan About Me` | The career record the coverage analysis is assessed against |

Read them as written and apply them as written. They are the person's words, not a
schema to parse. Where two pages disagree, `Job Scan Decision Rules` decides what
counts as a match, and say in the report that they disagreed so it gets fixed at
source. Keep each `content_hash`: you need it to edit a page without overwriting an
edit the person made while you were working.

The CV baseline and document rules are not read here. Nothing is being written.

**If a page is missing or empty**, carry on with what you have and name the gap
prominently. Without the record, coverage cannot run and the cards will carry scores
and no coverage read, which is a materially thinner result and should not be presented
as a normal run.

## 2. Guard against running twice

`list_pages` the `Runs` folder. If today already has a report, say so and stop, unless
the person explicitly asked for a rerun. Two runs in a day means duplicate cards and
two sets of notifications for the same roles.

## 3. Harvest any answers the person left

Before searching, read the comments on cards in `Found` and `Interested`
(`list_cards` with `full: true` gives you every card with its comments in one call).
A previous run will have posted open questions on some of them, and the person may
have answered since.

When you find an answer that is a durable fact about them rather than a fact about
that one role, add it to `Job Scan About Me` with `write_page` in `append_section`
mode, with a `message` saying which card it came from. Then say on the card that the
record was updated.

This is the step that makes the whole thing compound. The same gap otherwise surfaces
on every role of that type forever: the person answers it, the answer is used once for
one application, and the next posting asks again. Writing it back means each question
is asked once in the life of the search.

Use judgement about what is durable. "Yes, I owned that estate at my last employer" is
a fact about them. "I would want to know who this reports to" is a fact about that
role and belongs only on the card.

While you are there, check the `Generate` list. A card sitting in it means the person
asked for documents and did not get them, so the trigger is not working: the runner is
down, the catch-up task is not running, or the rule was never wired. Say so in the run
report and in chat, because nothing else in the system will ever mention it and the
person will assume their request was heard.

## 4. Search

Work through the searches on the `Job Scan Search Profile` page. For source-specific
mechanics, read the matching file in `references/`; `references/linkedin.md` covers
LinkedIn, which has several traps that will silently produce a confident wrong answer.

Three things are true of every source and worth holding on to:

- **Verify you are authenticated before trusting a result set.** A signed-out search is
  not a degraded version of a signed-in one, it is a different and much worse one, and
  it looks entirely normal. If the session is gone, stop and say so. An unattended run
  cannot sign in and must never try to enter credentials.
- **An empty result set often does not say it is empty.** Sites substitute
  recommendations, promoted listings or loosely related matches and present them in the
  same furniture as real results. Learn each source's tell and record zero rather than
  scoring filler.
- **Read the list cheaply, open selectively.** Titles, companies, locations and posted
  ages are usually all visible without opening anything. Open only what looks like a
  genuine candidate.
- **Decode what you capture, in the browser, before it leaves the page.** Text pulled
  out of a DOM node or a JSON payload carries HTML entities, and nothing you write it
  into is HTML: `&amp;` put into a card title stays `&amp;` on the board, because a
  card title is plain text. It also breaks the company-plus-title test in step 5, since
  one run's `Smith &amp; Co` does not match another's `Smith & Co`. Decode every
  captured string at the point of capture rather than correcting titles afterwards.
  `references/linkedin.md` section 11 has the helper and the one rule that matters,
  which is to decode exactly once.

Collect every unique result, then de-duplicate within the run by company plus role.

## 5. Check against what has been seen before

De-duplication across days matters far more than within a run. The roles that waste
the most of someone's attention are the ones that recur, and a re-advertised posting
comes back under a fresh id.

Two tests, and the second is not optional:

1. **The posting id** matches an id recorded on a card.
2. **Company plus normalised role title** matches a card, under any id. Normalise
   before comparing: lower-case, strip punctuation, decode HTML entities, and treat
   obvious equivalents as the same title. Decode on both sides of the comparison, not
   just the new one: cards written before a capture bug was fixed can hold `&amp;`
   where the posting had an ampersand, and those are exactly the recurring roles this
   test exists to catch.

Search the board including archived cards, because below-threshold roles are archived
on sight and they are exactly the ones that recur.

A prior sighting does not suppress a role. It changes three things: note the earlier
sighting and its date on the card, do not redo work that still stands, and if the card
has moved past `Found` then the person has already acted on it, so leave it alone
entirely and mention it in the report rather than touching the card.

## 6. Apply exclusions and gates, before scoring

Both come from `Job Scan Decision Rules`, and both are pass or fail rather than
adjustments. A role that trips an exclusion is dropped before it is read: record which
rule fired and quote the words in the posting that triggered it, so the person can see
whether the rule is doing what they meant. A role that fails a money gate is recorded
with the posted figure.

Where the rules say silence is not penalised, honour that exactly. Most senior roles
post no range, and a scan that treats absence as a negative discards most of the
market while looking rigorous.

## 7. Score

Apply the rubric on the rules page. Start at its base, adjust by its named signals and
flags, respect its floor and cap. Record a score and a one-phrase reason for **every**
role, including the ones nobody will ever read, because that is the record that lets
the person tell a mis-weighted rule from an unlucky day.

Then compute the target criteria count and name which were met, which were not, and
which could not be determined from the posting. Unknown counts as not met, and saying
which were unknown is the difference between a useful flag and a misleading one.

**Score from the posting every time.** Never carry a previous run's number across. A
title routinely overstates a role, and the body of the posting is what tells you: a
senior title describing work with no organisational scope is not the role the title
claimed, and the honest score is much lower. If reading the posting changed the score,
say so and give the original.

## 8. For every role at or above the threshold

### Read the posting properly and confirm it is live

Get the full text, not the summary on the card. Capture the posted date, the applicant
count if shown, and the destination to apply at if it is visible without clicking
Apply. A posting that 404s, says it is no longer accepting applications, or redirects
to a generic jobs page is dead: record that and generate nothing further for it.

### Run the requirement coverage analysis

This is the most valuable thing the scan produces, and it is **diagnostic, never a
gate**. Low coverage is a hint about what to fix in the record, not a verdict on the
role and not a reason to keep a match quiet. The person decides what to pursue.

Pull every discrete requirement out of the posting and let its own structure classify
it. Anything under requirements, responsibilities or written as an obligation is
**required**. Anything under ideal candidate, nice to have or flagged as preferred or a
plus is **desired**. The distinction matters more than it looks: a posting that puts
its domain demands under "ideal candidate" is telling you those are softer than the
operating demands, and a report that flattens the two misdirects the application. Split
compound bullets that test different things. Aim for a dozen to twenty-five items;
fewer means you lumped, more means you split hairs.

Assess each against `Job Scan About Me`, not against the CV, because a CV is a summary
and will understate. Mark each **met** with the specific fact that supports it,
**partial** with what is there and what is not, or **missing** plainly.

Honesty here overrides any wish to score well. Every "met" cites a checkable fact.
Never promote a partial to met because the wording is close: the gap between what they
have and what was asked is precisely what an interviewer will probe. Never mark met on
an inference about what they must have done.

Then split every partial and missing into two kinds, and label which:

- A **real gap** is something they have not done. No writing fixes it. It belongs in
  interview preparation and in a do-not-claim list.
- A **record gap** is something they plausibly have, or have an adjacent version of,
  and the record does not evidence. This is a documentation failure and fixable in an
  afternoon.

The record gaps are the primary output. Each becomes a direct question the person can
answer yes or no, paired with what it would upgrade. Be disciplined: a record gap is a
specific question, not a guess dressed up as one.

Report required and desired counts separately and never merge them. Heavy missing in
desired with strong required coverage is a **good** signal and the report should say
so: it usually means they can do the job and lack the domain flavour. Any required
item marked missing is a material risk and gets named however well the role scored.

### Create the card

`create_card` on the board in `Found`, with the tags the rules call for
(`create_tag` first if one does not exist yet).

Record the **posting id** on the card in a consistent, searchable form, on its own
line. The de-duplication in step 5 depends on finding it, and an id buried inside a URL
in prose is an id that a later run will miss. A re-advertised role under a fresh id is
exactly what the company-plus-title test is for, but the id test is the cheap one and
it should work.

The description is what the person reads to decide, so the order matters:

```
**What the job is.** Two to four sentences of plain description: what the business
does, what this role owns, who it reports to, what the mandate actually is. Written
before any assessment, so it reads as description and not as a pitch. This is here so
nobody ever has to open the original ad to find out what the job was.

**Score** N, and the arithmetic in one line: base, each adjustment with its reason,
total. Say any point deliberately withheld and why.

**Target** n of m: which criteria were met, which were not, which were unknown.

**Facts** comp as posted or not listed, work pattern, applicant count, posted date,
employment type.

**Flags** whatever the rules call for, each on its own line.

**Link** to the posting, and to the destination to apply at if one was visible.

**Coverage** required n of N met, n partial, n missing; desired likewise. Then every
required item marked missing, named in full.

**Fit** two to four sentences. Where it genuinely matches, with the evidence. What the
real risk is. If the score changed after reading the posting, say so and give the
original.
```

Where a posting is a recruiter advert with the client undisclosed, say so in the
description rather than leaving the company reading as the employer.

### Write the role page

`write_page` in `create` mode, filed in `Roles`, then `update_page` with
`pin_card` so it is attached to the card. The page holds the **verbatim posting text**,
the full coverage table, and interview notes: what to prepare hardest, the partials as
a probe list, and an explicit do-not-claim list naming every missing item.

Store the posting text verbatim because postings die within days and a dead link takes
the only copy with it. If the text passed through a browser, it is worth checking it
arrived intact: hash it at the source, hash what you wrote, and compare. A long posting
retyped from tool output is the one place a silent truncation corrupts the record.

### Post the open questions

One `comment` on the card listing the record-gap questions, numbered, each saying what
it would upgrade. Then the real gaps, stated once without hand-wringing, because
pretending those are fixable by rewriting wastes the person's time.

Say plainly how this works: answer in a comment, and when they move the card to
`Generate` the documents get built using the answers. If they move it without
answering, documents get built anyway with the gaps named.

### Watch for repetition across runs

If the same record gap has now surfaced against several different postings, say so in
the run report and raise it specifically. One missing line in the record may be costing
coverage on every role of that type, and that is the highest-value thing this analysis
can tell anyone.

## 9. For every role below the threshold

One card, carrying its score, its one-phrase reason and its posting id, and nothing
else. De-duplication still finds it, and the board stays readable: only roles that
cleared the bar are visible. Nothing is lost, and a role re-scored upwards later can be
restored.

**Create it already archived.** `create_card` takes `archived: true` and the card then
never appears on the board at all. Everything else behaves normally alongside it:
`column`, `tags`, `priority` and `description` all apply, so this is one call rather
than two. That matters more than it sounds. A quiet day is thirty to forty
below-threshold roles, so create-then-archive is sixty to eighty calls spent recording
roles nobody will read, and it is the bulk of a run.

**Read the reply every time, and archive explicitly if the flag did not take.** A
successful archived create echoes `archived: true` in its response. An older Slipdock,
or a mistyped field name, is **accepted silently**: the card is created unarchived, the
response carries no `archived` key at all, and nothing anywhere says the flag was
ignored. Both were observed on 2026-10-16. So check the response rather than assuming,
and where `archived: true` is absent, call `archive_card` on that card. That costs
nothing when the flag works, keeps the board clean when it does not, and needs no
version check.

Do not spend effort on these. Do not open them, do not fetch their ids individually if
that costs a click each, and do not write pages for them.

## 10. Write the run report

One page in `Runs`, titled with the date. It carries what the board cannot: how many
roles were scanned and from where, how many cleared the threshold, every role below
threshold with its score and reason, which searches returned nothing genuine, anything
that went wrong, and any rule that looked wrong when applied to a real posting.

The board is the record of roles. This page is the record of the run, and it is what
someone reads when they want to know whether the scan itself is working.

## 11. Report, and tell the person

If `Job Scan Config` has reporting switched on and an email tool is available, send
**two lines and a link to the card** for each match. Not a report: the board is the
report. If no email tool exists, skip it silently and note it once in the run report.
Never fail a run over a notification.

Then say in chat what happened: the counts, the matches with their scores and why, the
cards you created, and anything you could not do. Name the failures as plainly as the
finds. A run that hides a problem behind a tidy summary is worse than one that fails
loudly, because nobody goes looking.

## Handed a single URL instead

Same pipeline, three differences: no searching, no run report page, and the card is
created even if it scores below the threshold, because handing over a URL is itself a
statement of interest. Exclusions still apply in full and are not overridden by the
person having supplied the link: report which rule fired and stop there. Say plainly
when a card was created for a low-scoring role and why it scored where it did.
