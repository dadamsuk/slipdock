[Slipdock — the manual](../manual.md)

## Where it was left (handoffs)

Work on a card spans sittings, people and tools: a Claude Code session, a
runner pass, you at a browser. A **handoff** is the one short note on a card
that says where it was left, so whoever picks it up next, person or agent,
reads that first instead of piecing the state together from the comments.

It is a **next step** (one line, at most 280 characters, required) and a
**note** (Markdown, at most 8000), usually in this shape:

```
State:     what is done and what is half-done
Next:      the one next step
Gotchas:   what bit me / what not to try again
Open:      questions waiting on someone
Pointers:  branch, files, commits, pages (W-…)
```

Most cards never need one, so until one is written it is just a **Left off**
button in the toolbar at the top of the card (beside **Move**, **Ask** and
**⋯**). Once there is one it sits straight beneath the title: *Left off — next:*
and the next step, the note, who left it, when and how (the web app, the API,
MCP, the CLI or a runner), and, once there has been more than one, a
**History** of every earlier one. The note is Markdown, as a comment is
(bullets, `code`, links), and a single line break stays one. **Update** writes
a new one; nothing is edited in place, so the history is the whole story.
**Clear** writes an empty one, and the history keeps that too; the card goes
back to the link. In the history each entry opens to its note, and
**Restore** makes an earlier one current again (as a new entry, so the history
says who brought it back).

**Auto generate**, in the handoff's form when you have an [AI model](ai-assistant.md)
set up, drafts the next step and the note for you from what has happened on
the card lately: the last fortnight of its activity, its comments, checklist
and status updates, with the rest of the card and the handoff before this one
behind them. The draft goes into the form's fields, replacing what was there;
nothing is written until you change what needs changing and press **Save
“Left off”**. While the card is open its front carries a ↩ mark with the next step as
its tooltip; a completed card keeps its note but loses the mark. To read the notes
without opening the cards, show one of two elements in your [card views](card-views.md):
*Handoff note (2 lines)* puts the next step and the start of the note on each open
card's front (the whole of it in the tooltip), *Handoff note in full* puts all of it
there. It is for comfortable cards only, on the board and swimlanes views.

A board can call it something else, and tell Auto generate what to write.
Under **Handoffs** on the board's [Agentic Building](the-header-and-the-avatar-menu.md#agentic-building) page, **Label** replaces *Left off* wherever a person reads it in the web app — the
card's panel and its form, the link that adds one, Save, Clear and Delete, the
card's front (up to 40 characters), and **Instructions for Auto
generate** replace what the AI model is told about writing the note (up to
4000 characters) — keep it shorter, ask for a different shape, write in
another language. Whatever they say, the model is still asked for a next step
and a note, so the form fills the same way. Leave either blank for the
default; the placeholders show what the defaults are. A card's subcards start
with their parent board's, and both travel with a board's export. From the
command line: `slipdock set-board B --handoff-label Parked
--handoff-prompt-file prompt.txt` (`""` for the default); over the API,
`PATCH /api/boards/:board` with `handoff_label` and `handoff_prompt`. What
agents read (`get_card`, the `resume` prompt) still says *Left off:*, since
the skills look for it.

Anyone who can comment on a card can leave its handoff, since it is a kind of
comment; a reader sees it but can't write one. Each one is a line in the
board's activity.

**At a glance.** The block under a card's title says where it stands, in
order: the status row (the health, the latest step, when, and who: a person
or *Slipdock*), the next step, the shipped lines with their time, then the
note, folded past a few lines (**Show more**) with its byline last. The
runner's own lines (the transcript it sent, how the job ended) are left out
of the note: the byline names the job. Once the card is **finished** there is
no next step: the block shows its **outcome** instead — *Done 6 Nov 14:32 ·
accepted by runner verifier · merged PR #215 (def5678)* — and folds the
handoff written before it finished away as *Last note before it finished*,
so a stale "accepting will merge it" never reads as current. A handoff left
after it finished, for what is still to do, shows as *still to do*.
Reopening the card brings the handoff back as it was; nothing is rewritten.
`slipdock card` and `get_card` do the same: *Outcome* in place of *Left
off*, the earlier note as `last_handoff`.

Comments stay the running log and status updates the stated health; the
handoff is the *now*. Write one whenever you stop with a card unfinished.
Agents are told the same: the guide says to read a card's handoff before
starting it and to leave one when stopping, `get_card` puts it first, and the
`slipdock-work` and `slipdock-loop` skills do both. A [runner](runners.md) job
that ends with its card still open leaves its summary as the handoff (its first
line is the next step), unless the agent left one itself during the job or the
card is already accepted (merging, held or accepted).

```sh
slipdock handoff 12 --next "Write the rounding test" --body "State: fix is in, untested"
slipdock handoff 12 --next "Ship it" --file note.md      # or --body - to read stdin
slipdock handoff 12                                      # the handoff and its history
slipdock handoff 12 --clear
slipdock handoff 12 --delete
```

**Clear or delete.** *Clear* says the card has no handoff any more, and the
history keeps both the old one and the clear. *Delete* is for one that should
never have been written — the wrong card, a wrong next step: it goes outright,
history and all, and the one before it (if any) is the card's handoff again.
On the card it is **Delete** beside **Update**. The handoff's author may delete
it, as with a comment, and so may anyone who can edit the card; the board's
activity keeps a line saying it was deleted.

Over the API, `POST /api/cards/:id/handoff` with `next_step` and `body` (or
`{"clear": true}`) writes one, `DELETE` deletes the current one and `GET` reads
it with its history; a card's JSON carries it as `handoff`. Over MCP it is the
`leave_handoff` tool (`delete: true` to delete). Exports
between servers carry every handoff, signed by whoever imports them.

---

← [Time tracking](time-tracking.md) · [Contents](../manual.md) · [Verified work](verified-work.md) →
