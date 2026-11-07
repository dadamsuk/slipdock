defmodule SlipdockWeb.MCP.Tools.ListBoards do
  @moduledoc "Every board the connection can see, with which list plays which part."
  @behaviour SlipdockWeb.MCP.Tool

  alias Slipdock.{Access, Boards}

  @impl true
  def name, do: "list_boards"

  @impl true
  def title, do: "List boards"

  @impl true
  def description,
    do:
      "Boards you can see, with their code and lists, and which list is the ready list " <>
        "(take work from), in progress and done. Sub-boards hang off their epic card instead."

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        archived: %{type: "boolean", description: "Include archived boards (default false)."}
      },
      additionalProperties: false
    }
  end

  @impl true
  def read_only?, do: true

  @impl true
  def call(args, %{user: user, token: token}) do
    with {:ok, archived} <- SlipdockWeb.MCP.Args.boolean(args, "archived", false) do
      boards =
        user
        |> Access.list_boards(
          archived: if(archived, do: :all, else: false),
          token: token,
          wiki: false
        )
        |> Boards.sort_boards(user.board_sort || "manual")
        |> Enum.map(&summary(&1, user))

      {:ok, %{boards: boards}}
    end
  end

  @doc "A board as listed here: its code, its lists, and which list plays which part."
  def summary(board, user) do
    full = Boards.get_board!(board.id)
    roles = SlipdockWeb.APIGuide.list_roles(full.columns)

    %{
      id: full.id,
      code: full.code,
      name: full.name,
      owner: if(full.owner_id != user.id, do: "shared with you", else: "yours"),
      simple: full.simple,
      archived: not is_nil(full.archived_at),
      lists:
        Enum.map(full.columns, fn col ->
          %{
            name: col.name,
            category: col.category,
            open: Enum.count(col.cards, &(not &1.completed)),
            cards: length(col.cards)
          }
        end),
      ready: name_of(roles.ready),
      backlog: name_of(roles.backlog),
      doing: name_of(roles.doing),
      done: name_of(roles.done)
    }
    |> put_verified(full)
    # Profiles (#1951), only on a board with them on.
    |> then(&if(full.profiles, do: Map.put(&1, :profiles, true), else: &1))
  end

  # Verified work's switches (#1620), only on a board with one on.
  defp put_verified(map, board) do
    case Slipdock.Verified.switches(board) do
      [] ->
        map

      _ ->
        Map.put(map, :verified_work, %{
          bar_required: board.bar_required,
          evidence_required: board.evidence_required,
          verify_work: board.verify_work,
          verify_pool: board.verify_pool,
          ship_via: board.ship_via
        })
    end
  end

  defp name_of(nil), do: nil
  defp name_of(col), do: col.name
end
