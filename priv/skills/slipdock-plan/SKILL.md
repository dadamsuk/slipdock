---
name: slipdock-plan
description: Turn an idea into a plan on the user's Slipdock board the way the board's handbook Playbook says — size the ask (card, feature or system), run the stages that size takes (grill, decide, principles, spec, cards), and write the answers into the handbook and onto cards. Use when asked to "plan this", "I want to build…", "break this into cards", "spec this out" or "where do we start". Not for "add a card…": a card-sized ask gets one card and nothing else.
---

# Planning on the board

The board says how it plans: its handbook's **Playbook** page
(`Handbook/Playbook`). This skill carries that page out. It reads the page,
sizes the ask, runs the stages the size takes, and writes each answer where
the page says: Decisions, Principles, the spec on the epic, and the cards.
Everything it needs, apart from this file, it reads from the board. There
are no tools of its own: the `slipdock` CLI, or the Slipdock MCP tools
(`read_page`, `write_page`, `create_card`, `update_card`), are enough.

Start once per session with `slipdock guide` (MCP `get_guide`). Its board
lines, list names and *Epics and subcards* win over anything here.

## 1. Find the handbook

```sh
slipdock handbook <board>        # the index: every page's code, and the decisions
```

(MCP: `list_pages` with folder `Handbook`.) A subcard's board resolves to
its root, so the epic's sub-board finds the same handbook.

**No handbook:** say so, and offer to install one: `slipdock tools
install-board handbook --board <board>` (MCP `install_tool` with `tool:
"handbook"`, `board`). Install it only when the person says yes; then carry
on from its Playbook, which starts as the baseline seed. If they say no, or
nobody is there to ask, carry on from **The baseline** below, and don't
install anything.

Then read, whole: the **Playbook** (`slipdock page read <code>`, MCP
`read_page`), the **Principles** page, and the list of **Decisions**, so
nothing already decided is asked again.

## 2. Size the ask

Apply the Playbook's `## Sizing` in the order it gives, take the first size
whose trigger matches, and say which one matched, in one line: "Feature: it
adds a page." Between two sizes, take the smaller and say so.

**Card-sized:** make the card as the Playbook's `## Card shape` says (with
no such section, the guide's: `slipdock guide epics`), and **stop**. Don't
grill, write a spec or make an epic. "Make the login button red" is one
sentence and one card.

## 3. Run the stages

For each stage the size takes, in the Playbook's order, read the stage's
`##` section: what it **asks**, the **skill** it uses, what it **produces**
and where it **writes to**. Then:

- **The skill.** When the section names one (`skill: <name>`), take the
  first of these that has it, and say which you used ("Grill: `grilling`,
  enabled on this board from mattpocock/skills"):
  1. **Enabled on the board.** `slipdock skills board <board> <name>`
     prints its pinned text (MCP: `get_guide` with `board`, the `skills`
     entry of that name, its `text`). Follow that text for the stage. It is
     the version a board writer read and pinned; a `changed` status means
     upstream moved on and the pinned text is still the one to use.
  2. **Installed here.** It is in your list of available skills: invoke it.
  3. **Neither:** use this file's text for the stage (**Stage texts**
     below).

  Either way, bring what the skill produced back to this stage's
  *Produces* and *Writes to*: the writing is this skill's. A board with no
  skills enabled answers with none, which is the usual case.
- **Already done:** a stage whose output is already on the board (a
  Decision that covers the choice, a spec page on the epic) is skipped.
  Say so, and name what was there.
- **One stage at a time.** Show the person what the stage produced before
  writing it, and fold in what they change.
- **Nobody there** (a runner job, a loop): don't answer your own questions.
  Put the grill's or decide's questions, or the spike candidates, to the person as a wait (`slipdock
  wait <epic> "intro" --question Q --question Q --kind product`, MCP
  `update_card` `wait`) and stop; the answer starts the next pass. Write
  only what doesn't need them.
- **Spikes stop the plan.** With spike cards made, stop: leave a handoff
  on the epic, `slipdock handoff <epic> --next "Planning resumes at Spec
  once spikes #… are answered"`. Accepting the last opens a `product` wait
  on the epic. **Resuming**, read each accepted spike's answer page and
  start at Spec, writing what the answers changed. An *inconclusive* answer
  goes to the person: another spike, the risky card first, or drop it.

## 4. Write where the Playbook says

- **Decisions:** one page each, in `Handbook/Decisions`, titled
  `Decision: <what was chosen>`, with four parts: **Context** (what forced
  the choice), **The choice**, **Alternatives** (each, and why not),
  **Where decided** (the conversation or card, and the date). Then pin it
  to the epic.
  ```sh
  slipdock page new <board> "Decision: Postgres for storage" --folder Handbook/Decisions --body - <<'EOF'
  …
  EOF
  slipdock page pin <code> --card <epic>
  ```
- **Principles:** each one is a short paragraph (the two ways, the one
  taken, why) and an item in the page's `## Rules`, numbered with the next
  unused id: `- **PRIN-n** should · judgement · <the rule, in one line>`.
  A rule is a person's call. When the person agreed it in this
  conversation, append both: `slipdock page section <code>
  "Principles/Baseline" --append -` (the text on stdin) for the
  paragraph, and the same for `"Principles/Rules"` with the item.
  Otherwise, file both as a proposal for a person to apply: `slipdock
  garden propose <board> -` with an `edit_section` step for each section,
  its `body` the whole section as it should read, the new text added.
- **The spec:** a page on the epic, `slipdock page new <board> "Spec: <the
  epic's title>" --card <epic> --body -` (MCP `write_page`). For a
  system, the first sections of the Specification page too: a `##` per
  feature, appended to its features section (`slipdock page section
  <code> "Specification/Features" --append -`; `page section` can't make
  a section that isn't there yet).
- **The spikes:** the epic and its sub-board first, then one subcard per
  confirmed question, a spike by its profile (any board takes it), no
  paths: `slipdock add <sub> "Spike: <question>" --profile spike --bar
  "<question>; an answer is …"`.
- **The cards:** the epic if there isn't one, its sub-board (`slipdock
  subboard <epic> --template Simple`), then the subcards in build order,
  each as `## Card shape` says. On a board that verifies work or keeps
  lanes, give each its bar and paths as you add it (`slipdock add <sub>
  "<title>" --bar "…" --paths "…"`). Set `slipdock blocked-by <card>
  <other>` only where one card builds on another's output.

Finish with one short message: the size, each stage and what it wrote
(page codes, card ids), the stages skipped and why, and anything left open.

## 5. The person's defaults

When the Playbook's `## Defaults` names a page (`defaults: W-123`, their
own Knowledge Base), read it before the decide stage. For each choice the
decide stage makes, propose the default with its rationale and ask. Record
the outcome, the default or not, as a Decision on *this* project. A default
is never imposed. With `defaults: none`, ask from scratch.

## Stage texts

The built-in text for each stage, used when the Playbook names no skill for
it, or names one that is neither enabled on the board nor installed here.

### Grill

Ask one question at a time, the most important first, until you can say
back: what is built, for whom, what done looks like, and what is out of
scope. Don't ask what the handbook or a Decision already answers, or what
the person plainly doesn't care about. Offer your best guess with each
question, so a yes is enough. Stop when the next answer wouldn't change the
plan. Produce a brief: the problem, who it is for, done-when, out of scope,
open questions.

### Spike

For each open question in the brief, answer three: only building answers
it (not a person, not reading)? A "no" changes the spec (say how)? A late
"no" costs more than the spike, counting flow time and lane contention as
well as rework? All three: a candidate. Fails only the third: its card goes
first in build order. Show the candidates; only those the person confirms
become spikes, one sitting each. None pass: skip the stage and say why.

### Decide

List the choices the work can't start without (stack, hosting,
deployment, data store, auth: only those that apply). For each, propose
one option with a line of rationale, the default first if there is one,
and name the alternatives you considered. Ask. Write each answer as a
Decision page. Don't decide what the person hasn't, and don't reopen a
choice an existing Decision already settles.

### Principles

Find where the work could go two right ways and the person has a
preference: naming, error handling, how deep tests go, one place for each
concern. Suggest at most three or four, each as the two ways and the one
you'd take. Keep the ones the person agrees to; drop the rest. A principle
the baseline already holds isn't repeated.

### Spec

Write what each part does for the person using it, and its rules and edge
cases, in the brief's words. Then goals, non-goals and done-when for the
whole. Keep it to what a builder needs to start; leave the how to the
cards and the code. Name the handbook sections the work will touch.

### Cards

Turn the spec into cards: the fewest that each fit one sitting, one agent,
one PR, in the order they can be built. Each is shaped as Card shape says:
what, where, done-when, nothing the person didn't say. Never an epic with
one subcard. Use `blocked_by` where one card reads another's code, schema
or decision, and list position for mere preference.

## The baseline

When the board has no handbook, or its Playbook has no `## Sizing`, use
this, which is the Handbook Tool's own seed:

- **System**: a new deployable or service, a new repository, or a board
  with no code yet. Stages: Grill, Spike (when one is needed), Decide,
  Principles, Spec, Cards.
- **Feature**: a new user-facing surface (a page, a command, an API
  resource), a new external integration, a change to the data model, or
  more than one sitting's work. Stages: Grill, Spike (when one is needed),
  Spec, Cards.
- **Card**: anything else. One sitting, one agent, one PR, said in a
  sentence. Make the card, as Card shape says. No stages.

Without a handbook, Decisions, Principles and the spec go where they
would on a handbook's board, but as plain pages pinned to the epic: offer
the handbook again when the work is done.

## What this never does

- Plan a card-sized ask, or make an epic to hold one card.
- Write a principle into `## Rules` that the person didn't agree to.
- Impose a default, or decide for the person.
- Copy the Playbook onto a card. Cards link to the pages they need.
- Change the server, or need a tool beyond the CLI and the MCP tools.
