# Job search: generate

One card, five outputs. The scan found the role and analysed it; the person moved the
card to `Generate` because they want to apply. This turns the analysis into what they
send:

| Output | Form | Where it goes |
|---|---|---|
| CV | .docx and PDF | Attached to the card |
| Covering letter | .docx and PDF | Attached to the card |
| Recruiter LinkedIn message | Text, 300 characters or fewer | A comment on the card |
| Recruiter email | Text, with a subject line | The same comment |
| Talking points | Text | Appended to the role page |

Anything the person said on the card overrides the list: "just the CV" means just the
CV.

## What you are not doing

- **Not applying, and not sending.** Never click Apply. The message and the email are
  drafts the person sends from their own accounts.
- **Not moving the card past `Ready`.** `Applied`, `In conversation` and `Closed` are
  the person's statement of what they did.
- **Not inventing evidence.** Every item the gap analysis marked missing is on a
  do-not-claim list, not a gap to write around. A document that implies something the
  person has not done fails in the interview.
- **Not changing the CV's structure or the person's rules.** Both are theirs. If a
  posting makes you want a different structure, say so in your report.
- **Not attaching anything that failed a check.** The person trusts that what reaches
  the card was checked, and will send it.

## 1. How you were called

- **A runner job.** The prompt names the card and the job, or you claimed one:
  `claim_job` with the board and pool `generate`. "Nothing queued" means stop: a run
  that finds nothing is a success. Hold the lease: it is 20 minutes and a build is
  longer than it looks, so call `job_progress` after each step below. Its `note`
  becomes a comment on the card, so pass one only when it tells the person something.
  If it answers `cancel`, stop and `finish_job` with outcome `cancelled`.
- **A job sent again after a wait was answered.** `claim_job` hands back the wait and
  its answer with the job. Start at step 3 with that answer in hand.
- **A person naming a card or a role.** No job and no lease; everything else is the
  same. The card need not be in `Generate`: asking is the same signal.
- **Nothing says which card.** `list_cards` on `Generate` and work them oldest first,
  one at a time.

Find the board as the scan does: the prompt, else `list_tools` with
`{"tool": "job-search"}` and its `installed.board`.

## 2. Read everything before writing a word

On the board (`read_page` by title, keeping each `content_hash`):

| Page | What it gives the build |
|---|---|
| `Candidate Facts` | Everything known about the person, each fact with its source, date, framing rule, and whether it is confirmed |
| `CV Baseline` | The CV's fixed structure (entries, dates, section order) and default content. Its attachments include the style template, `cv-template.docx` |
| `Writing Rules` | Voice, banned phrases, positioning, what tailoring may change, file naming, and the ` ```build ` and ` ```checks ` blocks the build script reads |
| `Criteria` | The flags, for the commercial line in the talking points |

`Writing Rules` may point at a style guide kept elsewhere, even on another board.
Follow the pointer and read it: it is referenced so that an edit reaches every build.

Then the role:

- **`get_card`**, with every comment. The comments carry the person's answers.
- **The role page** pinned to the card (in `Roles`): the posting verbatim, the coverage
  table and the interview notes. Work from the stored posting, never a refetch.

Stop conditions, and say which fired:

- **No `CV Baseline`, or still a skeleton:** nothing to tailor. Build nothing; point at
  `job-search-setup`. With a job, `finish_job` `failed` with that reason.
- **No coverage on the card or the role page** (a card made by hand, or restored):
  run the gap analysis first, exactly as the scan procedure's step 8 describes
  (`skills/job-search-scan/references/procedure.md`), write it to the role page and the
  card, and say you did.

## 3. Put the answers into the record

Read every comment and any wait answer on the card. Each durable fact about the person
("yes, I ran that budget", "it was 30 people, not 25") goes on `Candidate Facts` with
`write_page` `append_section`, under the section it belongs to, recording:

- the fact, in the person's terms;
- its source: `card #N, comment of YYYY-MM-DD` or `wait answered YYYY-MM-DD`;
- any framing rule the answer implies ("say audit-ready, never certified");
- that it is **confirmed**, since the person said it.

Where the answer confirms a fact already marked unconfirmed, change that fact's marker
rather than adding a second copy (`replace_section`, with the hash). A fact about the
role rather than the person ("I'd want to know who it reports to") stays on the card.

This is what makes the system compound: each question is asked once in the life of the
search, not once per role.

## 4. Anything still open? One wait, then park

Before building, list everything the documents need and do not have:

- **Unanswered questions** from the card's `Questions` section (an answer of "skip" or
  "don't know" counts as answered: build without it);
- **Unconfirmed facts** the documents would rely on: anything on `Candidate Facts`
  still marked unconfirmed that you mean to put in the CV, the letter or the messages;
- anything the posting needs that nothing in the record covers and that the person
  could plausibly supply in a sentence (a notice period the advert asks for, say).

If the list is empty, go to step 5. Otherwise open **one** wait with all of it, never
one per question:

- **In a runner job:** `finish_job` with outcome `waiting` and `wait`:
  `{"needs": "<the questions, numbered, each answerable briefly>"}`. That parks the
  job; the answer starts a fresh one, which arrives with the answer on top.
- **Without a job:** `update_card` with `wait` the same way, and stop.

Say in the wait what each answer changes ("3. Yes → the CV can claim the budget
ownership the posting requires"), and that "skip" is a fine answer. Keep `needs` under
**1,000 characters**: a longer one is refused and the job is not parked. Only a person
can answer a wait an agent opened, so never answer it yourself. Then stop: do not
build half the documents while waiting.

## 5. Write the content first, as text

All five outputs, as markdown, before any file exists. A file built from content
nobody examined costs the build twice.

**Voice is where builds fail.** `Candidate Facts` and the coverage analysis are
written in the third person, because they are records. Every fact taken from them is
re-voiced into the voice `Writing Rules` gives for each document. Copying a sentence
across is how a CV ends up saying "he built".

**The CV** comes from `CV Baseline`, tailored only within what `Writing Rules` says
tailoring may change. What it says is fixed is fixed: a deviation passes its own checks
while being wrong. **Tailor from the coverage analysis, not the posting:** mirror the
posting's language only for items marked met, and for partials only in the honestly
qualified form. Assert nothing marked missing, by implication or by omission.

The CV is markdown laid out for the template:

```
# Name

::: {custom-style="Contact"}
phone | email | profile link
:::

::: {custom-style="Headline"}
The headline title
:::

## Section heading

Body paragraph.

### Title | Company | 2019 to 2026

::: {custom-style="Strapline"}
The one-line description of the employer.
:::

- A bullet
- Another bullet

**Label:** a competency line
```

**The covering letter** uses the same template: the name and contact block, then the
letter as body paragraphs. It names the one or two most significant gaps directly:
working around a gap reads as evasion to anyone who has read the posting.

**The LinkedIn message** to a recruiter: 300 characters or fewer, counted, including
spaces. The role, the strongest fit with one number, a line asking to talk. No
attachment language: they may never see a file.

**The email** to a recruiter: a subject line, then a short body: the role and where it
was seen, two or three sentences of the strongest fit carrying one number, one line on
availability if the person gave one. No "please find attached" unless the person will
attach the files.

**The talking points**, written to the person, for a live conversation:

1. the two or three things to lead with, each with its evidence;
2. the questions to ask: anything the posting left unstated (reporting line, office
   pattern, comp range) and any open question from the card;
3. the probe list: every partial, with the honest answer ready;
4. the do-not-claim list: every missing item, named in full;
5. the commercial line: comp or rate exactly as posted, and every flag on the card.

## 6. Check the content, then build the files

### Get the tools

Into one working folder:

- **The build script**, `skills/job-search-generate/scripts/build_docs.py`, fetched
  from the server the way this procedure was (MCP `list_tools` with the `file`, or
  `slipdock tools file`, or the API). Save the text exactly. A copy also sits beside the
  skill in `scripts/`.
- **The template:** the `cv-template.docx` attachment on `CV Baseline`. Get it with
  `download_file` with `link: true`, then `curl -fsSo cv-template.docx "<download_url>"`
  (single use, ten minutes, no token needed). Never through base64: binary files
  corrupt above about 1 KB that way. No template on the page: say so, and make a plain
  one with `python3 build_docs.py template --out cv-template.docx` so the build still
  runs; the person should run setup to build theirs.
- **The rules:** `Writing Rules` saved as `rules.md`, exactly as `read_page` returned it.

Check the toolchain before starting: `pandoc`, `soffice` (LibreOffice) and `pdftotext`
and `pdfinfo` (poppler). If one is missing, see step 10.

### Build

```sh
python3 build_docs.py build cv.md --kind cv --template cv-template.docx \
  --rules rules.md --out out --name "<file name from Writing Rules>"
python3 build_docs.py build letter.md --kind letter --template cv-template.docx \
  --rules rules.md --out out --name "<file name from Writing Rules>"
```

Each makes the .docx and its PDF (rendered from that .docx, so they cannot disagree),
reports the page count against the `cv pages` setting in the ` ```build ` block, and
runs every check in the ` ```checks ` block on the .docx text and the PDF text. Exit 0
is clean, 1 is a failed check or a wrong page count (the report lists each hit with its
line), 2 is a build that could not run.

Run the same checks over the message, the email and the talking points before they
go anywhere: write each to a file and use `build --no-pdf --kind other`, or read them
against the rules yourself.

**Read every hit.** A banned word inside a quotation from the posting, or describing
the employer's vacancy rather than the person, is legitimate. A hit that refers to the
person is a defect: fix the markdown, rebuild, re-check. **The CV must have exactly the
page count `Writing Rules` sets** (two, unless it says otherwise): a spill means
trimming the content, never the PDF. Whenever a .docx is rebuilt, its PDF is rebuilt in
the same run.

Nothing is attached, posted or reported until every check is clean or every remaining
hit has been read and is legitimate.

## 7. Put each output where it belongs

**The four files go on the card**, uploaded so the bytes never pass through the
conversation:

1. `upload_file` with `card`, `link: true` → a single-use `upload_url` (ten minutes, no
   token needed).
2. From the shell holding the file:
   ```sh
   curl -fsS -F file=@"out/NAME.pdf" -F sha256="$(sha256sum out/NAME.pdf | cut -d' ' -f1)" \
     -F replace=true "<upload_url>"
   ```
   One link per file. The answer echoes the stored `sha256`; compare it with yours.
   `replace=true` removes the card's older file of the same name, so a rebuild leaves
   one copy. A 422 `sha256_mismatch` stored nothing: upload again.

With a token in the shell, `slipdock attach <card> <file>` or the API
(`POST /api/cards/<id>/attachments` with the same fields) do the same.

**The message and the email go in one comment**, as plain text the person can copy:

```
**LinkedIn message** (N characters)
<the message>

**Email**
Subject: <subject>

<the body>
```

**The talking points go on the role page**, `write_page` in `append` mode with a body
that starts `## Talking points (YYYY-MM-DD)`, so they sit after the probe list and
do-not-claim list they draw on. (`append_section` adds to a section that already
exists, and this one does not yet.) No role page: create one in `Roles` and pin it to the card.

## 8. Move the card to `Ready`

`move_card` to `Ready`. This is the only move this skill makes.

## 9. Say what you built

One comment on the card. The person reads it just before a call:

```
**Built**, moved to Ready
- Files: CV and covering letter, .docx and PDF
- Answers recorded: n facts added to Candidate Facts (only when true)
- Analysed first: no coverage on the card, ran it (only when true)
- CV: what tailoring changed, in a few words
- Letter names: the gap, the gap
- Do not claim: comma-separated list
- Checks: all clean (or which hits were kept, and why)
- Couldn't do: what, and why
- Before you send: the one thing worth knowing (only when there is one)
```

Then, with a job, `finish_job` outcome `done` with a three-to-five-bullet summary. Say
the same in chat, naming failures as plainly as the output.

## 10. When the toolchain is not there

A runner on someone's own machine may lack pandoc or LibreOffice. If the files cannot
be built: write the content anyway, put the CV and the letter on the role page in full,
post the message and email as usual, comment that the files were not built and which
tool was missing (a `Couldn't do` line), and move the card to `Ready`. With a job,
`finish_job` `done` with that said in the summary. What must never happen is a card in
`Ready` with nothing on it and a report of success.
