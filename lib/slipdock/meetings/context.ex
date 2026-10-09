defmodule Slipdock.Meetings.Context do
  @moduledoc """
  What the board already knows that bears on a meeting (pipeline step 5):
  the cards and pages it mentions, the ones it is about without naming, and
  the decisions already written down.

  ## What counts as a mention

    * **By id** (strongest): a card's number (`#412`), a page's code
      (`W-31`), or a board's code and a card's number (`PL-14`: card 14,
      when it is on the board coded PL or a board beneath it).
    * **By name**: a card's or a page's title said aloud, word for word
      (case and punctuation aside). Titles too short to mean anything — a
      single short word — are not matched.
    * **By similarity** (weakest): what semantic search
      (`Slipdock.Search`) finds for each stretch of the transcript, when
      this server has it set up.

  ## Whose eyes (G12)

  Everything is looked for as the capture's owner, and only on the boards in
  its scope: the capture's board and the boards beneath it, its wiki, and
  its parent board when the capture asked for it. A card the owner cannot
  open is never returned, however well it matches.

  Each candidate carries its version (`Slipdock.Meetings.Version`) as read
  now, for the stale check at commit (G7).
  """
  import Ecto.Query, warn: false

  alias Slipdock.{Access, Repo, Search}
  alias Slipdock.Accounts.User
  alias Slipdock.AI.Embeddings
  alias Slipdock.Boards.{Board, Card}
  alias Slipdock.Meetings.{Capture, Utterance, Version}
  alias Slipdock.Wiki.Page

  @strength_rank %{"id" => 3, "name" => 2, "similarity" => 1}
  @max_candidates 60
  @chunk_chars 1_200
  @max_chunks 24
  @per_chunk 6

  @doc """
  Gathers the context for a capture. Returns the map stored as
  `capture.context`: `"candidates"`, `"decisions"` and `"stats"` (how many
  candidates, how many searches it took and how long).
  """
  @spec gather(Capture.t()) :: map()
  def gather(%Capture{} = capture) do
    started = System.monotonic_time(:millisecond)
    owner = Repo.get!(User, capture.owner_id)
    board = Repo.get!(Board, capture.board_id)
    scope = scope_board_ids(owner, board, capture.context_scope || %{})

    lines =
      Repo.all(
        from(u in Utterance, where: u.capture_id == ^capture.id, order_by: [asc: u.position])
      )

    cards = scope_cards(scope)
    pages = scope_pages(scope)

    explicit = explicit(lines, cards, pages, scope)
    named = named(lines, cards, pages)
    {similar, searches} = similar(owner, lines, scope)

    candidates =
      (explicit ++ named ++ similar)
      |> merge()
      |> Enum.filter(&readable?(owner, &1))
      |> Enum.sort_by(&{-@strength_rank[&1.strength], -(&1.score || 0)})
      |> Enum.take(@max_candidates)
      |> Enum.map(&describe/1)

    decisions = decisions(pages)

    %{
      "candidates" => candidates,
      "decisions" => decisions,
      "scope" => scope,
      "stats" => %{
        "candidates" => length(candidates),
        "by_id" => Enum.count(candidates, &(&1["strength"] == "id")),
        "by_name" => Enum.count(candidates, &(&1["strength"] == "name")),
        "by_similarity" => Enum.count(candidates, &(&1["strength"] == "similarity")),
        "decision_pages" => length(decisions),
        "semantic" => searches != :unavailable,
        "searches" => if(searches == :unavailable, do: 0, else: searches),
        "ms" => System.monotonic_time(:millisecond) - started
      }
    }
  end

  ## Scope --------------------------------------------------------------------

  @doc """
  The boards a capture on `board` reads, as `owner` may: the board, the
  boards beneath it, and (with `"parent" => true`) the board its parent card
  is on. Only boards the owner can read.
  """
  def scope_board_ids(%User{} = owner, %Board{} = board, scope) do
    readable = MapSet.new(Access.readable_scope(owner).board_ids)

    parent =
      if scope["parent"] && board.parent_card_id do
        case Repo.get(Card, board.parent_card_id) do
          %Card{board_id: id} -> [id]
          nil -> []
        end
      else
        []
      end

    ([board.id | beneath(board.id)] ++ parent)
    |> Enum.uniq()
    |> Enum.filter(&MapSet.member?(readable, &1))
  end

  # Every board in the sub-board trees under this one, a level at a time.
  defp beneath(board_id) do
    case Repo.all(
           from(b in Board,
             join: c in Card,
             on: c.id == b.parent_card_id,
             where: c.board_id == ^board_id,
             select: b.id
           )
         ) do
      [] -> []
      ids -> ids ++ Enum.flat_map(ids, &beneath/1)
    end
  end

  defp scope_cards([]), do: []

  defp scope_cards(board_ids) do
    Repo.all(
      from(c in Card,
        where: c.board_id in ^board_ids and is_nil(c.archived_at) and is_nil(c.stand_in_for_id),
        preload: [:board, :column, :assignees]
      )
    )
  end

  defp scope_pages([]), do: []

  defp scope_pages(board_ids) do
    Repo.all(
      from(p in Page,
        where: p.board_id in ^board_ids and is_nil(p.archived_at) and p.template == false,
        preload: [:board]
      )
    )
  end

  ## By id --------------------------------------------------------------------

  defp explicit(lines, cards, pages, scope) do
    cards_by_id = Map.new(cards, &{&1.id, &1})
    pages_by_code = Map.new(pages, &{String.upcase(&1.code || ""), &1})
    codes = board_codes(scope)

    Enum.flat_map(lines, fn line ->
      hashes =
        for [_, n] <- Regex.scan(~r/(?<![\w&])#(\d{1,9})\b/, line.text),
            card = cards_by_id[String.to_integer(n)],
            do: hit(:card, card, "id", line)

      page_codes =
        for [code] <- Regex.scan(~r/(?<![\w-])[Ww]-\d+(?![\w-])/, line.text),
            page = pages_by_code[String.upcase(code)],
            do: hit(:page, page, "id", line)

      qualified =
        for [_, code, n] <-
              Regex.scan(~r/(?<![\w-])([A-Za-z][A-Za-z0-9]{0,15})-(\d{1,9})(?![\w-])/, line.text),
            String.upcase(code) != "W",
            board_ids = Map.get(codes, String.upcase(code)),
            card = cards_by_id[String.to_integer(n)],
            card.board_id in board_ids,
            do: hit(:card, card, "id", line)

      hashes ++ page_codes ++ qualified
    end)
  end

  # Each board code in scope, with the boards it covers (itself and beneath).
  defp board_codes(scope) do
    boards = Repo.all(from(b in Board, where: b.id in ^scope and not is_nil(b.code)))

    Map.new(boards, fn b -> {String.upcase(b.code), [b.id | beneath(b.id)]} end)
  end

  ## By name ------------------------------------------------------------------

  defp named(lines, cards, pages) do
    spoken = Enum.map(lines, &{&1, normalise(&1.text)})

    titled =
      Enum.map(cards, &{:card, &1, normalise(&1.title)}) ++
        Enum.map(pages, &{:page, &1, normalise(&1.title)})

    for {kind, thing, title} <- titled,
        meaningful_title?(title),
        {line, text} <- spoken,
        String.contains?(" " <> text <> " ", " " <> title <> " "),
        do: hit(kind, thing, "name", line)
  end

  # "Bug" or "Misc" would match half of any meeting.
  defp meaningful_title?(title),
    do:
      String.length(title) >= 6 and
        (length(String.split(title)) >= 2 or String.length(title) >= 10)

  @doc false
  def normalise(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^\p{L}\p{N}]+/u, " ")
    |> String.trim()
  end

  ## By similarity ------------------------------------------------------------

  defp similar(owner, lines, scope) do
    if Embeddings.configured?() and lines != [] do
      chunks = chunks(lines)

      hits =
        Enum.flat_map(chunks, fn chunk ->
          text = Enum.map_join(chunk, " ", & &1.text)

          case Search.search(owner, text, limit: @per_chunk * 3) do
            {:ok, results} ->
              results
              |> Enum.filter(&(board_of(&1) in scope))
              |> Enum.take(@per_chunk)
              |> Enum.flat_map(fn result ->
                Enum.map(chunk, fn line -> similarity_hit(result, line) end)
              end)

            {:error, _} ->
              []
          end
        end)

      {hits, length(chunks)}
    else
      {[], :unavailable}
    end
  end

  defp board_of(%{kind: "card", card: card}), do: card.board_id
  defp board_of(%{kind: "page", page: page}), do: page.board_id

  defp similarity_hit(%{kind: "card", card: card, score: score}, line),
    do: %{hit(:card, Repo.preload(card, [:assignees]), "similarity", line) | score: score}

  defp similarity_hit(%{kind: "page", page: page, score: score}, line),
    do: %{hit(:page, page, "similarity", line) | score: score}

  # Consecutive lines grouped into stretches of about #{@chunk_chars}
  # characters; a long meeting is sampled evenly rather than cut off.
  defp chunks(lines) do
    chunks =
      lines
      |> Enum.chunk_while(
        [],
        fn line, acc ->
          size = Enum.reduce(acc, 0, &(String.length(&1.text) + &2))

          if size + String.length(line.text) > @chunk_chars and acc != [],
            do: {:cont, Enum.reverse(acc), [line]},
            else: {:cont, [line | acc]}
        end,
        fn
          [] -> {:cont, []}
          acc -> {:cont, Enum.reverse(acc), []}
        end
      )

    if length(chunks) <= @max_chunks do
      chunks
    else
      step = length(chunks) / @max_chunks
      for i <- 0..(@max_chunks - 1), do: Enum.at(chunks, trunc(i * step))
    end
  end

  ## Merging ------------------------------------------------------------------

  defp hit(kind, thing, strength, line),
    do: %{kind: kind, thing: thing, strength: strength, lines: [line.line_id], score: nil}

  # One candidate per card or page: its strongest reason, every line that
  # pointed at it, its best similarity score.
  defp merge(hits) do
    hits
    |> Enum.group_by(&{&1.kind, &1.thing.id})
    |> Enum.map(fn {_, [first | _] = group} ->
      strongest = Enum.max_by(group, &@strength_rank[&1.strength])

      %{
        first
        | strength: strongest.strength,
          lines: group |> Enum.flat_map(& &1.lines) |> Enum.uniq(),
          score:
            group |> Enum.map(& &1.score) |> Enum.reject(&is_nil/1) |> Enum.max(fn -> nil end)
      }
    end)
  end

  defp readable?(owner, %{kind: :card, thing: card}),
    do: Access.can_read?(Access.card_permission(owner, card))

  defp readable?(owner, %{kind: :page, thing: page}),
    do: Access.can_read?(Access.page_permission(owner, page))

  defp describe(%{kind: :card, thing: card} = c) do
    card = Repo.preload(card, [:board, :column, :assignees])

    %{
      "type" => "card",
      "id" => card.id,
      "ref" => "##{card.id}",
      "title" => card.title,
      "summary" => summary(card.description),
      "board_id" => card.board_id,
      "board" => card.board && card.board.name,
      "list" => card.column && card.column.name,
      "done" => card.completed,
      "assignees" => Enum.map(card.assignees, &(&1.name || &1.email)),
      "due" => card.due_date && Date.to_iso8601(card.due_date),
      "version" => Version.of(card),
      "strength" => c.strength,
      "score" => c.score && Float.round(c.score, 3),
      "lines" => c.lines
    }
  end

  defp describe(%{kind: :page, thing: page} = c) do
    page = Repo.preload(page, [:board])

    %{
      "type" => "page",
      "id" => page.id,
      "ref" => page.code,
      "title" => page.title,
      "summary" => summary(page.summary || page.body),
      "board_id" => page.board_id,
      "board" => page.board && page.board.name,
      "version" => Version.of(page),
      "strength" => c.strength,
      "score" => c.score && Float.round(c.score, 3),
      "lines" => c.lines
    }
  end

  defp summary(nil), do: nil

  defp summary(text) do
    text = String.replace(text, ~r/\s+/, " ") |> String.trim()
    if String.length(text) > 300, do: String.slice(text, 0, 297) <> "…", else: text
  end

  ## Decisions ----------------------------------------------------------------

  @doc """
  The decisions already written down on the boards in scope: every page whose
  title starts "Decisions", and each entry on it — a list item or a `###`
  heading — with whether it has been struck through (superseded).
  """
  def decisions(pages) do
    pages
    |> Enum.filter(&Regex.match?(~r/^decisions\b/i, &1.title))
    |> Enum.map(fn page ->
      %{
        "page_id" => page.id,
        "board_id" => page.board_id,
        "ref" => page.code,
        "title" => page.title,
        "version" => Version.of(page),
        "entries" => entries(page.body || "")
      }
    end)
  end

  defp entries(body) do
    body
    |> String.split("\n")
    |> Enum.flat_map(fn line ->
      case Regex.run(~r/^\s*(?:[-*]\s+|###\s+)(.+)$/, line) do
        [_, text] ->
          struck = Regex.match?(~r/^~~.*~~/, String.trim(text))
          [%{"text" => text |> String.replace("~~", "") |> String.trim(), "superseded" => struck}]

        nil ->
          []
      end
    end)
  end
end
