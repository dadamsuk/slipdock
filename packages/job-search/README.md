# Job Search

A job search that runs on a Slipdock board. Every day your assistant reads the job
sites you name, skips anything it has already seen, drops what you have ruled out,
scores the rest against **your own** criteria, and puts each posting worth a look in
**Found** with the advert stored word for word and a gap analysis against your record.
When you want to apply, move the card to **Generate**: your assistant asks anything it
still needs to know, in one question, and then builds a tailored CV and covering letter
(Word and PDF, on the card), a short LinkedIn message and an email for the recruiter,
and talking points for the call.

It never applies to anything and never sends anything. Only you move a card past
**Ready**.

## What you get

- **A board** with the lists `Found` → `Generate` → `Ready` → `Applied` →
  `In conversation` → `Closed`. The scan only writes to `Found`; building documents only
  moves a card from `Generate` to `Ready`.
- **Five pages** in its `Config` folder that hold everything about you: `Criteria`
  (what a match is, and the score a posting needs to become a card, 6 unless you change
  it), `Sources` (where to look), `Candidate Facts` (your record), `CV Baseline` (your
  CV as content, with your style template attached) and `Writing Rules` (how documents
  are written, and the checks every document must pass). They start empty and setup
  fills them in with you. Edit them whenever you like; the next run uses your changes.
- **A monthly ledger** in `Seen`: every posting the scan has looked at, with its score
  and why, cards or not.
- **A page per role** in `Roles`: the advert as it was, the gap analysis and the
  talking points.
- **One rule**: a card that arrives in `Generate` queues a job for the `generate`
  runner pool.
- **Three skills**: `job-search-setup` (the conversation that sets it all up, and
  changes it later), `job-search-scan` (one pass of the search) and
  `job-search-generate` (the documents for one card). Each skill fetches its current
  procedure from Slipdock when it runs, so a new version of the Tool reaches you without
  reinstalling anything.

## Getting started

Install the skills in your assistant, then say:

> Set up my job search.

Setup builds the board, then asks what you are looking for, where, what you would never
consider and what you need to be paid. It reads your CV (send it the Word file you
actually use) to fill in your record and your CV baseline, and builds a style template
from it, so the documents it makes look like yours.

## Running it every day

Setup gives you three prompts to schedule, with your board filled in:

- **The daily scan**, on your own computer, because sites like LinkedIn need your
  signed-in browser.
- **Generate**, hourly, in Claude's cloud, which takes any card you have moved to
  `Generate`. (A runner on your own computer can do this instead, within seconds, if it
  has pandoc and LibreOffice.)
- **A fallback scan**, in the evening, in Claude's cloud: on a day your computer was
  off it reads the sources that need no sign-in.

## Adding a job yourself

Seen a job the search hasn't? Add a card to **Found** with the posting's link on it
(the title can be just the link). The next scan reads the posting, fills the card in
with the score and gap analysis, and stores the advert, keeping your link and anything
you wrote. It keeps the card whatever it scores, but your hard exclusions still apply:
if one fires, the card says which. LinkedIn links need your signed-in browser, so they
are picked up by the daily scan on your computer, not the evening fallback.

## Your data

Everything about you lives on your board's pages, which only you, and anyone you share
the board with, can read. The Tool holds only the method, which is why one package works
for anybody.
