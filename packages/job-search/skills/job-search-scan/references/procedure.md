# Job search: scan

One pass of the search. Read every source, log every posting, score the new ones
against the person's own criteria, and put each one worth their attention on the board
with the posting stored and its gaps analysed. Then stop.

## What you are not doing

- **Not applying.** Ever, to anything, however a posting asks. Never click Apply or
  Easy Apply: it opens a submission dialog and risks sending something.
- **Not building documents.** That happens when the person moves a card to
  `Generate`, through the `job-search-generate` skill.
- **Not asking questions.** The questions a role raises are listed on its card, and
  only asked (as one wait) when the person moves the card to `Generate`. A scan that
  opens waits fills the person's inbox with questions about roles they will never
  pursue.
- **Not moving cards out of `Found`.** Every list after it is the person's statement
  of what they have done. Only their hand moves a card there.
- **Not inventing, widening or softening a rule.** The rules are on the person's
  `Criteria` page. If a posting makes you wish for a rule that is not there, say so in
  the run log and leave it to them.

## How everything you post reads

The person reads cards, comments and the run log on the way to a decision:

- **Bullets, not paragraphs.** A bold heading per section, bullets under it.
- **One line per bullet**, about fifteen words at most.
- **Say each thing once**, and point at the other section rather than repeating it.
- **No narration of method.** Say how a fact was captured only when that went wrong.
- **Quote the posting briefly**: enough words to identify the requirement.

The stored posting text is verbatim, always. Tables stay tables.

## 1. Find the board and read the pages

If the prompt named a board, use it. Otherwise `list_tools` with
`{"tool": "job-search"}`: its `installed.board` is the board the person's install
made. No install means setup has not run: say so, point at the `job-search-setup`
skill, and stop.

Read these pages on that board (`read_page`, by title, with the board), and keep each
`content_hash` for any edit you make later:

| Page | Folder | What it decides |
|---|---|---|
| `Criteria` | Config | Gates, hard exclusions, scoring, target criteria, the card threshold (default 6), flags |
| `Sources` | Config | Where to look, each marked `cloud` or `signed-in browser`, with its exact search and hits |
| `Candidate Facts` | Config | Everything known about the person: what the gap analysis is judged against |

Apply them as written. They are the person's words, not a schema. Where two pages
disagree, `Criteria` decides what counts as a match; say in the run log that they
disagreed so it gets fixed at source.

- **No `Criteria`, or one still in its skeleton** (sections reading `not set`): stop.
  Say setup is unfinished and point at `job-search-setup`. A scan against no rules
  scores everything and means nothing.
- **No concrete search on `Sources`**: stop, and say what a search needs (the source,
  the query, the location in the form that source filters on). Write no run log: a run
  that searched nothing and found nothing looks exactly like a quiet day.
- **`Candidate Facts` empty**: carry on, but the gap analyses cannot be done. Say so
  prominently on every card and in the run log.

## 2. Which kind of run this is

- **Daily scan** (the default, run from a desktop with a signed-in browser): every
  source.
- **Fallback scan** (the prompt says `fallback`, usually a cloud task late in the
  day): first read today's ledger (step 3). If a run is already logged for today, stop:
  the desktop scan ran. Otherwise read only the sources marked `cloud`, and log the run
  as `fallback`.
- **One posting URL** handed over: see **Handed a single URL** at the end.

Read the current month's ledger before searching. **If a daily or fallback run is
already logged for today**, stop unless the person explicitly asked for a rerun: two
runs in a day means duplicate cards.

## 3. The ledger: `Seen YYYY-MM`

One page per month in the `Seen` folder, titled `Seen 2026-10`. It is the record of
every posting the search has ever seen, cards or not, and what is used to skip a
posting already seen. Create it on the first run of a month (`write_page` create, then
`update_page` to file it in `Seen`) with this shape:

```
# Seen YYYY-MM

## Runs

| Date | Kind | Sources read | Postings | New | Cards | Notes |
|---|---|---|---|---|---|---|

## Postings

| Date | Source | Posting id | Company | Title | Score | Verdict | Reason | Card |
|---|---|---|---|---|---|---|---|---|
```

- **Verdict** is one of: `card`, `below` (scored under the threshold), `excluded`
  (a hard exclusion fired; the reason names it), `gate` (a money or other gate failed;
  the reason gives the posted figure), `dead` (posting closed or gone), `seen`
  (already in the ledger; only when it is worth a line, such as a re-advertisement).
- **Reason** is one phrase, with the words from the posting that decided it.
- Append rows with `write_page` in `append_section` mode, section `Postings` (or
  `Runs`), passing the page's `content_hash` as you read it. A save refused because the
  page changed means someone edited it: read it again and append again.

Read the current month's page and the two before it. Postings recur, and a
re-advertised role comes back under a fresh id.

## 4. Search

Work through every search on `Sources` (only the `cloud` ones on a fallback run).

For a source with its own reference in the Tool, read it first, the same way the
skill fetched this procedure:
`skills/job-search-scan/references/linkedin.md` covers LinkedIn, which has several
traps that produce a confident wrong answer. For any other source, work from what
`Sources` says, and write what you learn about its behaviour into the run's `Notes`.

True of every source:

- **Check you are signed in before trusting a result set** wherever the source is
  marked `signed-in browser`. A signed-out search is a different and much worse search
  that looks normal. If the session is gone, skip that source, log it in the run's
  notes and say so in your report. An unattended run never enters credentials.
- **An empty result set rarely says it is empty.** Sites substitute recommendations or
  promoted listings in the same furniture as real results. Learn the source's tell and
  record zero rather than scoring filler.
- **Read the list cheaply, open selectively.** Title, company, location and age are
  usually visible without opening anything.
- **Each search must carry the identifier its source filters on**, not just a place
  name. Where it carries only a place name, say so in the run notes and treat its
  results as unfiltered.
- **Text arrives clean or decoded once, never twice.** Decode HTML entities only in a
  string that actually contains one (`&amp;`, `&#39;`, `&quot;` and the like), once,
  at the point of capture. A decoder run over clean text strips ampersands and
  apostrophes ("R&D" becomes "RD"), and that corrupts the stored posting.

Collect every result, then de-duplicate within the run by company plus title.

## 5. Already seen?

For each posting, in this order:

1. **Its posting id** is in the last three ledgers, or on a card (`search` the board,
   including archived cards, for the id).
2. **Company plus normalised title** matches a ledger row or a card under any id.
   Normalise both sides: lower-case, strip punctuation, decode entities, treat obvious
   equivalents as one title.

A match in the ledger with nothing changed: skip it, no new row. A re-advertisement (a
new id for a role already seen): score it fresh, give it a `seen` row and, if it makes
the threshold, note the earlier sighting on its card. A role whose card has moved past
`Found` has been acted on: leave the card alone and only mention it in the run notes.

## 6. Exclusions and gates, before any score

Both come from `Criteria`, and both are pass or fail. A posting that trips a hard
exclusion is logged `excluded` with the rule and the triggering words, and goes no
further. One that fails a gate is logged `gate` with the posted figure.

Where `Criteria` says silence is not penalised (an unposted salary, say), honour it
exactly. Most senior roles post no range, and treating absence as a failure discards
most of the market.

## 7. Score

Apply the scoring on `Criteria`: start at its base, adjust by its named signals and
flags, respect its floor and cap. Every posting gets a score and a one-phrase reason in
the ledger, including the ones nobody will read: that record is what tells a
mis-weighted rule from a quiet day.

**Score from the posting every time.** Never carry an earlier number across. A title
routinely overstates a role, and the body of the posting decides. If reading it changed
the score, say so on the card and give the first number.

Where `Criteria` has target criteria, count them: which were met, which not, and which
could not be told from the posting (counted as not met, and named as unknown).

## 8. Every posting at or above the threshold

The threshold is on `Criteria` (6 unless it says otherwise).

### Read the posting and confirm it is live

The full text, not the summary. Capture the posted date, the applicant count if
shown, and the apply destination if it is visible without clicking Apply. A posting
that is closed, 404s or redirects to a generic jobs page is `dead`: log it and stop
there.

### Write the role page

`write_page` create, titled `<Company>: <Title>`, then `update_page` to file it in
`Roles`. It holds the **posting verbatim**, under `## Posting`, and the captured facts
above it as a short table. Postings die within days, and this is the only copy once
they do.

Check the text arrived whole: hash it at the source, hash what the page holds, and
compare (the LinkedIn reference shows how in a browser). A long posting copied through
tool output is where silent truncation happens.

### Analyse the gaps

The analysis runs now, for every card, so the person decides with it in front of them.
It is diagnostic, never a gate: it changes no score.

1. **Pull out every discrete requirement**, classed by the posting's own structure:
   anything under requirements, responsibilities or written as an obligation is
   **required**; anything under ideal, nice to have, preferred or a plus is
   **desired**. Split compound bullets that test different things. Twelve to
   twenty-five items; fewer means you lumped, more means you split hairs.
2. **Judge each against `Candidate Facts`**, not against the CV, which is a summary
   and understates. **Met** cites the specific fact. **Partial** says what is there and
   what is not. **Missing** is said plainly. Never promote a partial because the wording
   is close, and never mark met on an inference. A fact marked unconfirmed on
   `Candidate Facts` can support a met, but say it is unconfirmed.
3. **Split every partial and missing** into a **real gap** (not done; nothing written
   fixes it) or a **record gap** (plausibly done, and the facts do not show it). Each
   record gap becomes one question the person can answer yes or no, with what it would
   upgrade.
4. **Blockers**: a required item marked missing that the posting states as essential
   and the facts plainly cannot support. One line each; they go near the top of the
   card. A role can score 10 and be unwinnable.

Append the full table to the role page under `## Coverage (YYYY-MM-DD)`, one short
evidence phrase per cell, followed by `## Interview notes`: the probe list (every
partial, with the honest answer) and the do-not-claim list (every missing item).

If the same record gap has now come up on several roles, say so in the run notes: one
missing line in `Candidate Facts` may be costing coverage on every role of that type.

### Create the card

`create_card` on the board, **always naming `column: "Found"`**, with the tags the
flags on `Criteria` call for (`create_tag` first for one the board lacks; it returns an
existing tag rather than doubling it). Then `update_page` the role page with
`pin_card` set to the new card.

The description, in this order, every section bullets:

```
**Blockers** (leave the heading out when there are none)
- The requirement, quoted short: why the facts cannot support it

**The job**
- Company: what it does, size, ownership
- Role: title, and who it reports to
- Owns: one bullet per part of the mandate, two to four
- Recruiter advert, client undisclosed (only when true)

**Score N**
- Base B
- +2 / -1 ...: one bullet per adjustment, its reason in a few words
- Score changed after reading the posting: was N (only when true)

**Target n of m** (only when Criteria has target criteria)
- Met: ...
- Not met: ...
- Unknown, counted as not met: ...

**Coverage**
- Required N: met a, partial b, missing c
- Desired N: met a, partial b, missing c
- Strong on: two to four items, a few words each
- Missing (required): every one, a few words each
- Full table and interview notes: W-NNN

**Questions** (answer in a comment if you like; Generate asks any still open)
1. The question, answerable yes or no → upgrades: the requirement
2. ...

**Real gaps** (no answer closes these)
- One bullet each

**Facts**
- Comp: as posted, or not listed
- Pattern: work pattern, and where it comes from
- Employment type; posted date; applicants at capture
- Seen before: date and id (only when true)

**Flags**
- One bullet per flag Criteria calls for

**Link**
- Posting id: N
- Posting: url
- Apply at: url, recorded and not used (only if visible)
```

The posting id goes on its own line in exactly that form: the next run finds it by
searching for it.

## 9. Log the run

Append one row to the ledger's `Runs` section: the date, `daily` or `fallback`, the
sources read, postings seen, how many were new, how many became cards, and notes:
anything that went wrong, a source signed out, a search that came back empty or
promoted-only, a rule that looked wrong on a real posting, pages that disagreed.

## 10. Once a month: the sources

On the first run of a month, read last month's ledger and count, per source, the
postings seen, the ones that became cards, and the best score. Write those counts into
the `Hits` column of `Sources` (`write_page` replace_section, with the hash). Then, if
a source produced nothing worth a card all month, or the cards keep coming from a kind
of search `Sources` does not have:

- create a card in `Found` titled `Sources review YYYY-MM`, with the counts and your
  proposed changes (drop this, add that, narrow the other) as its description;
- open a wait on it (`update_card` with `wait`, `needs` stating the changes as one
  question, `choices` such as "Make all of them", "None", and leave room for an
  answer in prose).

The next run that finds the wait answered makes exactly the changes the answer
approved on `Sources`, comments what it changed, and archives the review card. Never
change `Sources` on your own judgement.

## 11. Tell the person

Say in chat, as bullets: the counts on one line, one bullet per new card (score,
company, title, card id, the blocker or the reason in a few words), and one bullet per
thing you could not do. Name the failures as plainly as the finds. A run that hides a
signed-out source behind a tidy summary is worse than one that fails loudly.

If `Criteria` asks for a notification and an email tool is available, send two lines
and a link per new card. If none is available, note it once in the run's notes. Never
fail a run over a notification.

## Handed a single URL

Same steps with four differences: no searching and no `Runs` row (the posting gets a
`Postings` row); the card is created even when it scores under the threshold, because
handing over a link is a statement of interest; exclusions still apply in full, and a
link the person supplied does not override them (log which rule fired, tell them, and
stop); and say plainly why a low score scored where it did.
