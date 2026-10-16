# Job Scan

An automated job search that runs on a Slipdock board. Every day your assistant
searches the job sites you name, drops anything you have ruled out, scores what is
left against **your own** rules, and puts each role worth a look on the board with a
plain description, a score and a read of how well your record covers what it asks
for. When you want to apply for one, you move its card to **Generate** and the
documents — a tailored CV, a cover letter, a short note for a recruiter and talking
points — are built from your own record and attached to the card.

It never applies to anything and never sends anything. Only you move a card past
**Ready**.

## What you get

- **A board** with seven lists: `Found` → `Interested` → `Generate` → `Ready` →
  `Applied` → `In conversation` → `Closed`. The scan only ever writes to `Found`, and
  the document build only moves a card from `Generate` to `Ready`.
- **Six pages** in the board's `Config` folder, which hold everything about you: what
  you are looking for, where, the absolute noes, money, how to score a role, your
  career record, your CV and how documents should be written. They start empty, and
  setup fills them in with you.
- **One rule**: a card that arrives in `Generate` is queued to have its documents
  built.
- **Three skills** for your assistant: `job-scan-setup` (the conversation that sets it
  all up), `job-scan` (one pass of the search) and `job-scan-build` (the documents for
  one role).

Slipdock builds the board itself, the same way for everyone, so the lists always mean
what the skills expect.

## Installing it

Follow the steps for your assistant above, then start a new chat and say:

> Set up Job Scan for me.

Setup happens in stages. The first is short — what you are looking for, where, what
you will not consider and what you need to be paid — and at the end of it the first
scan runs, so you see it working before you are asked about your career. The record,
the CV and the document rules come after, at your pace. Skipped questions stay "not
set" and are treated as absent: nothing is invented on your behalf.

## Running it every day

Setup gives you a one-line prompt to schedule, naming your board: for example
"run the job-scan skill against board `job-scan`". Scheduling it is done in your
assistant (a scheduled task in Claude, for one).

For documents, something has to take the build jobs that `Generate` queues. Either a
scheduled task that claims them every few minutes (nothing to install), or a runner
on your own computer (faster; needs node, pandoc and LibreOffice). Setup explains both.

## What it needs

- The Slipdock connector in your assistant (or the `slipdock` command, in Claude Code).
- A browser your assistant can drive, signed in to the job sites you search. A scan
  that finds itself signed out stops and says so; it never types a password.

## Your data

Everything about you lives on the board's pages, which only you (and anyone you share
the board with) can read. The skills hold only the method, which is why one package
works for anybody.
