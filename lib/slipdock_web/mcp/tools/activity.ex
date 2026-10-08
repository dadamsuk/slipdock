defmodule SlipdockWeb.MCP.Tools.Activity do
  @moduledoc "A board's activity log, as `GET /api/boards/:board/activity` gives it."
  @behaviour SlipdockWeb.MCP.Tool

  alias Slipdock.Boards
  alias SlipdockWeb.API.Authorize
  alias SlipdockWeb.API.JSON, as: V
  alias SlipdockWeb.MCP.Args

  @max 200

  @impl true
  def name, do: "activity"

  @impl true
  def title, do: "Board activity"

  @impl true
  def description,
    do:
      "A board's activity log, newest first: cards added, moved, completed, commented on. " <>
        "card = only the entries about that card."

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        board: %{type: "string", description: "Board id, code or name."},
        card: %{type: "integer", description: "Only the entries about this card."},
        limit: %{type: "integer", description: "At most this many (default 30, max #{@max})."}
      },
      required: ["board"],
      additionalProperties: false
    }
  end

  @impl true
  def read_only?, do: true

  @impl true
  def call(args, context) do
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
