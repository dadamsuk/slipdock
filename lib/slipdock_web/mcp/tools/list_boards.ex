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
        "(take work from), in progress and done, and the Scheduled list (worked by feed rules, " <>
        "never taken from). Sub-boards hang off their epic card instead."

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
        |> Boards.Arrangement.sort_boards(user.board_sort || "manual")
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
      # Agentic Building (#2011): the web app's page for the agent settings.
      agentic_building: full.agentic_building,
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
      done: name_of(roles.done),
      # Where recurring agent work lands (#2100): never the ready list.
      scheduled: name_of(roles.scheduled),
      housekeeping: name_of(roles.housekeeping)
    }
    |> put_verified(full)
    # Profiles (#1951), only on a board with them on.
    |> then(&if(full.profiles, do: Map.put(&1, :profiles, true), else: &1))
    |> put_lanes(full)
    # Batched releases (#2834), only on a tree that has them on.
    |> put_release(full)
  end

  defp put_release(map, board) do
    case Slipdock.Releases.settings(board) do
      %{mode: "batched", age_cap_hours: cap} ->
        Map.put(map, :release, %{mode: "batched", age_cap_hours: cap})

      _ ->
        map
    end
  end

  @doc """
  `map` with a `lanes` key on a board with lanes on or shared paths set
  (#1971): `%{on:, shared_paths:}`, the globs being the ones that hold for
  the board (its root's and its own). A board with neither reads as before.
  """
  def put_lanes(map, board) do
    case SlipdockWeb.API.JSON.board_lanes(board) do
      nil -> map
      lanes -> Map.put(map, :lanes, lanes)
    end
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
