defmodule SlipdockWeb.MCP.Tools.Activity do
  @moduledoc """
  A board's activity log, as `GET /api/boards/:board/activity` gives it; or,
  with `view: "ledger"`, its ledger (#1948): what shipped since a time, as
  `GET /api/boards/:board/ledger?since=` gives it (`Slipdock.Ledger`).

  The ledger is a view of this tool rather than a tool of its own: it is the
  board's history, read the same way, and a new tool would add to every
  count the docs quote (SPEC-3) and to the guide's size (SPEC-4).
  """
  @behaviour SlipdockWeb.MCP.Tool

  alias Slipdock.{Boards, Ledger}
  alias SlipdockWeb.API.Authorize
  alias SlipdockWeb.API.JSON, as: V
  alias SlipdockWeb.API.LedgerJSON
  alias SlipdockWeb.MCP.Args

  @max 200

  @impl true
  def name, do: "activity"

  @impl true
  def title, do: "Board activity"

  @impl true
  def description,
    do:
      "A board's activity log, newest first; card = only that card's. " <>
        "view=ledger: what shipped since (days, a date or a time; 07:00 yesterday by default), " <>
        "with who accepted it and its evidence."

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        board: %{type: "string", description: "Board id, code or name."},
        card: %{type: "integer", description: "Only the entries about this card."},
        limit: %{type: "integer", description: "At most this many (default 30, max #{@max})."},
        view: %{
          type: "string",
          enum: ["log", "ledger"],
          description: "log (default), or ledger: what shipped on the board tree since `since`."
        },
        since: %{
          type: "string",
          description:
            "For view=ledger: days, a date or an ISO time (default 07:00 yesterday, board time)."
        }
      },
      required: ["board"],
      additionalProperties: false
    }
  end

  @impl true
  def read_only?, do: true

  @impl true
  def call(args, context) do
    case Args.optional(args, "view") do
      {:ok, view} when view in [nil, "log"] -> log(args, context)
      {:ok, "ledger"} -> ledger(args, context)
      {:ok, _other} -> {:error, "view is log or ledger"}
      error -> error
    end
  end

  # The ledger (#1948): what shipped since `since`, as REST gives it.
  defp ledger(args, context) do
    auth = Args.auth(context)

    with {:ok, ref} <- Args.required(args, "board"),
         {:ok, since} <- Args.optional(args, "since"),
         {:ok, board} <- Args.refusal(Authorize.fetch_board(auth, ref, :read)),
         {:ok, ledger} <- Args.refusal(Ledger.since(board, since: since)) do
      {:ok, LedgerJSON.ledger(board, ledger)}
    end
  end

  defp log(args, context) do
    auth = Args.auth(context)

    with {:ok, ref} <- Args.required(args, "board"),
         {:ok, card_id} <- card(args),
         {:ok, limit} <- Args.limit(args, "limit", 30, @max),
         {:ok, board} <- Args.refusal(Authorize.fetch_board(auth, ref, :read)) do
      {:ok,
       %{
         board: %{id: board.id, code: board.code, name: board.name},
         activity: board.id |> Boards.list_activities(limit, card_id) |> Enum.map(&V.activity/1)
       }}
    end
  end

  defp card(%{"card" => _} = args), do: Args.id(args, "card")
  defp card(_args), do: {:ok, nil}
end
