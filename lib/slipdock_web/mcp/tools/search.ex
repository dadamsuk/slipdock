defmodule SlipdockWeb.MCP.Tools.Search do
  @moduledoc "Semantic search over every card and wiki page the connection can read."
  @behaviour SlipdockWeb.MCP.Tool

  alias Slipdock.Access
  alias SlipdockWeb.MCP.Args

  @max 30

  @impl true
  def name, do: "search"

  @impl true
  def title, do: "Search"

  @impl true
  def description,
    do:
      "Search cards, comments and wiki pages by meaning, across every board you can read " <>
        "or one board. Use it before writing anything new, to find what already exists."

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        q: %{type: "string", description: "What to look for, in words."},
        board: %{type: "string", description: "Only this board (id, code or name)."},
        kind: %{type: "string", enum: ["all", "card", "page"]},
        limit: %{type: "integer", description: "Default 10, max #{@max}."}
      },
      required: ["q"],
      additionalProperties: false
    }
  end

  @impl true
  def read_only?, do: true

  @impl true
  def call(args, %{user: user, token: token} = context) do
    with {:ok, q} <- Args.required(args, "q"),
         {:ok, limit} <- Args.limit(args, "limit", 10, @max),
         {:ok, kind} <- kind(args),
         {:ok, board_id} <- board_id(args, context),
         {:ok, results} <-
           Slipdock.Search.search(user, q, limit: limit, board_id: board_id, kind: kind) do
      results =
        results
        |> Enum.filter(&in_scope?(&1, token))
        |> Enum.map(&result(&1, context.base_url))

      {:ok, %{query: q, count: length(results), results: results}}
    end
  end

  defp kind(args) do
    case args["kind"] do
      k when k in [nil, "", "all"] -> {:ok, :all}
      "card" -> {:ok, :card}
      "page" -> {:ok, :page}
      _ -> {:error, "kind must be card, page or all"}
    end
  end

  defp board_id(args, context) do
    with {:ok, ref} when is_binary(ref) <- Args.optional(args, "board"),
         {:ok, board} <-
           Args.refusal(SlipdockWeb.API.Authorize.fetch_board(Args.auth(context), ref, :read)) do
      {:ok, board.id}
    end
  end

  # `Slipdock.Search` scopes by the user; a token confined to some boards
  # narrows that further, as everywhere else.
  defp in_scope?(result, token) do
    board_id = if result.card, do: result.card.board_id, else: result.page.board_id
    {level, _} = Access.narrow(:read, token, board_id)
    Access.can_read?(level)
  end

  defp result(%{card: card} = r, base) when not is_nil(card) do
    %{
      kind: "card",
      id: card.id,
      title: card.title,
      board: card.board.code,
      column: card.column && card.column.name,
      completed: card.completed,
      score: Float.round(r.score, 3),
      excerpt: excerpt(r),
      url: base <> "/boards/#{card.board_id}/cards/#{card.id}"
    }
  end

  defp result(%{page: page} = r, base) do
    %{
      kind: "page",
      code: page.code,
      title: page.title,
      board: page.board.code,
      summary: page.summary,
      score: Float.round(r.score, 3),
      excerpt: excerpt(r),
      url: base <> "/boards/#{page.board_id}/wiki/#{page.slug}"
    }
  end

  defp excerpt(%{matches: [m | _]}), do: String.slice(m.body || "", 0, 300)
  defp excerpt(_), do: nil
end
