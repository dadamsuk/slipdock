defmodule SlipdockWeb.MCP.Tools.UpdateBoard do
  @moduledoc """
  Changes a board's settings, as `PATCH /api/boards/:board` does, for the
  ones an agent is asked to set (#1620): its name, description, colour,
  simple mode, default view, handoff label, the Verified work switches, and
  how long runner job logs stay (#1872), the Agentic Building switch
  (#2011), and who each kind of question an
  agent asks goes to (`wait_routes`, #1949, `Slipdock.WaitRoutes`), and
  each profile's human tier (`profile_tiers`, #1952).
  Only the board's owner may.
  """
  @behaviour SlipdockWeb.MCP.Tool

  alias Slipdock.Boards
  alias SlipdockWeb.API.Authorize
  alias SlipdockWeb.MCP.{Args, Tools, WaitingList}
  alias SlipdockWeb.Ops

  @fields ~w(name description color simple default_view agentic_building handoff_label bar_required
             evidence_required verify_work verify_pool profiles profile_tiers ship_via job_log_hours
             failure_log_hours findings_propose_at wait_default_after release_mode release_age_cap_hours
             release_command)

  # The params it shares with `PATCH /api/boards/:board` (`Ops.SetBoard`).
  # Its own: overseer and waiting_list. The board's other settings are
  # REST's and the CLI's alone (an agent isn't asked to set them, #1620).
  @shared ["board", "wait_routes" | @fields]

  @doc false
  def shared, do: @shared

  @impl true
  def name, do: "update_board"

  @impl true
  def title, do: "Change a board's settings"

  @impl true
  def description,
    do:
      "Changes a board you own: name, description, color, simple, default_view, handoff_label, agentic_building, " <>
        "verified-work switches, profiles, profile_tiers, " <>
        "job log hours, findings_propose_at, wait_routes, overseer. Only what you send changes."

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        # The caller's own Waiting on you (#2069).
        waiting_list: WaitingList.property(board: true),
        overseer: %{
          type: "object",
          description:
            "The overseer (#2068): enabled, the runner pool its passes go to, min_minutes " <>
              "(10) while cards are active and max_minutes (120) when nothing is in flight, " <>
              "idle_minutes before idle runners are said, email, digest_at (HH:MM, 07:00): " <>
              "the morning digest of Housekeeping's work.",
          properties: %{
            enabled: %{type: "boolean"},
            pool: %{type: "string"},
            min_minutes: %{type: "integer"},
            max_minutes: %{type: "integer"},
            idle_minutes: %{type: "integer"},
            email: %{type: "boolean"},
            digest_at: %{type: "string"}
          },
          additionalProperties: false
        }
      },
      required: ["board"],
      additionalProperties: false
    }
    # The params it shares with PATCH /api/boards/:board, from its
    # definition (#3361).
    |> Map.update!(:properties, &Map.merge(&1, Ops.params_from(Ops.SetBoard, @shared)))
  end

  @impl true
  def read_only?, do: false

  @impl true
  def call(args, context) do
    case WaitingList.action(args, "board") do
      :no ->
        update(args, context)

      {:ok, action} ->
        with {:ok, ref} <- Args.required(args, "board"),
             do: WaitingList.board(Args.auth(context), ref, action)

      error ->
        error
    end
  end

  defp update(args, %{user: user} = context) do
    auth = Args.auth(context)
    changes = Map.take(args, @fields)
    routes = Map.get(args, "wait_routes")
    overseer = Map.get(args, "overseer")

    with {:ok, ref} <- Args.required(args, "board"),
         :ok <- something(changes, routes, overseer),
         {:ok, board} <- Args.refusal(Authorize.fetch_board(auth, ref, :owner)),
         {:ok, changes} <- Slipdock.Profiles.put_tiers(board, changes),
         {:ok, board} <- routes(board, routes),
         :ok <- overseer(board, overseer),
         {:ok, board} <- save(board, changes) do
      summary =
        board
        |> Tools.ListBoards.summary(user)
        |> Map.put(:wait_routes, SlipdockWeb.API.JSON.wait_routes(board))
        |> put_overseer(board, overseer)

      {:ok, summary |> put_tiers(board) |> put_agentic_warning(board, changes)}
    end
  end

  defp something(changes, nil, nil) when changes == %{},
    do: {:error, "nothing to change: send a setting"}

  defp something(_changes, _routes, _overseer), do: :ok

  # Only the overseer sent: the board itself is left alone.
  defp save(board, changes) when changes == %{}, do: {:ok, board}
  defp save(board, changes), do: Args.refusal(Boards.update_board(board, changes))

  # The overseer's settings (#2068), on the tree's root.
  defp overseer(_board, nil), do: :ok

  defp overseer(board, %{} = attrs) do
    case Slipdock.Overseer.put_settings(board, attrs) do
      {:ok, _} -> :ok
      error -> Args.refusal(error)
    end
  end

  defp overseer(_board, _), do: {:error, "overseer must be an object"}

  defp put_overseer(summary, _board, nil), do: summary

  defp put_overseer(summary, board, _attrs),
    do:
      Map.put(
        summary,
        :overseer,
        SlipdockWeb.API.OverseerJSON.state(Slipdock.Overseer.state(board))
      )

  # The tree's tiers (#1952) with profiles on, and a loud warning for
  # security set to none.
  defp put_tiers(summary, %{profiles: true} = board) do
    tiers = Slipdock.Profiles.board_tiers(board)

    case Slipdock.Profiles.tier_warnings(tiers) do
      [] -> Map.put(summary, :profile_tiers, tiers)
      warnings -> Map.merge(summary, %{profile_tiers: tiers, warnings: warnings})
    end
  end

  defp put_tiers(summary, _board), do: summary

  # Turning Agentic Building off with rules set (#2011): they go on holding,
  # out of sight in the web app, so say which.
  defp put_agentic_warning(summary, board, %{"agentic_building" => false}) do
    case SlipdockWeb.API.JSON.agentic_warning(board) do
      nil -> summary
      warning -> Map.update(summary, :warnings, [warning], &(&1 ++ [warning]))
    end
  end

  defp put_agentic_warning(summary, _board, _changes), do: summary

  defp routes(board, nil), do: {:ok, board}
  defp routes(board, routes), do: Args.refusal(Slipdock.WaitRoutes.set(board, routes))
end
