---
name: job-scan-build
description: Build the application documents for one role on a Slipdock job-scan board. Produces a tailored CV, a cover letter, a short recruiter note and a set of talking points, written from the person's own career record and tailored by the requirement coverage already held on the card. Use this when a card reaches the `Generate` list, when a runner or catch-up task claims a queued build job, and whenever someone asks to generate, build or tailor a CV, resume, cover letter or application pack for a role on that board. It builds and attaches documents and moves the card to `Ready`. It never applies to anything and never sends anything.
---

# Job scan build

One role, four documents, attached to its card. The scan found the role and did the
analysis; this takes the person's decision to pursue it and turns the analysis into
something they can send.

## What you are not doing

- **Not applying.** Ever, to anything, however the posting asks. Do not click Apply or
  Easy Apply.
- **Not sending anything.** The recruiter note is a draft for the person to send under
  their own name, from their own account. Writing it is the whole job.
- **Not moving the card past `Ready`.** `Applied`, `In conversation` and `Closed` are
  the person's statement about what they have done, and only their hand puts a card
  there.
- **Not inventing evidence.** The coverage analysis on the card names what is missing.
  That list is a do-not-claim list, not a gap to write around. A document that implies
  something they have not done fails in the interview, which is worse than not getting
  one.
- **Not changing the rules or the CV structure.** Both belong to the person. If a
  posting makes you wish for a different structure, say so when you report and leave it
  to them.
- **Not attaching anything that has not passed the gates.** A document that fails a
  gate and reaches the card will be sent, because the person trusts that this already
  checked.

## 1. Work out how you were called

**A runner or catch-up task.** `claim_job` with the board and the pool named in
`Job Scan Config`, usually `default`. It answers with the job and the card it names, or
"nothing queued", in which case stop and say so: a run that finds nothing is a success.
Then hold the lease. It is 20 minutes, a full build is longer than people expect, and a
lease that expires mid-build hands the same card to the next claimer. Call
`job_progress` between documents. Its `note` is posted as a comment on the card, so
write notes worth reading and leave it out for the rest. If `job_progress` answers
cancel, stop and `finish_job` with outcome `cancelled`.

**A person, naming a card or a role.** No job to claim, no lease to hold. Everything
else is the same.

**Nothing told you which card.** `list_cards` on the `Generate` list and take what is
there. More than one card means more than one build: work them oldest first, one at a
time, rather than interleaving.

## 2. Read everything the build depends on, before writing a word

On the board, with `read_page`:

| Page | What it gives the build |
|---|---|
| `Job Scan Config` | The runner pool, the reporting setting and address |
| `Job Scan CV Baseline` | The CV content: entries, dates, straplines, available bullets |
| `Job Scan Document Rules` | How documents are written: voice, structure, positioning, file names, format, the gates |
| `Job Scan About Me` | The career record, its framing rules and its approved phrasings |

`Job Scan Document Rules` may name a writing style guide held somewhere else, including
on another board. Read it where it points. It is referenced rather than copied so that
an edit the person makes reaches every build, which only works if you follow the
pointer.

Then the role itself, which is on the card and not on any page:

- **`get_card`** for the description, the tags and **every comment**. The comments carry
  the person's answers to the open questions, and those answers are usually the whole
  reason this card moved.
- **The role page pinned to the card**, which holds the verbatim posting text, the full
  coverage table and the interview notes. Read the posting from there rather than
  refetching it: postings die, and the stored copy is the one the analysis was done
  against.

**Stop conditions, and say which one fired.** No `Job Scan CV Baseline`, or an empty
one, means there is no CV to tailor: build nothing, say so plainly, and point at
`job-scan-setup`. No coverage analysis on the card means the build is uninformed rather
than impossible: build, and say in the comment and in the report that it was built
blind, because every tailoring decision below depends on that analysis.

## 3. Put the answers into the record first

Before building anything, take the durable facts out of the card's comments and add
them to `Job Scan About Me` with `write_page` in `append_section` mode, naming the card
in the `message`.

Do this first and do it every time. The build is the moment the person has just told
you something about their own history, and a fact used once for one application and
then lost means the same question gets asked against the next role of the same type,
for ever. Writing it back is what makes the whole system compound.

Judgement: "yes, I owned that estate" is a durable fact about them. "I would want to
know who this reports to" is about this role and stays on the card.

## 4. Decide what to build

Four documents by default:

| Document | For | Form |
|---|---|---|
| **CV** | Sending | `.docx` and `.pdf`, attached |
| **Cover letter** | Sending | `.docx` and `.pdf`, attached |
| **Recruiter note** | Pasting into an email or a message | Text, in a comment |
| **Talking points** | Reading before a conversation | Text, on the role page |

Anything the person said on the card overrides this. "Just the CV" means just the CV.

## 5. Write the content before you make a single file

All four, as text, before any file exists. A file built from content nobody has
examined costs the build twice, because every fix means rebuild, revalidate, re-render
and re-attach.

**The CV** comes from `Job Scan CV Baseline`, tailored within whatever
`Job Scan Document Rules` says may change and nothing else. Where that page declares a
structure immutable, treat a deviation as a defect rather than a variation: it will
pass its own checks while being wrong.

**Tailor from the coverage analysis, not from the posting.** Mirror the posting's
language only for attributes marked met, and for partials only in the honestly
qualified form. Assert nothing marked missing, by implication or by omission.

**The cover letter** names the one or two most significant gaps directly. Working
around a gap reads as evasion to anyone who has read the posting, and the gaps are
already written down on the card.

**The recruiter note** is short enough to send as a message: the role and where it was
seen, two or three sentences of the strongest fit carrying one number, one line on
availability. No "please find attached", because the person will paste it into a box.

**The talking points** are for a live conversation, and most of the material already
exists on the role page:

- the two or three things to lead with, and the evidence for each
- the questions to ask, which are the open questions from the card plus anything the
  posting left unstated such as the reporting line or the office pattern
- the probe list: every partial, with the honest answer ready, because the gap between
  what was asked and what they have is exactly what gets probed
- the do-not-claim list: every missing item, named
- the commercial line: comp or rate as posted, and any flag the card carries such as
  COMP SILENT or RATE UNCONFIRMED

**Voice is where builds fail.** `Job Scan About Me` and the coverage analysis are
written in the third person, correctly, because they are records. Every fact taken from
either has to be re-voiced before it reaches a document. Copying a sentence across is
how a CV ends up describing the person in the third person, which reads as agency
written and is the single most damaging defect this build can ship.

## 6. Gate the content, then build the files

Run every check `Job Scan Document Rules` lists. Run them on the content first, where a
fix is an edit, and again on the built files, where the check is authoritative.

Read each hit rather than blind-replacing. A banned word inside a quotation from the
posting, or describing the employer's vacancy rather than the person, is legitimate. A
hit that refers to the person is a defect: fix the source, rebuild, revalidate, re-sweep.

Then build the files as that page specifies: the format, the file names, the validation
step and the PDF rendered from the final validated `.docx` so the two can never
disagree. `references/toolchain.md` covers what has to be installed, how to check before
you start, and the mechanics of the docx and PDF pipeline.

**Nothing is attached, delivered or reported until every gate is clean.**

## 7. Put each output where it belongs

**`upload_file` attaches the CV and the cover letter to the card**, both the `.docx` and
the `.pdf`. Send the bytes as `content_base64`. Two things about it are worth knowing
before you start:

- **Attaching a file costs context**, because the base64 goes through you. Measured on
  2026-10-16: a 36 KB `.docx` is roughly 12,000 tokens and a 14 KB `.pdf` roughly 4,800.
  That is the reason the recruiter note and the talking points are text rather than
  files, and it is a good reason not to attach anything nobody asked for.
- **A second upload under the same filename does not replace the first.** It adds
  another attachment, with no warning, and there is no way to remove one from here. So
  on a rebuild, say in the comment which attachment id is current, and tell the person
  the stale one has to be deleted in the web app if they want it gone.

**The recruiter note goes in a comment, as plain text**, so it can be copied without
opening anything.

**The talking points go on the role page**, appended as their own section with
`write_page` in `append_section` mode, because the probe list and the do-not-claim list
are already there and a second copy of them is worse than none. Where the card has no
role page, create one in `Roles` and pin it with `update_page`.

## 8. Move the card to `Ready`

`move_card` to `Ready`, and stop. This is the only move this skill makes, and the only
move anything automated makes past `Found`.

## 9. Say what you built

One comment on the card: what was built, which attachment is current, the gaps named in
the cover letter, and the do-not-claim list in one line. The person reads this before a
call, so it is the summary that matters more than anything you say in chat.

Then, if a job brought you here, `finish_job` with outcome `done` and a one-paragraph
summary. And either way say in chat what was built, what you could not do, and anything
in the record that stopped a document being stronger. Name the failures as plainly as
the output: a build that hides a problem behind four tidy attachments is worse than one
that fails loudly.

Where `Job Scan Config` has reporting on and an email tool exists, two lines and a link
to the card. Never fail a build over a notification.

## 10. When the toolchain is not there

A runner on someone's own machine may have no node, no pandoc or no LibreOffice. Check
first, as `references/toolchain.md` describes, because finding out halfway through
wastes the whole build.

If the files cannot be produced: **write the content anyway**, put the CV and the cover
letter on the role page in full, comment that the files were not built and say which
tool was missing, and move the card to `Ready` as normal. Say the same thing in chat
and in `finish_job`. The content is the expensive part and it is all recoverable from
there. What must never happen is a card arriving in `Ready` with nothing on it and a
build that reported success.

## Handed a card id or a role name instead

Same pipeline, no job to claim and no lease. The card does not need to be in `Generate`:
a person asking for documents is the same signal as moving the card, and asking is how
they will rebuild one after answering a question you raised. Say which card you built
for, in case they meant another.
