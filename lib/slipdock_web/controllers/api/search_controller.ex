defmodule SlipdockWeb.API.SearchController do
  @moduledoc """
  Semantic search and the assistant that uses it, for agents and the CLI.

  `GET /api/search?q=…` is the same search the `/search` page runs: every
  card, comment and status update the token's owner can read, matched by
  meaning. `POST /api/ask` is the same assistant as `/ask` — it searches on
  its own and answers in Markdown, naming the cards it read.

  Both are scoped to the token's owner by `Slipdock.Search`, which takes the
  user rather than a list of boards, so there is no way to widen the scope
  from out here.
  """
  use SlipdockWeb, :controller

  alias Slipdock.AI.Researcher
  alias Slipdock.SavedQueries
  alias Slipdock.Search

  action_fallback SlipdockWeb.API.FallbackController

  @max_limit 50

  @doc "Searches everything the caller can read."
  def search(conn, params) do
    user = conn.assigns.current_user

    with {:ok, query} <- required(params["q"] || params["query"], "q"),
         {:ok, limit} <- limit(params["limit"]),
         {:ok, board_id} <- board_id(user, params["board"], conn.assigns[:api_token]),
         {:ok, kind} <- kind(params["kind"]),
         {:ok, results} <-
           Search.search(user, query,
             limit: limit,
             archived: truthy(params["archived"]),
             board_id: board_id,
             kind: kind
           ) do
      json(conn, %{
        query: query,
        count: length(results),
        results: Enum.map(results, &result/1)
      })
    else
      {:error, message} when is_binary(message) -> {:error, :bad_request, message}
      other -> other
    end
  end

  @doc "Asks the assistant a question it answers by searching."
  def ask(conn, params) do
    with {:ok, question} <- required(params["q"] || params["question"], "q"),
         {:ok, answer} <- Researcher.ask(conn.assigns.current_user, history(params), question) do
      json(conn, %{
        question: question,
        answer: answer.reply,
        searches: answer.searches,
        sources: Enum.map(answer.sources, &source/1)
      })
    else
      {:error, message} when is_binary(message) -> {:error, :bad_request, message}
      other -> other
    end
  end

  @doc "What is indexed right now — useful for telling a stale index from an empty one."
  def status(conn, _params) do
    stats = Search.stats()

    json(conn, %{
      available: Search.available?(),
      chunks: stats.chunks,
      cards: stats.cards,
      pages: stats.pages,
      queued: stats.pending,
      model: stats.model,
      dimensions: stats.dimensions
    })
  end

  @doc "The caller's own saved queries, newest first."
  def saved(conn, params) do
    with {:ok, mode} <- mode(params["mode"]) do
      queries = SavedQueries.list(conn.assigns.current_user, mode)
      json(conn, %{saved: Enum.map(queries, &saved_query/1)})
    end
  end

  @doc "Saves a query. Saving the same thing twice is saving it once."
  def save(conn, params) do
    with {:ok, text} <- required(params["q"] || params["text"], "q"),
         {:ok, mode} <- required_mode(params["mode"]),
         {:ok, _} <- SavedQueries.save(conn.assigns.current_user, mode, text) do
      saved(conn, %{"mode" => mode})
    else
      {:error, :bad_mode} -> {:error, :bad_request, mode_error()}
      other -> other
    end
  end

  @doc "Removes a saved query, by id or by its exact text. Idempotent."
  def unsave(conn, %{"id" => id} = params) do
    case Integer.parse(to_string(id)) do
      {id, ""} ->
        :ok = SavedQueries.delete(conn.assigns.current_user, id)
        saved(conn, Map.take(params, ["mode"]))

      _ ->
        {:error, :bad_request, "id must be a number"}
    end
  end

  def unsave(conn, params) do
    with {:ok, text} <- required(params["q"] || params["text"], "q"),
         {:ok, mode} <- required_mode(params["mode"]) do
      :ok = SavedQueries.remove(conn.assigns.current_user, mode, text)
      saved(conn, %{"mode" => mode})
    end
  end

  ## Shaping ------------------------------------------------------------------

  defp saved_query(q),
    do: %{id: q.id, mode: q.mode, text: q.text, saved_at: q.inserted_at}

  # A result is a card or a wiki page. `card` is kept where it always was so
  # nothing that reads these breaks; `kind` and `subject` say which it is.
  defp result(%{kind: kind, score: score, matches: matches} = result) do
    %{
      kind: kind,
      subject: subject(result),
      card: result.card && card_result(result.card),
      page: result.page && page_result(result.page),
      score: Float.round(score, 4),
      matches:
        Enum.map(matches, fn m ->
          %{
            kind: m.kind,
            source_id: m.source_id,
            section: nonblank(m[:section]),
            score: Float.round(m.score, 4),
            text: m.body
          }
        end)
    }
  end

  defp subject(%{kind: "card", card: card}), do: %{title: card.title, url: card_url(card)}

  defp subject(%{kind: "page", page: page}),
    do: %{title: page.title, url: ~p"/boards/#{page.board_id}/wiki/#{page.slug}"}

  defp card_result(card) do
    %{
      id: card.id,
      title: card.title,
      completed: card.completed,
      priority: card.priority,
      due_date: card.due_date,
      archived: not is_nil(card.archived_at),
      tags: Enum.map(card.tags, & &1.name),
      board: %{id: card.board.id, name: card.board.name, code: card.board.code},
      column: card.column && %{id: card.column.id, name: card.column.name},
      url: card_url(card)
    }
  end

  defp page_result(page) do
    %{
      id: page.id,
      code: page.code,
      title: page.title,
      slug: page.slug,
      summary: page.summary,
      board: %{id: page.board.id, name: page.board.name, code: page.board.code},
      url: ~p"/boards/#{page.board_id}/wiki/#{page.slug}"
    }
  end

  defp card_url(card), do: ~p"/boards/#{card.board_id}/cards/#{card.id}"

  defp nonblank(nil), do: nil
  defp nonblank(""), do: nil
  defp nonblank(text), do: text

  defp kind(nil), do: {:ok, :all}
  defp kind(""), do: {:ok, :all}
  defp kind("all"), do: {:ok, :all}
  defp kind("card"), do: {:ok, :card}
  defp kind("cards"), do: {:ok, :card}
  defp kind("page"), do: {:ok, :page}
  defp kind("pages"), do: {:ok, :page}
  defp kind(other), do: {:error, "kind must be card, page or all (got #{inspect(other)})"}

  # The assistant reads cards and wiki pages, so a source is either.
  defp source(%{page: page, why: why}) do
    %{
      kind: "page",
      id: page.id,
      code: page.code,
      title: page.title,
      board: page.board && page.board.name,
      found_by: why,
      url: ~p"/boards/#{page.board_id}/wiki/#{page.slug}"
    }
  end

  defp source(%{card: card, why: why}) do
    %{
      kind: "card",
      id: card.id,
      title: card.title,
      board: card.board && card.board.name,
      found_by: why,
      url: card_url(card)
    }
  end

  ## Params -------------------------------------------------------------------

  defp required(value, name) do
    case String.trim(to_string(value || "")) do
      "" -> {:error, :bad_request, "#{name} is required"}
      trimmed -> {:ok, trimmed}
    end
  end

  defp limit(nil), do: {:ok, 20}

  defp limit(value) do
    case Integer.parse(to_string(value)) do
      {n, _} when n > 0 -> {:ok, min(n, @max_limit)}
      _ -> {:error, :bad_request, "limit must be a positive number"}
    end
  end

  defp board_id(_user, nil, _token), do: {:ok, nil}
  defp board_id(_user, "", _token), do: {:ok, nil}

  defp board_id(user, reference, token) do
    wanted = reference |> to_string() |> String.trim() |> String.downcase()

    board =
      user
      |> Slipdock.Access.list_boards(archived: :all, token: token)
      |> Enum.find(fn b ->
        String.downcase(b.name) == wanted or String.downcase(b.code || "") == wanted or
          to_string(b.id) == wanted
      end)

    if board,
      do: {:ok, board.id},
      else: {:error, :bad_request, "no board you can see matches #{inspect(reference)}"}
  end

  # A conversation carried over from a previous call, as
  # `[{"role": "user"|"assistant", "content": "…"}, …]`.
  defp history(%{"history" => history}) when is_list(history) do
    for %{"role" => role, "content" => content} <- history,
        role in ["user", "assistant"],
        is_binary(content),
        do: %{role: role, content: content}
  end

  defp history(_), do: []

  # `mode` is optional when listing (both modes come back) and required when
  # writing, since a query has to be saved under one or the other.
  defp mode(nil), do: {:ok, nil}
  defp mode(""), do: {:ok, nil}

  defp mode(value) do
    value = value |> to_string() |> String.trim() |> String.downcase()
    if value in SavedQueries.modes(), do: {:ok, value}, else: {:error, :bad_request, mode_error()}
  end

  defp required_mode(value) do
    case mode(value) do
      {:ok, nil} -> {:error, :bad_request, mode_error()}
      other -> other
    end
  end

  defp mode_error, do: "mode must be one of: " <> Enum.join(SavedQueries.modes(), ", ")

  defp truthy(value), do: Enum.member?(["true", "1", "yes"], to_string(value))
end
