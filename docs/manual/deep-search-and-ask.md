[Slipdock — the manual](../manual.md)

## Deep search and Ask

The search box in a board's toolbar filters the cards in front of you by
substring. Type a card's id (`123` or `#123`) or its link and it finds that
card; if the card is elsewhere in the board's tree (a subcard on an epic's
board), the strip under the toolbar offers it as a link, with its board. Type a
wiki page's code (`W-31`) and the strip offers that page, whether or not it is
on the board. `slipdock cards <board> --search`, the API's `q` and MCP's
`list_cards` take an id the same way. That is the right tool when you can half-remember the title and no
help at all when you cannot — when what you remember is that somebody said
something about refunds, on one of eleven boards, some time in the spring.

One page answers that, in two modes: **Search finds cards; Ask gives answers to
questions.** The toggle at the top switches between them and carries whatever
is in the box across, so "I searched, now ask the same thing" is one click.
Each mode keeps its own state — your results are still there when you come back
from asking. The mode is the URL (`/search` and `/ask`, the header's ⌕ and ✨
icons, or `Ctrl-P`), so it is linkable and the back button works through it.

**Search** embeds every card, comment, status update and recording transcript
as a vector; your query
is embedded the same way and matched by meaning, so the words you type need
never appear in what comes back. A result is a **card**, because a card is what
you open. Under it are the chunks that actually matched — the comment, the
status update, the description — each labelled with what it is. That matters: a
card whose only match is a two-year-old comment looks exactly like a card whose
title is a bullseye until you can see which it was.

Each match is a link of its own, to where it is rather than to the card: the
card opens scrolled to that comment or status update, lit up for
a moment. A recording's transcript is labelled with the file and the part
(*transcript of call.mp3, part 2 of 5*); its link opens the transcript at that
part, shaded. A page section's link goes to its heading. The links are
`…/cards/<id>?at=comment-7`, `?at=status-update-7` and
`?at=transcript-5-part-2`, so they can be shared; the API gives each match
its `url`, and `slipdock search --full` prints it. Filter to one board or
include archived cards. A card's id (`#123`) or link as the query finds that
card first, archived or not and with no AI needed; a link is nothing but the
card, while a bare id goes on to search for the number as well.

Either mode's box has a **star**: press it and the query is saved. In Ask the
box empties when you send, so each question in the conversation carries a star
of its own — which is the honest place for it, since whether a question is
worth keeping is something you know once you have seen the answer. Only the
question is kept, never the answer — the answer to "what's at risk this week"
is a snapshot of a Tuesday, and the point of saving it is to ask again. Saved
queries appear where the examples were, and **once you have saved one the
examples go**: your own questions are better examples than ours, and a list of
both is a list of neither. The two modes keep separate lists, and the whole
thing is yours alone, like favourites.

**Ask** hands that same search to a model as a *tool*. The assistant on a board
page is handed the page you are looking at and answers from that; this one is
handed nothing at all. It searches, reads the cards worth reading, searches
again if the first attempt missed, and then answers — showing you what it
searched for and linking every card it looked at, because an answer assembled
from four cards on three boards is worth very little if you cannot go and check
it.

Search is only one of its tools, because most questions about a board are not
really searches. It can **list** a board — every list with an exact count,
filtered by priority, tag, flag, text, due date, dependency or assignee, and
to any depth, so subcards are counted when it matters and it says which it
counted when they are not. It can **describe** a board: the lists, the tags
and people available, the milestones, the custom fields. It can list **one
person's work** across every board and level, grouped by when it is due — the
My work page, for anybody. It can read the **activity log** for a date range,
with the comments and status updates written in it, which is the only way to
answer "what changed this week" — the search index has no sense of time. And
it can read the **alerts** the automations have raised for you. A search
ranked by meaning returns its best matches and nothing else, so counting,
completeness and chronology all used to be questions it had to decline.

Search runs as you type; Ask waits for Enter, because a model call should
be asked for. It can read, not write; edits stay with the board assistant,
where the scope is visible.

Both are scoped by the same permissions as everything else, and slightly more
tightly. A board you can only reach through a shared saved view contributes
nothing — a search has no view to apply, so it would be all or nothing, and
nothing is the safe half. A card shared with you on its own is searchable
without its neighbours coming along.

### How it works

`Slipdock.Search.Chunk` breaks each card into the pieces a person wrote — the
card, each comment, each status update, and the transcript of each recording on
it (split between lines into parts when it is long, each part naming the
recording and the card). `Slipdock.AI.Embeddings` turns each into
a unit-length vector through OpenRouter's `/embeddings` endpoint, stored packed
as 32-bit floats in `search_embeddings` (see `Slipdock.Search.Vector`, which
keeps cosine similarity to a plain dot product). A query is embedded the same
way and every chunk you may see is scored: no index, no approximation, exact
answers in a few milliseconds at this size. A plain substring match runs
alongside and lifts exact tokens — a version number, a name — that a vector
would blur.

Writes queue their card with `Slipdock.Search.Indexer`, which embeds a couple of
seconds later, so saving a card never waits on an HTTP call. Chunks are
content-hashed, so unchanged text is never re-embedded; a card that moves board
has the board on its chunks corrected *inline*, because that field is what
permission filtering reads.

On a deployed server (the Docker release), run it inside the release, which
uses the server's own database and the AI key chosen under Configuration → AI
for search and automations:

```sh
docker compose run --rm slipdock reindex   # build or repair the index
slipdock search-status                     # from anywhere: what is indexed, and whether search is on
```

From a source checkout, against a database of your own:

```sh
mix ecto.migrate                  # first: mix does not migrate on start, a release does
mix slipdock.reindex              # build or repair the index
mix slipdock.reindex --stats      # what is indexed right now
mix slipdock.reindex --force      # empty it and rebuild from scratch
```

`mix slipdock.reindex` uses whatever database `DATABASE_URL` names in that
shell — not your live server's unless you point it there — and on one that is
behind on migrations it fails at start with `column … does not exist`. Run
`mix ecto.migrate` and try again. `--force`, `--stats` and `--dry-run` are
`mix`-only; the release's `reindex` is the plain walk, which is what a
restored database or a model change needs.

Run it again after changing the embedding model: vectors from two models are
not comparable. Walking every card is cheap — anything whose text has not
changed is skipped without an API call — so running it is also how you repair
an index that drifted. Embedding a board of a few hundred cards costs a
fraction of a penny.

`SLIPDOCK_AI_EMBED_MODEL` picks the model (default
`openai/text-embedding-3-small`) and `SLIPDOCK_AI_EMBED_DIMENSIONS` the vector
size (default 768 — `text-embedding-3-*` are Matryoshka models, so that is the
full 1536-dimension vector truncated: half the storage for almost none of the
quality).

---

← [Emailing your board](emailing-your-board.md) · [Contents](../manual.md) · [AI assistant](ai-assistant.md) →
