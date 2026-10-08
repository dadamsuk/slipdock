defmodule Slipdock.Search do
  @moduledoc """
  Semantic search across every board, card, comment, status update and wiki
  page the reader is allowed to see.

  The ordinary board search matches substrings of a title, which only finds
  what you can already half-remember. This finds by meaning: "the thing that
  was blocked on legal" turns up the card whose comment said "waiting on the
  contract review", with no word in common.

  ## How it works

  `Slipdock.Search.Chunk` breaks each card into the pieces a person wrote — the
  card, each comment, each status update — and each wiki page into its
  sections, and `Slipdock.AI.Embeddings` turns each into a unit-length vector, stored packed in `search_embeddings` (see
  `Slipdock.Search.Vector`). A query is embedded the same way, and every chunk
  the reader may see is scored by dot product. There is no index and no
  approximation: at a few thousand chunks the full scan is milliseconds and
  the answer is exact. The scan reads the index in batches of
  500 chunks and keeps only the best 120 it has seen so far, so a
  search holds a batch and a short list in memory however large the index
  grows, and never sorts more than those.

  Results are **hybrid**. Semantic recall is good at the question nobody
  phrased the same way and bad at the exact token — a card code, a name, a
  version number — so a plain substring match runs alongside and the two are
  merged, with a keyword hit lifting a chunk's score. Chunks then roll up to
  their card: a card is returned once, scored by its best chunk, carrying
  the snippets that matched.

  ## Permissions

  Nothing is searched that the reader could not open directly.
  `Slipdock.Access.readable_scope/1` resolves a user to the boards and
  individually-shared cards they may read, and every query is filtered to
  those before a single vector is scored. Callers never pass board ids in;
  the user is the scope.

  ## Keeping the index current

  Writes enqueue their card with `Slipdock.Search.Indexer`, which embeds in
  the background a moment later so no save ever waits on an HTTP call.
  Chunks are content-hashed, so unchanged text is never re-embedded.
  `mix slipdock.reindex` does the initial backfill and repairs anything that
  drifted.
  """

  import Ecto.Query, warn: false

  alias Slipdock.Accounts.User
  alias Slipdock.Boards.{Board, Card}
  alias Slipdock.Repo
  alias Slipdock.Search.{Chunk, Embedding, Indexer, Vector}
  alias Slipdock.Wiki.Page
  alias Slipdock.AI.Embeddings

  # How many chunks a search scores before rolling up, and how many cards it
  # returns. The first is generous because several chunks often belong to the
  # same card; the second is what a person or a model actually reads.
  @chunk_limit 120
  @default_limit 20
  # How many chunks are read, bodies and vectors, per trip to the database.
  # Bounds what one search holds in memory alongside the running best.
  @batch_size 500

  # What a keyword hit is worth. Enough to lift an exact token above a merely
  # related chunk, not enough to bury a strong semantic match under a
  # coincidental substring.
  @keyword_boost 0.15
  # What a page gives up against a card of the same score. The card is the
  # live thing; the page explains it. Small on purpose — a decision record
  # that answers the question exactly should still win.
  @page_penalty 0.03
  # The floor a purely semantic chunk must clear to be shown at all. Cosine
  # similarity between unrelated short texts sits around 0.1–0.2 with this
  # model; below this the results are noise dressed as answers.
  @min_score 0.22

  @doc "Whether semantic search can run: embeddings are configured and the index has rows."
  def available? do
    Embeddings.configured?() and Repo.aggregate(Embedding, :count) > 0
  end

  @doc "How many chunks are indexed, and how many cards and pages they cover."
  def stats do
    %{
      chunks: Repo.aggregate(Embedding, :count),
      # DISTINCT over the schema's columns is not what is wanted here, so the
      # count asks for distinct ids directly.
      cards: Repo.one(from(e in Embedding, select: count(e.card_id, :distinct))),
      pages: Repo.one(from(e in Embedding, select: count(e.page_id, :distinct))),
      model: Embeddings.model(),
      dimensions: Embeddings.dimensions(),
      pending: Indexer.pending()
    }
  end

  ## Searching ----------------------------------------------------------------

  @doc """
  Searches everything `user` may read for `query`.

  Returns `{:ok, results}`, each result a map of:

    * `:kind` — `"card"` or `"page"`
    * `:subject` — the card or the page, whichever it is
    * `:card` — the card, with `:board` and `:column` preloaded; nil for a page
    * `:page` — the page, with `:board` preloaded; nil for a card
    * `:score` — the best chunk score, 0.0–1.0-ish
    * `:matches` — the chunks that matched, best first, each with `:kind`,
      `:body`, `:score`, `:source_id` and (for a page) `:section`

  Options:

    * `:limit` — how many results to return (default #{@default_limit})
    * `:archived` — include archived cards (default `false`)
    * `:board_id` — restrict to one board and its sub-boards
    * `:kind` — `:card`, `:page` or `:all` (the default)
    * `:min_score` — override the relevance floor
    * `:token` — the API token asking, whose board scope narrows the user's
      reach further (see `Slipdock.Access.narrow/3`); nil for a person
    * `:batch_size` — how many chunks are scored per read of the index
      (default #{@batch_size}); it changes memory and round trips, never the
      answer
  """
  @spec search(User.t() | nil, String.t(), keyword) :: {:ok, [map]} | {:error, String.t()}
  def search(user, query, opts \\ [])

  def search(nil, _query, _opts), do: {:ok, []}

  def search(%User{} = user, query, opts) do
    query = String.trim(to_string(query))

    cond do
      query == "" ->
        {:ok, []}

      not Embeddings.configured?() ->
        {:error,
         "Semantic search isn't set up on this server: an admin needs to choose whose AI " <>
           "key it uses, under Configuration → AI for search and automations " <>
           "(or `slipdock admin set ai_system_user=<email>`)."}

      true ->
        with {:ok, vector} <- Embeddings.embed(query) do
          {:ok, run(user, query, Vector.pack(vector), opts)}
        end
    end
  end

  defp run(user, query, packed, opts) do
    limit = opts[:limit] || @default_limit
    floor = opts[:min_score] || @min_score
    keywords = keywords(query)

    score = fn row ->
      semantic = Vector.similarity(packed, row.vector)
      boost = if keyword_hit?(row.body, keywords), do: @keyword_boost, else: 0.0
      penalty = if Embedding.page?(row.kind), do: @page_penalty, else: 0.0
      %{row | score: semantic + boost - penalty}
    end

    user
    |> candidates(opts)
    |> best_chunks(opts[:token], opts[:batch_size] || @batch_size, score, floor)
    |> roll_up(user)
    |> Enum.take(limit)
  end

  # Walks the candidates in id order, a batch at a time, keeping only the
  # best `@chunk_limit` scored so far. The running best goes ahead of each
  # new batch before the stable sort, so a tie is won by the lower id — the
  # same answer one batch of everything would give.
  defp best_chunks(query, token, batch_size, score, floor),
    do: scan(query, token, batch_size, score, floor, 0, %{}, [])

  defp scan(query, token, batch_size, score, floor, after_id, allowed, best) do
    rows =
      from([e, _c, _p] in query,
        where: e.id > ^after_id,
        order_by: [asc: e.id],
        limit: ^batch_size
      )
      |> Repo.all()

    {readable, allowed} = within_token_scope(rows, token, allowed)

    best =
      readable
      |> Enum.map(score)
      |> Enum.filter(&(&1.score >= floor))
      |> then(&(best ++ &1))
      |> Enum.sort_by(& &1.score, :desc)
      |> Enum.take(@chunk_limit)

    if length(rows) < batch_size,
      do: best,
      else: scan(query, token, batch_size, score, floor, List.last(rows).id, allowed, best)
  end

  # The query for every chunk the reader may see, as bare rows — the vectors
  # are scored in Elixir, so the query's job is only to keep unreadable and
  # unwanted rows out of memory. `scan/8` reads it a batch at a time.
  defp candidates(user, opts) do
    %{board_ids: board_ids, card_ids: card_ids} = Slipdock.Access.readable_scope(user)
    # A page shared on its own reaches its reader without its board, the way
    # a shared card does.
    page_ids = user |> Slipdock.Access.shared_pages() |> Enum.map(& &1.id)

    from(e in Embedding,
      left_join: c in Card,
      on: c.id == e.card_id,
      left_join: p in Page,
      on: p.id == e.page_id,
      where: e.board_id in ^board_ids or e.card_id in ^card_ids or e.page_id in ^page_ids,
      select: %{
        id: e.id,
        kind: e.kind,
        source_id: e.source_id,
        section: e.section,
        card_id: e.card_id,
        page_id: e.page_id,
        board_id: e.board_id,
        body: e.body,
        vector: e.vector,
        score: 0.0
      }
    )
    |> filter_archived(opts[:archived])
    |> filter_board(opts[:board_id])
    |> filter_kind(opts[:kind])
  end

  # The user's reach is the outer bound; a token confined to some boards only
  # ever narrows it. Checked once per board rather than per chunk, and the
  # answers carried from batch to batch so no board is asked about twice.
  defp within_token_scope(rows, nil, allowed), do: {rows, allowed}

  defp within_token_scope(rows, token, allowed) do
    allowed =
      rows
      |> Enum.map(& &1.board_id)
      |> Enum.uniq()
      |> Enum.reject(&Map.has_key?(allowed, &1))
      |> Enum.reduce(allowed, fn board_id, acc ->
        {level, _} = Slipdock.Access.narrow(:read, token, board_id)
        Map.put(acc, board_id, Slipdock.Access.can_read?(level))
      end)

    {Enum.filter(rows, &Map.fetch!(allowed, &1.board_id)), allowed}
  end

  defp filter_archived(query, true), do: query

  defp filter_archived(query, _),
    do: from([e, c, p] in query, where: is_nil(c.archived_at) and is_nil(p.archived_at))

  defp filter_board(query, nil), do: query

  defp filter_board(query, board_id) do
    ids =
      from(b in Board, where: b.id == ^board_id or b.root_id == ^board_id, select: b.id)
      |> Repo.all()

    from([e, _c, _p] in query, where: e.board_id in ^ids)
  end

  defp filter_kind(query, kind) when kind in [:card, "card"],
    do: from([e, _c, _p] in query, where: is_nil(e.page_id))

  defp filter_kind(query, kind) when kind in [:page, "page"],
    do: from([e, _c, _p] in query, where: not is_nil(e.page_id))

  defp filter_kind(query, _), do: query

  # Chunks belong to a card or to a page; each is one result, scored by its
  # best chunk and carrying every chunk that matched so the reader sees *why*
  # it came back. A page rolls up to the page rather than the section, with
  # the sections as snippets — so a result links to `…/wiki/runbook#rollback`.
  defp roll_up([], _user), do: []

  defp roll_up(chunks, user) do
    {page_chunks, card_chunks} = Enum.split_with(chunks, &Embedding.page?(&1.kind))

    (card_results(card_chunks) ++ page_results(page_chunks, user))
    |> Enum.sort_by(& &1.score, :desc)
  end

  defp card_results(chunks) do
    by_card = Enum.group_by(chunks, & &1.card_id)
    cards = cards_by_id(Map.keys(by_card))

    Enum.flat_map(by_card, fn {card_id, matches} ->
      case cards[card_id] do
        nil -> []
        card -> [result("card", card, card, nil, matches)]
      end
    end)
  end

  defp page_results(chunks, user) do
    by_page = Enum.group_by(chunks, & &1.page_id)
    pages = pages_by_id(Map.keys(by_page))

    Enum.flat_map(by_page, fn {page_id, matches} ->
      case pages[page_id] do
        nil ->
          []

        page ->
          # Drafts are not indexed, but a page can become one after it was;
          # the reader's own permission is checked here rather than trusted
          # to the index.
          if Slipdock.Wiki.visible?(page, Slipdock.Access.page_permission(user, page)),
            do: [result("page", page, nil, page, matches)],
            else: []
      end
    end)
  end

  defp result(kind, subject, card, page, matches) do
    matches = Enum.sort_by(matches, & &1.score, :desc)

    %{
      kind: kind,
      subject: subject,
      card: card,
      page: page,
      score: hd(matches).score,
      matches:
        Enum.map(
          matches,
          &%{
            kind: &1.kind,
            source_id: &1.source_id,
            section: Map.get(&1, :section) || "",
            body: &1.body,
            score: &1.score
          }
        )
    }
  end

  defp cards_by_id(ids) do
    from(c in Card, where: c.id in ^ids, preload: [:board, :column, :tags, :assignee, :assignees])
    |> Repo.all()
    |> Map.new(&{&1.id, &1})
  end

  defp pages_by_id([]), do: %{}

  defp pages_by_id(ids) do
    from(p in Page, where: p.id in ^ids, preload: [:board])
    |> Repo.all()
    |> Map.new(&{&1.id, &1})
  end

  # Words worth matching literally: anything three characters or longer that
  # isn't a stop word. Short tokens match far too much to be evidence.
  @stop_words ~w(the and for are but not you all any can has had was were with
                 that this from what when where which who why how does did about
                 into over under than then them they there their been being have)
  defp keywords(query) do
    query
    |> String.downcase()
    |> String.split(~r/[^\p{L}\p{N}_-]+/u, trim: true)
    |> Enum.filter(&(String.length(&1) >= 3 and &1 not in @stop_words))
    |> Enum.uniq()
  end

  defp keyword_hit?(_body, []), do: false

  defp keyword_hit?(body, keywords) do
    down = String.downcase(body)
    Enum.any?(keywords, &String.contains?(down, &1))
  end

  ## Indexing -----------------------------------------------------------------

  @doc """
  The query that loads a card with everything `Slipdock.Search.Chunk` needs.
  """
  def card_query do
    # A stand-in is the same title as the card it stands for, so indexing it
    # would only find that card twice.
    from(c in Card,
      where: is_nil(c.stand_in_for_id),
      preload: [
        :board,
        :column,
        :tags,
        :assignee,
        :assignees,
        :checklist_items,
        :comments,
        :status_updates
      ]
    )
  end

  @doc "Loads cards by id, with everything `Slipdock.Search.Chunk` needs."
  @spec load_cards([integer]) :: [Card.t()]
  def load_cards([]), do: []
  def load_cards(ids), do: Repo.all(from(c in card_query(), where: c.id in ^ids))

  @doc """
  Re-embeds one card and everything written on it, synchronously.

  Chunks whose text hasn't changed keep their existing vector; chunks whose
  source has gone (a deleted comment) are removed. Returns
  `{:ok, %{embedded: n, unchanged: n, removed: n}}`.
  """
  @spec index_card(Card.t() | integer) :: {:ok, map} | {:error, String.t()}
  def index_card(%Card{id: id}), do: index_card(id)

  def index_card(card_id) when is_integer(card_id) do
    case Repo.get(card_query(), card_id) do
      nil -> {:ok, forget_card(card_id)}
      card -> index_cards([card])
    end
  end

  @doc """
  Re-embeds a list of loaded cards in one pass, batching every changed chunk
  across all of them into as few embedding calls as possible.
  """
  @spec index_cards([Card.t()]) :: {:ok, map} | {:error, String.t()}
  def index_cards([]), do: {:ok, %{embedded: 0, unchanged: 0, removed: 0}}

  def index_cards(cards) do
    chunks = Enum.flat_map(cards, &Chunk.for_card/1)
    existing = existing_for(Enum.map(cards, & &1.id))
    embed_chunks(chunks, existing, fn -> remove_orphans(Enum.map(cards, & &1.id), chunks) end)
  end

  ## Pages --------------------------------------------------------------------

  @doc "The query that loads a page with everything `Slipdock.Search.Chunk` needs."
  def page_query, do: from(p in Page, preload: [:board])

  @doc "Loads pages by id, with everything `Slipdock.Search.Chunk` needs."
  def load_pages([]), do: []
  def load_pages(ids), do: Repo.all(from(p in page_query(), where: p.id in ^ids))

  @doc """
  Re-embeds one wiki page, synchronously.

  Chunking by heading is what makes this cheap: editing one section of a long
  runbook re-embeds that section and leaves the rest alone.
  """
  @spec index_page(Page.t() | integer) :: {:ok, map} | {:error, String.t()}
  def index_page(%Page{id: id}), do: index_page(id)

  def index_page(page_id) when is_integer(page_id) do
    case Repo.get(page_query(), page_id) do
      nil -> {:ok, forget_page(page_id)}
      page -> index_pages([page])
    end
  end

  @doc "Re-embeds a list of loaded pages in one pass."
  @spec index_pages([Page.t()]) :: {:ok, map} | {:error, String.t()}
  def index_pages([]), do: {:ok, %{embedded: 0, unchanged: 0, removed: 0}}

  def index_pages(pages) do
    chunks = Enum.flat_map(pages, &Chunk.for_page/1)
    existing = existing_for_pages(Enum.map(pages, & &1.id))

    embed_chunks(chunks, existing, fn -> remove_page_orphans(Enum.map(pages, & &1.id), chunks) end)
  end

  @doc "Drops everything indexed for a page (it was deleted, archived or drafted)."
  @spec forget_page(integer) :: map
  def forget_page(page_id) when is_integer(page_id) do
    {n, _} = Repo.delete_all(from(e in Embedding, where: e.page_id == ^page_id))
    %{embedded: 0, unchanged: 0, removed: n}
  end

  @doc "Every page id, oldest first — what `mix slipdock.reindex` walks."
  def all_page_ids, do: Repo.all(from(p in Page, order_by: [asc: p.id], select: p.id))

  ## Embedding ----------------------------------------------------------------

  # The half of indexing that does not care what it is indexing: skip what has
  # not changed, embed the rest in batches, replace, then sweep up chunks whose
  # source has gone.
  defp embed_chunks(chunks, existing, sweep) do
    model = Embeddings.model()
    dimensions = Embeddings.dimensions()

    {fresh, stale} =
      Enum.split_with(chunks, fn chunk ->
        case existing[{chunk.kind, chunk.source_id, chunk.section}] do
          %{content_hash: hash, model: ^model} = row ->
            hash == Chunk.hash(chunk.body) and
              (is_nil(dimensions) or row.dimensions == dimensions)

          _ ->
            false
        end
      end)

    with {:ok, vectors} <- Embeddings.embed_all(Enum.map(stale, & &1.body)) do
      now = DateTime.utc_now(:second)

      rows =
        Enum.zip(stale, vectors)
        |> Enum.map(fn {chunk, vector} ->
          packed = Vector.pack(vector)

          %{
            kind: chunk.kind,
            source_id: chunk.source_id,
            section: chunk.section,
            card_id: chunk.card_id,
            page_id: chunk.page_id,
            board_id: chunk.board_id,
            body: chunk.body,
            content_hash: Chunk.hash(chunk.body),
            model: model,
            dimensions: Vector.size(packed),
            vector: packed,
            inserted_at: now,
            updated_at: now
          }
        end)

      # Every field of every row counts against one statement's parameter
      # limit (65535 on Postgres), so the insert goes in its own batches.
      # These are well inside it: vectors are the bulky part of a row, and
      # they are bytea, not thousands of parameters.
      rows
      |> Enum.chunk_every(50)
      |> Enum.each(
        &Repo.insert_all(Embedding, &1,
          on_conflict:
            {:replace,
             [
               :card_id,
               :page_id,
               :board_id,
               :body,
               :content_hash,
               :model,
               :dimensions,
               :vector,
               :updated_at
             ]},
          conflict_target: [:kind, :source_id, :section]
        )
      )

      removed = sweep.()

      {:ok, %{embedded: length(rows), unchanged: length(fresh), removed: removed}}
    end
  end

  @doc """
  Corrects the board recorded against a card's chunks, and those of every
  card beneath it, after the card has been moved to another board.

  This runs inline rather than through the queue because `board_id` is what
  permission filtering reads: until it is right, a moved card is searchable
  by the people who could see where it used to live and invisible to the
  people who can see where it is now. The text those chunks hold still names
  the old board, which is a cosmetic staleness the queued re-embed fixes a
  moment later.
  """
  @spec relocate_card(Card.t() | integer) :: :ok
  def relocate_card(%Card{id: id}), do: relocate_card(id)

  def relocate_card(card_id) when is_integer(card_id) do
    from(c in Card, where: c.id in ^subtree_card_ids(card_id), select: {c.id, c.board_id})
    |> Repo.all()
    |> Enum.each(fn {id, board_id} ->
      from(e in Embedding, where: e.card_id == ^id and e.board_id != ^board_id)
      |> Repo.update_all(set: [board_id: board_id])
    end)

    :ok
  end

  defp do_descendant_board_ids([]), do: []

  defp do_descendant_board_ids(card_ids) do
    board_ids = from(b in Board, where: b.parent_card_id in ^card_ids, select: b.id) |> Repo.all()

    case board_ids do
      [] ->
        []

      ids ->
        next = from(c in Card, where: c.board_id in ^ids, select: c.id) |> Repo.all()
        ids ++ do_descendant_board_ids(next)
    end
  end

  @doc """
  Every card in the subtree beneath a card, itself included — what has to be
  re-embedded when the card moves boards.
  """
  @spec subtree_card_ids(integer) :: [integer]
  def subtree_card_ids(card_id) when is_integer(card_id) do
    case do_descendant_board_ids([card_id]) do
      [] -> [card_id]
      ids -> [card_id | Repo.all(from(c in Card, where: c.board_id in ^ids, select: c.id))]
    end
  end

  @doc "Drops everything indexed for a card (it was deleted, or its board was)."
  @spec forget_card(integer) :: map
  def forget_card(card_id) when is_integer(card_id) do
    {n, _} = Repo.delete_all(from(e in Embedding, where: e.card_id == ^card_id))
    %{embedded: 0, unchanged: 0, removed: n}
  end

  @doc """
  Every card id, oldest first — what `mix slipdock.reindex` walks.

  There is no cheaper "what changed" query, and there does not need to be:
  a chunk whose text and model are unchanged is skipped without an API
  call, so walking everything costs a few local hashes and repairs any
  drift — a comment whose embedding failed, a card half-indexed when the
  app stopped — as a side effect of running at all.
  """
  def all_card_ids, do: Repo.all(from(c in Card, order_by: [asc: c.id], select: c.id))

  @doc "Empties the index. The next reindex rebuilds it from scratch."
  def clear do
    {n, _} = Repo.delete_all(Embedding)
    n
  end

  defp existing_for(card_ids), do: existing_where(dynamic([e], e.card_id in ^card_ids))

  defp existing_for_pages(page_ids), do: existing_where(dynamic([e], e.page_id in ^page_ids))

  defp existing_where(clause) do
    from(e in Embedding,
      where: ^clause,
      select: %{
        kind: e.kind,
        source_id: e.source_id,
        section: e.section,
        content_hash: e.content_hash,
        model: e.model,
        dimensions: e.dimensions
      }
    )
    |> Repo.all()
    |> Map.new(&{{&1.kind, &1.source_id, &1.section}, &1})
  end

  # Chunks for sources that no longer exist — a deleted comment, a status
  # update that was withdrawn — would otherwise linger and keep matching.
  defp remove_orphans(card_ids, chunks),
    do: do_remove_orphans(dynamic([e], e.card_id in ^card_ids), chunks)

  defp remove_page_orphans(page_ids, chunks),
    do: do_remove_orphans(dynamic([e], e.page_id in ^page_ids), chunks)

  defp do_remove_orphans(clause, chunks) do
    keep = MapSet.new(chunks, &{&1.kind, &1.source_id, &1.section})

    ids =
      from(e in Embedding, where: ^clause, select: {e.id, e.kind, e.source_id, e.section})
      |> Repo.all()
      |> Enum.reject(fn {_id, kind, source_id, section} ->
        MapSet.member?(keep, {kind, source_id, section})
      end)
      |> Enum.map(&elem(&1, 0))

    case ids do
      [] -> 0
      ids -> Repo.delete_all(from(e in Embedding, where: e.id in ^ids)) |> elem(0)
    end
  end
end
