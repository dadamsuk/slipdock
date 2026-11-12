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

  @fields ~w(name description color simple default_view agentic_building handoff_label bar_required
             evidence_required verify_work verify_pool lanes lane_mode shared_paths profiles profile_tiers ship_via job_log_hours
             failure_log_hours findings_propose_at wait_default_after release_mode release_age_cap_hours
             release_command)

  @impl true
  def name, do: "update_board"

  @impl true
  def title, do: "Change a board's settings"

  @impl true
  def description,
    do:
      "Changes a board you own: name, description, color, simple, default_view, handoff_label, agentic_building, " <>
        "verified-work switches, lanes, profiles, profile_tiers, " <>
        "job log hours, findings_propose_at, wait_routes, overseer. Only what you send changes."

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        board: %{type: "string", description: "Board id, code or name."},
        # The caller's own Waiting on you (#2069).
        waiting_list: WaitingList.property(board: true),
        name: %{type: "string"},
        description: %{type: "string"},
        color: %{type: "string", description: "A palette colour."},
        simple: %{type: "boolean", description: "A plain to-do list."},
        default_view: %{type: "string", description: "What opening the board shows: board, wiki…"},
        agentic_building: %{
          type: "boolean",
          description:
            "Show the Agentic Building item and page in the web app. Off changes no setting."
        },
        handoff_label: %{type: "string", description: "What a handoff is called; \"\" default."},
        bar_required: %{type: "boolean", description: "Agents write a card's bar before work."},
        evidence_required: %{type: "boolean", description: "Agents give evidence to complete."},
        verify_work: %{type: "boolean", description: "A second agent accepts or rejects."},
        verify_pool: %{type: "string", description: "Runner pool for verify jobs; \"\" none."},
        ship_via: %{
          type: "string",
          enum: ["push", "pull_request"],
          description: "How verified work ships: push, or pull_request (needs verify_work)."
        },
        release_mode: %{
          type: "string",
          enum: Slipdock.Boards.Board.release_modes(),
          description:
            "How merged work reaches production: on_merge (each merge deploys) or batched " <>
              "(merges wait for a release). Root board only."
        },
        release_age_cap_hours: %{
          type: ["integer", "null"],
          description:
            "Batched: release once the oldest waiting merge has waited this many hours; " <>
              "null off. Root board only."
        },
        release_command: %{
          type: ["string", "null"],
          description:
            "Batched: the one-line command a runner's release job runs; null for the " <>
              "default (gh workflow run release.yml). Any other command runs only on a " <>
              "machine whose local.json lists it under release_commands. Root board only."
        },
        lanes: %{
          type: "boolean",
          description: "Lanes on (as hold) or off. lane_mode, if sent too, wins."
        },
        lane_mode: %{
          type: "string",
          enum: Slipdock.Boards.Board.lane_modes(),
          description:
            "What an overlap does: off; hold (refuse an agent's start, hold its job); " <>
              "advise (start it, and tell the agent in its job's prompt)."
        },
        profiles: %{
          type: "boolean",
          description:
            "Give a card an agent claims or starts a profile (docs, fix, feature, schema, " <>
              "security, spike) when it has none."
        },
        profile_tiers: %{
          type: "object",
          description:
            "Each profile's human tier on the tree (root board only): none or ledger (acceptance " <>
              "merges), before_merge (a person decides first); default puts one back. Defaults: " <>
              "docs/fix/spike none, feature ledger, schema/security before_merge.",
          properties:
            Map.new(Slipdock.Profiles.names(), fn p ->
              {p, %{type: "string", enum: Slipdock.Profiles.tiers() ++ ["default"]}}
            end),
          additionalProperties: false
        },
        shared_paths: %{
          type: "array",
          items: %{type: "string"},
          description:
            "Globs that never count toward a lane (docs/manual.md, README.md): cards may " <>
              "both declare them without holding each other. [] clears."
        },
        job_log_hours: %{
          type: "integer",
          description: "Hours a finished runner job's log stays (24 by default)."
        },
        failure_log_hours: %{
          type: "integer",
          description: "Hours a failed, stuck or rejected job's log stays (168 by default)."
        },
        findings_propose_at: %{
          type: "integer",
          description:
            "A finding seen this many times gets a handbook rule proposal drafted (3 by default; 0 off)."
        },
        wait_default_after: %{
          type: ["string", "integer", "null"],
          description:
            "How long an approval wait (kind other, with choices and a default) goes " <>
              "unanswered before its proposal stands: 4h, 90m, 2d or minutes; off or null " <>
              "turns it off (the default). Never for product, ux, security or release waits."
        },
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
        },
        wait_routes: %{
          type: "object",
          description:
            "Who each kind of question goes to: kind => emails of the board's users, the first " <>
              "is who it waits on, the rest are told; [] takes a kind's route off.",
          properties:
            Map.new(Slipdock.WaitRoutes.kinds(), fn kind ->
              {kind, %{type: "array", items: %{type: "string"}}}
            end),
          additionalProperties: false
        }
      },
      required: ["board"],
      additionalProperties: false
    }
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
