---
name: slipdock-docs
description: Decide what to write down on the user's Slipdock wiki, and where it goes. Use when asked to document something, write up a decision, record a retro or a post-mortem, keep notes on an investigation, draft a spec or a runbook, or check what has already been written before starting work. The companion to slipdock-work — that one works the board, this one leaves something behind worth reading.
---

# Writing things down on the board

`slipdock-wiki` is the command reference. This is the harder half: **what
belongs in a document, and where it goes.** The commands are easy to look up;
the judgement is what a model gets wrong.

Start, once per session, with the server's own conventions — they come from
the running app and so cannot be out of date:

```sh
slipdock guide            # its wiki section is the shape of what follows
```

## Before you write anything: look

The single most common failure here is a fourth page about deployment.

```sh
slipdock search <the thing> --kind pages    # by meaning, every board you can see
slipdock page ls <board> --q <the thing>    # by substring, one board
slipdock page tree <board>                  # what the wiki already looks like
slipdock wiki                               # or the whole lot, every board, folders and all
```

The first one is the one that works. Pages are in the same semantic index as
cards, chunked by heading, so a search for "how do retries work" lands on the
*section* that says — even when nobody wrote the words you typed.

**Extend the page that exists** unless the subject is genuinely new. A new
page is right when the thing it describes is new; it is wrong when you simply
did not find the page that was already there.

## A page, or a comment?

| It is… | It goes… |
|---|---|
| Durable, and will be re-read after this card closes | a **page** |
| About one card, and about *now* | a **comment** or status update on the card |
| A decision, and why it was made | a **page**, linked from the card |
| Progress, a blocker, what you tried | a **comment** |

Never both. A page that repeats the card's comments is a page nobody trusts,
because nobody can tell which copy is current.

The test that settles almost every case: **will anyone want this after the
card is closed?** If yes, it is a page.

## Where it goes

Two different questions, and answering the wrong one is what makes a wiki hard
to read later.

**What is it part of?** `--parent W-12` — the rollback half of the runbook, the
appendix of the spec. Reading the parent should make you want to read the
child. If it would not, this is the wrong axis.

**Where is it kept?** A folder — "Design", "Contracts", "Meetings". Filing,
and nothing more: the pages in one need have nothing to do with each other.

```sh
slipdock folder ls <board>                          # what filing already exists
slipdock page file W-31 --folder "Design/Decisions" # made if it is new
```

- **Use the folders that are there** before making another. `slipdock folder ls`
  first, the same discipline as searching before writing.
- **Never make a parent page just to hold pages.** A page called "Design" that
  is about nothing is a document you have to read past. That is what a folder
  is for, and a folder costs nothing.
- **Pinned to the card it explains** (`slipdock page pin W-31 --card 412`), so
  the person looking at the work finds the writing without searching for it.
- **Named for the thing, not the moment.** "Retry policy", not "Notes from
  Tuesday". A page is a place a subject lives, and it gets edited; a dated
  heading inside it carries the moment.

## Shape

Write the document someone will read in six months, not a transcript of what
you just did.

- **A `## Log` section** for dated notes, appended to, newest last. That is
  what `slipdock page section <page> Log --append` is for, and it means an
  agent can add to a running record without touching anyone's prose.
- **A summary line** (`--summary`) on every page: it is what shows in
  listings, search results and link hovers, and it is the only chance to say
  what the page is for.
- **Link, don't restate.** `[[Retry policy]]` beats a paraphrase that will be
  wrong in a month. `#412` beats "the card about retries" — it is drawn live,
  so it is never stale.
- **Leave wanted pages.** Linking `[[Rollback procedure]]` before it exists
  is how the next person finds the work; `slipdock page wanted <board>` is the
  list. Do this deliberately rather than avoiding it.
- **Query, don't list.** A list of blocked cards typed out by hand is wrong
  by Tuesday. A ```` ```slipdock ```` block asks the question instead and is
  answered whenever somebody reads the page — with *their* permissions, so it
  is safe to put one in a page you share. `slipdock page query-help` is the
  grammar; `slipdock page query <board> --body -` tries it before you save it.
  The exception is a document that should *not* move: a decision record
  saying what was true on the day wants the list written out.
- **Keep code in fenced blocks.** References inside them stay literal, which
  is what you want when documenting the syntax itself.

## Writing safely

- **Append or replace a section**, rather than sending the whole body. It is
  cheaper, and it is the difference between collaborating on a document and
  overwriting it.
- **`--base-hash` on any whole-body edit** of a page you did not just write.
  A refused save is a good outcome; a silent overwrite is not.
- **`--message` on every edit**, saying why. It sits in history beside who
  you are and the fact that a robot made the change — that part is recorded
  for you, the reason is not.
- **Don't rewrite someone else's section** without saying so in the message.
- **Draft it** (`--draft`) if it is half an answer. A draft is visible only to
  people who could edit the board, which is exactly right for work in
  progress.

## Kinds of page worth knowing

- **Decision record** — the decision, the options, why this one, what it
  costs. Dated. Never edited to pretend a different decision was made;
  superseded by a new page that links back.
- **Runbook** — what to do, in order, when the thing happens. Imperative,
  short lines, a `## Log` at the bottom for what actually happened each time.
- **Spec** — what is being built and what "done" means. Pinned to the epic.
- **Retro / post-mortem** — what happened, what we learned, what changes.
  Links to the cards, so the cards do not have to repeat it.
- **Investigation** — the question, what was ruled out and why, where it got
  to. The ruled-out list is the valuable part; it is what stops the next
  person repeating the work.

## Should it be on the board?

A page can be put in one of the board's lists and dragged about like a card
(`slipdock page place <page> "In Progress"`). Almost always the answer is no.

Place a page when somebody is working **through** it and its progress is part
of the plan: a spec being written, a retro waiting to be held, an
investigation somebody has picked up. Leave it in the wiki when it is
something people *consult* — a runbook, a decision record, a reference. The
test is whether "done" means anything for it. A board full of documents is a
board people stop reading.

A placed page is drawn as a card and can carry the card's facets — priority,
flags, an assignee, start and due dates, a percentage, a done tick, a cover
colour (`slipdock page edit <page> --priority high --due 2026-10-09 --flag
review`). Set them only for a page whose progress is genuinely part of the
plan, which is the same page it was worth placing. A priority on a runbook
tells nobody anything.

## Talking about a document

A page takes comments, a checklist, reported health, web links and votes, the
same way a card does and with the same commands (`slipdock comment <page> …`,
`slipdock check`, `slipdock status`, `slipdock weblink`, `slipdock vote`).

Use them for talk *about* the document, not as a second place to write it:

- **A comment** for a remark on the draft — a question, a correction, a
  pointer. `[[Another page]]` in one shows up in that page's backlinks, so a
  remark is as findable as a sentence in the body.
- **A checklist** for the work of finishing the page: sections still to
  write, people still to ask.
- **A status update** when a document somebody is waiting on has stalled.
  "At risk, blocked on the SRE review" is worth more than silence.

If a comment thread is turning into content, move it into the body and delete
it. The body is the thing people read.

## Starting from the work, and from the page

Two shortcuts that save the whole awkward dance of making a page, finding the
card and linking them by hand:

```sh
slipdock writeup 412                        # a page for that card, pre-titled and pinned
slipdock writeup 412 --template "Spec template"
slipdock page make-card W-31 --body -       # a passage of a page becomes a card
```

`writeup` is the right answer to "document this card". `make-card` is the
right answer to a page that has grown a list of things somebody should do:
turn each into a card rather than leaving the work buried in prose. Both
write the link into both ends, so neither side has to remember the other.

## After the work

When something came off the board and produced an answer worth keeping:

1. Write or extend the page.
2. Pin it to the card if it explains that card.
3. Name it by code in the card's closing comment (`W-31`), so the trail runs
   both ways.

That is the whole point of a wiki inside a work tracker: neither side has to
remember the other exists.
