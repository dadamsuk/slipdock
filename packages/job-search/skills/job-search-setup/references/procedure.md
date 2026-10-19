# Job search: setup

Stand up the person's job search, or change it. The Tool holds the method; everything
about the person lives on pages on their own board, which they can edit at any time and
which take effect on the next run. Your job here is to **ask and record, never to
supply**: a value you invent that looks deliberate is worse than a blank, because nobody
will think to check it.

Setup is interactive. It also runs again whenever the person wants to change
something: "add a source", "my floor is higher now", "rebuild my CV template". For a
change, go straight to the step that owns it, and skip the rest.

## The board and its pages

| Page | Folder | Holds |
|---|---|---|
| `Criteria` | Config | Gates, hard exclusions, scoring, target criteria, the card threshold (default 6), flags |
| `Sources` | Config | Where to look, each marked `cloud` or `signed-in browser`, its exact search, and hits per source |
| `Candidate Facts` | Config | Everything known about the person beyond the CV, each fact with its source, date, any framing rule, and whether it is confirmed |
| `CV Baseline` | Config | The CV's fixed structure (entries, dates, section order) and its default content; the style template is attached here |
| `Writing Rules` | Config | Voice, banned phrases, positioning, what tailoring may change, file naming, and the build settings and checks |
| `Seen YYYY-MM` | Seen | The scan's monthly ledger. Setup never writes these |
| one page per role | Roles | Written by the scan |

Lists: `Found` → `Generate` → `Ready` → `Applied` → `In conversation` → `Closed`. The
scan writes only to `Found`; generate moves a card only from `Generate` to `Ready`;
every other move is the person's.

## 1. Find or make the board

1. `whoami`: the connection must be able to write. A read-only one cannot set anything
   up; say so now rather than at step four.
2. `list_tools` with `{"tool": "job-search"}`.
   - `installed` set: setup has run before. Read the five `Config` pages, tell the
     person what is filled in and what still reads `not set`, and ask what they want to
     change.
   - `installed: null`: ask what to call the board ("Job Search" is the default), then
     `install_tool` with `tool: "job-search"` and that `board_name`. It builds the
     lists, the five page skeletons, the folders and the rule that queues a runner job
     when a card enters `Generate`. Check the answer lists them all.

## 2. Criteria: what a match is

Ask in two or three conversational batches, never as a form, and say why each matters.
Offer to read what they already have (old notes, a previous search's rules) and draft
from it, then go through the draft with them: correcting a draft surfaces more than
answering blank questions.

- **What they want.** Titles and level; permanent, interim, contract or a mix. Interim
  usually needs its own money floor.
- **Where.** Base, the places they would travel to (named, not a radius), remote,
  relocation.
- **Gates.** Money floors per track, and **what to do when nothing is posted**. Most
  senior roles post no range, so penalising silence throws away most of the market.
  Record their answer either way.
- **Hard exclusions.** Sectors, business types, titles, posting sources they would not
  even look at. Push gently: people under-report these and are then irritated daily by
  a category they could have named in a sentence.
- **Scoring.** Supply the shape, never the values: start every role at a base, add for
  signals they name, subtract for red flags they name, floor and cap. Propose 1 to 10
  from 5 as the scale (that is shape, not judgement), then go through each signal and
  flag and write down **the number they give it**. A list of signals without weights
  looks finished and cannot be executed.
- **Target criteria** (optional): three to six checkable things that describe the role
  they actually want. Each card then shows how many it meets, which keeps a high score
  for the wrong kind of role from looking flattering.
- **The card threshold**: the score at which a posting becomes a card. Default **6**;
  ask after the weights exist, never before.
- **Flags**: things to raise on a card without changing its score (comp not posted,
  interim, seen before). Each flag names the tag the card gets.

Write it to `Criteria` (`write_page` `replace`, with the page's hash and a `message`).
Every rule records **the date** and **one line of why**: a rule with no reason gets
reverted by the next reader who finds it inconvenient. Keep the `## Changing a rule`
section the skeleton has: the person alone sets rules, and a retired rule moves to
`## Retired` rather than being deleted, so nothing stale gets "restored".

Create the tags the flags name (`create_tag`), and no others.

## 3. Sources: where to look

Propose sources from the criteria: job boards and searches suited to the titles,
sectors and places. For each one, **check it can be read** before recording it:

- **`cloud`**: readable from any session with web access and no sign-in (public job
  boards, company career pages, search engines). The cloud fallback scan reads only
  these.
- **`signed-in browser`**: needs the person's own logged-in session (LinkedIn among
  them). Only a scan on their desktop, with that browser, can read it. A signed-out
  search is a different and much worse search that looks normal.

Each search records the exact query and **the identifier its source filters location
on**, not just a place name: several sites discard a text location silently and return
country-wide results. LinkedIn uses a numeric `geoId`: run the search once in a browser
with the place picked from LinkedIn's own dropdown, and read `geoId` out of the URL.
The Tool's `skills/job-search-scan/references/linkedin.md` has the rest of LinkedIn's
mechanics (the 24-hour filter, employment type, the promoted-results trap).

Write `Sources`: one table row per search (source, access, query or URL, location
identifier, hits; leave hits empty, the scan fills them in monthly) and a notes section
for anything learned about a source.

**If no concrete search exists yet, say what that means**: the scan stops rather than
reporting a clean zero, but they should hear it from you first.

## 4. CV Baseline and Candidate Facts: the record

**Ask for their CV as a file** (.docx, the version they actually send), and anything
else: a LinkedIn export, old applications, notes. For a file on their machine, give
them an upload link: `upload_file` with `page` set to the `CV Baseline` page's code (`W-…`, from `read_page`) and `link: true`
returns a single-use URL (ten minutes, no token) they or their shell can `curl -F
file=@cv.docx -F sha256=<hex> <url>` to. In a chat with no shell, they can attach it to
the `CV Baseline` page in the web app.

**`CV Baseline`** is the CV as structured markdown, word for word from their document:

- `## Structure (fixed)`: the entries in order with their exact titles, companies and
  dates, and the section order. Ask which of these they want held fixed; whatever they
  say goes here and generate treats a deviation as a defect.
- `## Content`: the header, every section, every entry with its strapline and its
  bullets, in the document's order.
- `## Available bullets`: lines they approve for tailoring that are not on the base.
- `## Never on the CV`: things that must not appear, with the reason.

**`Candidate Facts`** is the fuller record the gap analysis is judged against. It is
not a CV: it is what they did, with the numbers and names a CV has no room for. Draft
it from everything they gave you, then hand it back for correction. Each fact is one
bullet with its source, date and any framing rule:

```
- Grew the engineering team from 8 to 40 in two years. (source: CV, 2026-10-19 · confirmed)
- Ran the ISO 27001 programme to audit readiness. (source: CV, 2026-10-19 · framing: never say certified · confirmed)
- Probably owned the vendor budget at Acme. (source: inferred from CV, 2026-10-19 · unconfirmed)
```

Anything you inferred rather than read is **unconfirmed** until they say so; generate
asks before relying on it. Record **known gaps** plainly, because a gap analysis that
cannot tell a real gap from a missing line keeps proposing fixes for things no writing
can fix. Open questions go under `## Open questions`; the record fills in over time.

The line between the two pages: "it was 30 people, not 25" changes the fact on
`Candidate Facts` and the figure on `CV Baseline`; neither page holds rules about
writing.

## 5. Writing Rules: how documents are written

Ask, and record:

- **Voice** per document: most people want the CV in implied first person (no
  pronouns) and the letter and messages in plain first person. Record what they say.
- **Banned phrases** and constructions, with the reason for each.
- **Positioning**: claims to make, claims never to make, how to phrase the sensitive
  ones.
- **What tailoring may change** and what it may not (this must agree with the fixed
  structure on `CV Baseline`).
- **File naming** for the CV, the letter and their PDFs.
- **A style guide** they keep elsewhere, if they have one: record where it is and read
  it at every build rather than copying it.

Then the two blocks the build script reads, which the skeleton has with placeholders.
Propose values and record the ones they accept:

````
```build
bullet: -
cv pages: 2
```

```checks
forbid all | third person | \b(he|his|him|himself|she|her|hers|herself)\b
require letter | first person | \b(I|my|me)\b
forbid all | em dashes | —
forbid all | status declarations | actively seeking|available for work|open to opportunities
forbid all | age signals | [0-9]+ years of experience|[0-9]+ years
max 2 all | antithesis | \brather than\b|, not [a-z]
```
````

A check line is `<rule> <documents> | <label> | <regex>`: the rule is `forbid`,
`require` or `max N`; documents are `all`, or `cv`, `letter`, `other` (comma-separated).
Patterns are case-insensitive; `(?-i:...)` makes part of one case-sensitive. Add one
check per banned phrase that can be matched mechanically. Every hit is read by
generate before anything is fixed, so a check can afford to be broad.

## 6. The style template

Generate builds every document from markdown plus a style template, so the output
looks like their CV. Build it from the CV file they gave you:

1. Fetch the script: `skills/job-search-generate/scripts/build_docs.py` (MCP
   `list_tools` with `tool` and `file`, or `slipdock tools file`). Save the text exactly.
2. Fetch their CV: `download_file` with its attachment id and `link: true`, then
   `curl -fsSo cv.docx "<download_url>"`. Never through base64.
3. `python3 build_docs.py inspect cv.docx` reports its page size, margins, fonts,
   sizes, colours and bullet.
4. `python3 build_docs.py template --from cv.docx --out cv-template.docx` makes the
   template from those. Override anything the inspection got wrong with the flags
   (`--font`, `--size`, `--heading-size`, `--name-size`, `--heading-colour`,
   `--centre-name`, `--bullet`, `--bullet-indent`, `--margin`, `--space KEY=PT`;
   `--help` lists them).
5. **Prove it:** write the `CV Baseline` content as markdown in the layout the generate
   procedure shows (step 5 there), build it with
   `python3 build_docs.py build baseline.md --kind cv --template cv-template.docx --rules rules.md --out out --name baseline`,
   render their original to PDF too (`soffice --headless --convert-to pdf cv.docx`),
   and **compare the two PDFs by eye**, page by page (`pdftoppm -png -r 60` gives images
   you can look at). Fonts, sizes, colours, rules under headings, bullets, spacing and
   the page breaks should match. Adjust the flags and rebuild until they do, and say
   what still differs.
6. Upload the template to `CV Baseline` as `cv-template.docx`: `upload_file` with the
   page's code, `filename: "cv-template.docx"`, `link: true`, `replace: true`, then `curl` the file with its sha256, as
   generate does for card files.

No shell at all (a chat with no code execution): say the template could not be built,
and that generate will fall back to a plain one until setup runs somewhere with
pandoc and LibreOffice.

## 7. The scheduled tasks

Three tasks keep it running. Give the person each prompt with their board code filled
in, and say where each runs:

| Task | Where | When | Prompt |
|---|---|---|---|
| Daily scan | Their desktop (it needs the signed-in browser) | Once a day, morning | `Use the job-search-scan skill: run the daily scan on board <code>.` |
| Generate | Claude cloud (pandoc and LibreOffice are there) | Hourly | `Use the job-search-generate skill on board <code>: claim a job from pool generate and build it; stop if nothing is queued.` |
| Fallback scan | Claude cloud | Once a day, evening | `Use the job-search-scan skill: run the fallback scan on board <code> (cloud sources only; stop if today's scan already ran).` |

Instead of the hourly task, a runner on their own machine can take the `generate`
pool's jobs within seconds; it needs pandoc and LibreOffice installed there. Say which
you would pick and why, and let them choose.

A cloud task needs the Slipdock connector in its environment, or a Slipdock token in
its environment settings.

## 8. Check, then say what exists

Read back every page you wrote. A setup that reports success over a page that did not
save is worse than one that failed: the first scan runs against nothing and reports
cheerfully.

Then tell them plainly: the board and its link; which pages are filled in and which
still read `not set`, and what that stops (the scan works without `Candidate Facts`
but the gap analyses do not; generate needs `CV Baseline` and the template); the three
tasks and whether they exist yet; and that they come back to this skill to change any
of it.

## What not to do

- **Do not supply rules**: no floor, exclusion or weight they did not give you.
- **Do not create cards** to make the board look busy. Every card comes from the scan.
- **Do not touch other boards**, even ones that look related.
- **Do not copy the method onto their pages.** Pages hold their data; the method is
  the Tool's and updates itself.
