# Live query blocks

A fenced ```` ```slipdock ```` block in a page body is a question, answered
when the page is **read**. A hand-typed list of blocked cards is wrong by
Tuesday; this never is.

````
```slipdock
view: table
board: this
filter: flag=blocked, due < +7d, priority in high|critical
group: assignee
sort: due_date asc
fields: title, assignee, due_date, status
limit: 20
empty: "Nothing blocked and due this week."
```
````

**Read the grammar and try the block before you write it into a page.** Both
come from the parser, so neither can be out of date:

```sh
slipdock page query-help                  # views, settings, operators, fields
slipdock page query <board> --body -      # what this block would answer, right now
```

A block that cannot be answered renders as a red note on somebody's document.
Trying it costs one call.

## Settings

| Setting | Means |
|---|---|
| `view:` | `table` (default), `list`, `board`, `count`, `progress`; `timeline` and `calendar` are presets of the first two |
| `board:` | `this` (default), `tree` (this board and everything beneath it), or another board's code |
| `filter:` | clauses separated by commas; all must hold |
| `group:` | a swimlane axis: `assignee`, `priority`, `tag`, `flag`, `list`, `status`, `due_date`, … |
| `sort:` | `due_date asc`, `priority desc`, … |
| `fields:` | which columns a table shows |
| `limit:` | at most this many cards |
| `empty:` | what to say when nothing matches |
| `saved_view:` | embed a saved view instead of spelling its filters out |
| `card:` | one card, for `view: progress` — its whole subtree rolled up |
| `assigned:` | `me`, or `@name` — one person's work |
| `done:` | `all`, `hide`, `only` |

## Filters

```
field = value        is                  field != value      is not
field ~ text         contains            field !~ text       does not contain
field in a|b         any of              field not in a|b    none of
field < value        before / less       field > value       after / greater
field within 7d      a date in N days    field older than 30d
field set            has a value         field not set
```

Values: `today`, `tomorrow`, `yesterday`, `+7d`, `-3d`, `YYYY-MM-DD`, `true`,
`false`, a number, or text. Fields are the automations' condition vocabulary
plus the friendly spellings a document wants — `due` for `due_date`, `list`
for `column`, `status` for `completed`. `slipdock page query-help` prints the
full list from the server.

## Permissions

A block is answered with **the reader's** permissions, every time — never the
author's. A board the reader cannot read is dropped before a single card is
looked at, so a document can never become a way to see cards somebody could
not otherwise open. Two people opening the same page can legitimately see
different answers.

## Inline

In a sentence: `{{count: flag=blocked}}`, `{{progress:412}}`,
`{{card:412.due_date}}`, `{{board.name}}`, `{{today}}`.

> There are {{count: flag=blocked}} blocked cards as of {{today}}.

An expression the app does not understand is left exactly as written. That is
deliberate: a template page's `{{card.title}}` is filled when a page is *made*
from it, and must still read as itself when the template is opened.

## When not to use one

- When the picture is the point, link the view instead:
  `[[view:Blocked work]]`. A document is a column of text, not a canvas.
- When the answer should *not* move — a decision record saying what was true
  on the day — write the list out. A live query is for the places staleness
  would be a bug.
