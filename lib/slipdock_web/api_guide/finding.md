
## Finding something nobody can name

`GET /api/boards/<id>/cards?q=…` filters by substring: the right tool when
you know a word that is in the title. Its other filters answer the
questions that are about state rather than words — `due=overdue`,
`due=week`, `deps=blocked`, `assignee=me`, `priority=high`, `flag=review`,
`completed=false`, `kind=document` — and they mean exactly what the same
words mean in a swimlane or a table, because they are the same filters. A
value that is not one of the listed buckets is a `400`, never a silent
everything.

`kind` is the one filter that asks what a thing *is* rather than how it is
doing: `kind=card` or `kind=document`, a document being a card whose whole
content is the file on it — no description, nothing to tick off, no
subcards (comments are allowed) — which is
what "Add a document…" leaves in a list. Every card's JSON says which it
is in `kind`. Wiki pages are the third kind of thing a list holds and are
not cards: ask `GET /api/boards/<id>/pages` for those, or filter a view
with `kinds=page` (below), which is the one place all three are counted
together.

`GET /api/search?q=…` is different. It searches by **meaning**, across every
card, comment, status update and recording transcript on every board you can
see, so the words in
the query need not appear anywhere in the result. Reach for it when:

- the person describes a thing rather than naming it — "the card about the
  refund rounding problem", "whatever we said about the vendor contract";
- the answer is likely in a **comment** or a status update rather than a
  title, which is where most of what a team actually decided ends up;
- you do not know which board to look on. Substring search is per board;
  this is across all of them at once.

Each result is a card (or a wiki page), with `matches`: the chunks that matched, each with
its `kind` (`card`, `comment`, `status_update`, `transcript`, …), the text
and a `url` that lands on that chunk rather than the card —
`…/cards/12?at=comment-7`, `…/cards/12?at=transcript-5-part-2`. Read the
match, not just the title — it is why the card came back — and give the
person the match's `url` when you point them at it. Then
`GET /api/cards/<id>` for the whole thing before acting on it.

Archived cards are left out unless you pass `archived=true` (each card
result says `archived`). A card's id (`#123`) or its link as `q` finds that
one card first, archived or not, if you can read it — a link returns only
the card, and works even where semantic search isn't set up.

```sh
curl -sH "$H" --get --data-urlencode 'q=what did we decide about refunds'   <%= @base %>/search
curl -sH "$H" --get --data-urlencode 'q=flaky tests' -d board=qvm-v1-rem -d limit=5   <%= @base %>/search
```

`POST /api/ask` is the same search with a model in front of it: ask a
question in prose and it answers from the tools it is given — the same
search, one card in full, a board's cards list by list to any depth (so
it can count), a board's lists and tags, one person's work across every
board, the activity log for a date range, and this person's alerts. It
returns `answer`, the `searches` it ran and the `sources` it read. Use
`/search`
when you want to pick the card yourself — which is most of the time, and
always when you are about to change something. Use `/ask` when the person
asked a question in words and wants an answer rather than a list. Over
MCP it is the `ask` tool (`question`, and `board` to keep to one).

`GET /api/saved-queries` is what this person has chosen to keep asking —
their own, and not derivable from the boards. Worth a look alongside
`/api/favourites` at the start of a session: favourites say where they
work, saved queries say what they keep wanting to know.

Both search endpoints are scoped to your token's owner: they can return
nothing you could not open directly. A token confined to some boards
searches only those, and `/ask` refuses it with a 403, because the
assistant reads across every board. If `/api/search/status` says `available: false`, the index
has not been built — say so rather than concluding there is nothing there.

