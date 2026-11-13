
## Automations and alerts

A board can carry **rules** that the server runs by itself: when something
happens to a card (or when enough time passes), do something about it.
They keep running after you have gone, so treat adding one as a change to
how the board behaves, not as a way of doing this task — for a one-off,
just make the change yourself.

A rule is `{"trigger": …, "conditions": […], "actions": […]}`. Write it
out and POST it as `spec` and it is stored exactly as given; POST `text`
instead and the server's model turns a sentence into one for you (which
needs an API key configured there, and can misread you). **Prefer
`spec`** — you know the vocabulary, and a spec cannot be misunderstood.
`GET /api/automations/vocabulary` is that vocabulary as data, with an
example; it is also under `automations` in the vocabulary below.

For the common cases there is a shorter way still: POST `preset` and
`params` — one of the ready-made rules listed at
`GET /api/automations/presets` (follow a board, a list or a card, hear
about comments or a field changing, reminders when work is due or has
gone quiet, tidying Done), filled in with the few fields it asks for.
No model is involved, and what it stores is an ordinary rule.

Only a board's owner may list or change its rules. Every rule is checked
before it is stored: an unknown trigger, action or condition is a 422 with
the reason, so a rule that saves is a rule that runs.

An `email` action may only go to people who can read the board — its
owner and those it is shared with — at most
<%= @max_recipients %> of them per action, and
anyone else is a 422 naming them; access taken away later stops the
email at send time. A rule has at most <%= @max_actions %>
actions and a board at most <%= @max_rules %> rules.
What rules send is metered: <%= @emails_per_hour %>
automation emails an hour across everything one person owns, and
<%= @callbacks_per_minute %> callbacks
a minute per board; past that the action fails with "held back" in the
rule's last error, and the next window carries on.

- **triggers** — <%= @triggers %>
  (the last five are checked on a timer, the rest fire on the event)
- **conditions** — any number, all must hold; fields
  <%= @condition_fields %>; ops <%= @condition_ops %>
- **actions** — <%= @actions %>
- text in an action may use <%= @placeholders %>

```sh
# the grammar, with an example you can adapt
curl -s -H "$H" B/api/automations/vocabulary

# a rule, written out: move stale work back and say so
curl -s -H "$H" -H 'content-type: application/json' B/api/boards/1/automations \
     -d '{"name": "Return stale work",
          "spec": {"trigger": {"type": "card_stale", "days": 7, "column": "In Progress"},
                   "conditions": [{"field": "completed", "op": "is", "value": false}],
                   "actions": [{"type": "move_card", "column": "Backlog"},
                               {"type": "comment", "body": "Untouched for a week, back to the backlog."}]}}'

# the same thing described in words, for the server's model to write
curl -s -H "$H" -H 'content-type: application/json' B/api/boards/1/automations \
     -d '{"text": "move anything in In Progress untouched for a week back to Backlog"}'

# a ready-made rule: hear about every card that arrives in Doing, by email
curl -s -H "$H" B/api/automations/presets
curl -s -H "$H" -H 'content-type: application/json' B/api/boards/1/automations \
     -d '{"preset": "follow_list", "params": {"column": "Doing", "notify": "email"}}'

# list, inspect, switch off, run now, remove
curl -s -H "$H" B/api/boards/1/automations
curl -s -H "$H" "B/api/boards/1/automations/Return%20stale%20work"
curl -s -X PATCH -H "$H" -H 'content-type: application/json' \
     B/api/boards/1/automations/3 -d '{"enabled": false}'
curl -s -X POST -H "$H" B/api/boards/1/automations/3/run
curl -s -X DELETE -H "$H" B/api/boards/1/automations/3
```

Running a rule by hand is how you check it: a timed rule first forgets
what it has already acted on, then looks again, and the reply says how
often it fired (`{"fired": 2, …}`) and carries `last_error` if an action
could not be resolved.

**Callbacks** are the `webhook` action: when the rule fires, the server
calls a URL of yours with the card. A `post` (the default), `put` or
`patch` sends JSON —

```json
{"rule": "Tell the robot", "event": "card_updated", "at": "2026-10-03T12:00:00Z",
 "board": {"id": 1, "name": "Launch", "code": "launch", "url": "B/boards/1"},
 "card": {"id": 42, "title": "Ship it", "url": "B/boards/1/cards/42",
          "column": "In Progress", "priority": "high", "assignee": "David",
          "start_date": "2026-10-20", "due_date": "2026-11-01",
          "completed": false, "status": "open", "health": "at_risk",
          "percent_complete": 40, "blocked": false,
          "flags": ["review"], "tags": ["backend"],
          "bar": "Tests pass", "paths": ["lib/ship/**"], "profile": "feature",
          "verify_state": "pending"}}
```

— and `{"type": "webhook", "url": "…", "method": "get"}` sends the same
fields as query parameters instead, flattened to `card.title`,
`card.url`, `card.due_date` and so on (lists comma-separated, anything
unset left out). `status` is `open`, `done` or `archived`; `bar`, `paths`,
`profile` and `verify_state` are what verified work and lanes keep on the
card (null or empty where unset), and a rule can change the first three
with `set_bar`, `set_paths` and `set_profile`. The URL may
itself carry placeholders, so `https://example.com/hooks/{{card.id}}`
works — in the path and query only, never the host, and each value is
percent-encoded. Only `http`/`https` URLs to public addresses are called:
loopback, private, link-local and CGNAT/tailnet addresses are refused
(when the rule is saved if the URL names one outright, and on every call
after resolving it) unless the server's admin has opened them with
`SLIPDOCK_EGRESS_ALLOW`. Redirects are not followed, nothing is retried,
and a non-2xx answer never stops the rule's other actions. A call that
never got an answer is logged as `unreachable` or `timed out`.

Every call is logged once it finishes — and since calls go out in the
background, the log is where a failed one shows up:

```sh
curl -s -H "$H" "B/api/boards/1/automations/callbacks?limit=20"
```

```json
{"callbacks": [{"id": 9, "at": "2026-10-04T11:00:00Z", "rule": "Tell the robot",
                "rule_id": 3, "card": "Ship it", "card_id": 42, "method": "POST",
                "url": "https://example.com/hooks/kanban", "ok": false,
                "status": 503, "error": "HTTP 503", "duration_ms": 140}]}
```

Newest first, `limit` up to 200 (default 50); the board keeps its newest
200. `status` is null when nothing answered — `error` then says why.
`slipdock callbacks <board>` is the same on a shell.

**Alerts** are the `alert` action: a line in the header bar of the web UI
that stays until the reader dismisses it. They are how a rule tells a
person something without emailing them, and they are worth reading before
you start work — they are the board saying what it thinks is wrong.

```sh
curl -s -H "$H" B/api/alerts            # what is waiting for you
curl -s -X DELETE -H "$H" B/api/alerts/7   # dismiss one (yours only)
curl -s -X DELETE -H "$H" B/api/alerts     # dismiss the lot
```

Dismissing is per person: yours going does not take anyone else's.
