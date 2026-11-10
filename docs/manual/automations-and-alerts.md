[Slipdock — the manual](../manual.md)

## Automations and alerts

Every board has an **Automations** panel (the *…* menu → *Automations*, or
`/boards/:id/automations`; owners only). You describe a rule in your own
words and the model turns it into a spec the app runs:

> when creating a new card in Doing, email someone@example.com
> automatically move cards in In progress to Backlog if they've not been touched for 7 days
> show an alert if a card is due in less than 24 hours

The rule is stored as its sentence *and* as the spec, and the panel shows
the spec read back as a sentence ("When a card is added to Doing, email
someone@example.com.") plus the raw JSON under *What this does, exactly*. Nothing
the model invents can get through: every trigger, condition and action is
checked against the vocabulary before the rule is saved, and unknown keys
are dropped.

**Ready-made rules.** Above the composer sits a gallery of the rules most
boards want, each filled in with a short form instead of a sentence — and
because no model is involved, they work on a server with no AI key:

- *Follow* — this board (every new card), a list (every card added to it or
  moved into it), one card (anything that happens to it), comments
  (optionally only on one person's cards), a field changing (or any field),
  cards assigned to someone (you, by default), a card being flagged.
- *Remind* — due soon (N hours before), overdue, gone quiet (untouched for
  N days, optionally in one list).
- *Tidy* — complete cards that land in the done list, archive what has sat
  there for N days, have a tag set the priority, and a *Weekly tidy-up*
  that looks the board over once a week and alerts you to what it found
  (see [Tidying up](tidying-up.md)), and flag what arrives by email (cards,
  optionally in one list, or pages, optionally in one folder) `review`, or
  any flag you pick, so somebody reads it before it is worked.
- *Connect* — call a URL on every change.

Every *Follow* and *Remind* rule asks how to tell you: an alert in the header,
an email (to you unless you give another address), both, or an email to
whoever the card is assigned to. What a preset adds is an ordinary rule — it
appears in the list, reads back as a sentence, and can be switched off or
deleted like any other.

**Triggers.** Events — a card created, arriving in a list (added there or
moved there), moved, updated (optionally one named field), completed,
reopened, archived, assigned, tagged, flagged, commented on, or anything at
all happening to a card (once per change). Mail arriving (see [Rules for
what mail brings in](#rules-for-what-mail-brings-in)). Clock-driven — a card untouched for N days, due within a
window, overdue, starting soon, or simply a time of day. Time-based rules
are checked once a minute and fire once per occasion (one due date, one
card going stale, one day), so nothing repeats itself.

**Conditions.** Any number, all of which must hold: the card itself (by
number, to follow one card), list, priority, tag,
assignee, flag, title, description, completed, archived, blocked, whether a
due date or assignee is set, the dates themselves, health, age in days, and
the verified-work fields: the card's `bar`, its lane `paths`, its `profile`
and `verify_state` (`pending`, `held`, `rejected`, `accepted`, `merging`) —
tested with `is`, `is_not`, `contains`, `any_of`, `none_of`, `is_set`,
`before`, `after`, `within_days`, `older_than_days`, `gt`, `lt`.

**Actions.** Email an address or whoever the card is assigned to; raise an
alert; move the card; set priority; add or remove tags and flags; assign or
unassign; comment; set or clear the due date; complete, reopen or archive;
add checklist items; create a card (with no title given it is
`<rule>: <card> <date>`, as an alert's is); start a wiki page; call a URL back;
write a line in the activity log; colour the card (`set_colours`: its
`cover`, every edge with `border`, or one with `border_top`, `border_right`,
`border_bottom`, `border_left`, each a palette colour or `none`); set the
card's bar (`set_bar`, `none` clears it), its paths (`set_paths`, globs,
with `mode` `replace`, `add` or `remove`) or its profile (`set_profile`).
Text in an action can use `{{card.title}}`, `{{card.url}}`,
`{{card.due_date}}`, `{{card.assignee}}`, `{{card.bar}}`, `{{card.paths}}`,
`{{card.profile}}`, `{{card.verify_state}}`, `{{board.name}}`, `{{today}}`
and the rest.

**Bars, lanes and profiles.** A rule can read, fire on and change what
[verified work](verified-work.md) keeps on a card. `card_updated` with
`field` `bar`, `paths`, `profile` or `verify_state` fires when one changes
(`verify_state` changes when an agent submits the card and when it is held,
accepted or rejected), and a callback carries all four. The checks verified
work makes hold agents only, so a rule, which is the board owner's standing
say, can change a bar that locked when work started and lower a started
card's profile, as a person can. A profile a rule sets is recorded as the
rule's.

```json
{"trigger": {"type": "card_updated", "field": "verify_state"},
 "conditions": [{"field": "verify_state", "op": "is", "value": "rejected"}],
 "actions": [{"type": "add_flags", "flags": ["flagged"]},
             {"type": "comment", "body": "Sent back. Bar: {{card.bar}}"}]}
```

### Rules for what mail brings in

Two triggers fire when mail sent to the board ([Emailing your
board](emailing-your-board.md)) has made something, so a rule can process it
as it arrives — "when a card arrives by email, flag it for review":

- `card_emailed` — a card made by mail to the board's `card-…@` address or a
  personal `add-…@` one, once its description and files are on it. It fires
  as well as `card_created`, but only for mail, and late enough that a
  condition on the description sees the message. `column` limits it to cards
  that land in one list.
- `page_emailed` — a wiki page made by mail to a `page-…@` address (the
  board's or a folder's), or added to with a `+ Title` subject. `how: new`
  or `how: added` limits it to one of the two, and `folder` to pages in one
  folder, by path (`Inbox`, `Notes/Calls`).

A page rule acts on the page: it can add or remove flags and tags, set the
priority or the due date, assign or unassign, and do anything that needs no
card (email, alert, log, call a URL, create a card, the gardener). A rule
that would move, comment on, complete or send a page to a runner is refused
when it is saved. Both triggers add `{{email.from}}` and `{{email.subject}}`,
and a page rule `{{page.title}}`, `{{page.code}}`, `{{page.url}}` and
`{{page.folder}}`; a callback from a page rule carries `page` (id, code,
title, url, folder, summary, priority, flags, tags) and `email` in place of
`card`. A rule that fails never bounces the mail: the card or page is kept,
and the error is the rule's last error.

```json
{"trigger": {"type": "page_emailed", "folder": "Inbox"},
 "actions": [{"type": "add_flags", "flags": ["review"]},
             {"type": "alert", "title": "New in the wiki: {{page.title}}"}]}
```

**Who gets email, and how much.** Automation email goes out under this
server's name, so it only goes to people who can read the board: its owner
and the people it is shared with. A rule naming anybody else is refused when
it is saved, and somebody whose access is taken away afterwards stops
getting it. One email action reaches at most 10 addresses, a rule has at
most 20 actions and a board at most 50 rules. Each owner's rules send at
most 200 emails an hour between them, and each board's rules make at most
120 callbacks a minute; past either, the action fails with "held back" as
the rule's last error and the next window carries on. At most 50
deliveries are in flight at once (`config :slipdock, :automations,
max_in_flight: N`); beyond that a delivery is dropped and logged rather
than queued.

**Callbacks.** "POST to https://example.com/hooks/kanban whenever a card is
archived", "when a card changes, GET https://example.com/hooks/kanban". The
server calls the URL with the card: its id and title, a link straight to
it, the list it is in, priority, assignee, start and due dates, whether it
is completed, its status (`open`, `done` or `archived`), stated health, per
cent complete, whether it is blocked, and its flags and tags — plus the
board (name, code and link), the rule's name, the event and the time. A
POST, PUT or PATCH sends that as a JSON body; a GET sends the same fields
as query parameters, flattened to `card.title`, `card.url`,
`card.due_date` and so on, with lists comma-separated and anything unset
left out. The URL can use placeholders too, so
`https://example.com/hooks/{{card.id}}` works. Only `http` and `https` URLs
are called, nothing is retried, and a refusal at the other end never stops
the rule's other actions.

Every call is written down as it finishes: **Recent callbacks**, at the foot
of the Automations panel, lists the newest twenty — the method and URL, the
rule and card that set it off, and what came back (the HTTP status, or why
there was none: a refusal, a timeout, a URL that is not `http(s)`), with
how long it took and when. It updates as calls land, so you can fire a rule
and watch. The board keeps its newest 200; `slipdock callbacks <board>` and
`GET /api/boards/:board/automations/callbacks` read the same log.

A rule normally watches its own board; say "including subcards" and it
watches the whole tree beneath it. Rules can be switched off, reworded,
deleted, and (when time-based) run by hand — which also forgets what they
have already acted on. Each rule shows how often it has run and what went
wrong last time; an action that can't be resolved (a renamed list, a person
who has left) fails on its own and leaves the rest of the rule running.
Rules change cards, and changing a card sets off more rules, so a run
carries a depth and stops after three: one rule feeding another works, two
rules batting a card back and forth does not run for ever.

**Alerts** are the quiet action: no email, just a line in the collapsible
section in the header bar of every page, with a count and the worst
severity (info, warning, urgent) always visible. Each person dismisses
their own — dismissing yours leaves everyone else's alone — and an alert
raised while you are looking at a page appears there without a reload. An
alert is only shown to people who can read the board it came from, and a
rule that keeps noticing the same thing about the same card says it once.

The code lives in `Slipdock.Automations` (the context, events and the
scheduled pass), `Slipdock.Automations.Spec` (the vocabulary, validation and
the sentence it reads back as — the one place that knows the shape),
`Slipdock.Automations.Runner` (matching and doing), `Slipdock.Automations.Parser`
(plain English → spec), `Slipdock.Automations.Scheduler` (the timer),
`Slipdock.Automations.Notifier` (email and callbacks, off the caller's back)
and `SlipdockWeb.AlertsHook` (the header bar, mounted into every
authenticated page). `config :slipdock, :automations` turns rules off
(`enabled: false`), changes how often the timer runs (`interval`) or sends
deliveries inline (`async: false`, as the tests do).

---

← [AI assistant](ai-assistant.md) · [Contents](../manual.md) · [Runners](runners.md) →
