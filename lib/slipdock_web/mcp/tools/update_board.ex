defmodule SlipdockWeb.MCP.Tools.UpdateBoard do
  @moduledoc """
  Changes a board's settings, as `PATCH /api/boards/:board` does, for the
  ones an agent is asked to set (#1620): its name, description, colour,
  simple mode, default view, handoff label, the Verified work switches, and
  how long runner job logs stay (#1872).
  Only the board's owner may.
  """
  @behaviour SlipdockWeb.MCP.Tool

  alias Slipdock.Boards
  alias SlipdockWeb.API.Authorize
  alias SlipdockWeb.MCP.{Args, Tools}

  @fields ~w(name description color simple default_view handoff_label bar_required
             evidence_required verify_work verify_pool lanes ship_via job_log_hours
             failure_log_hours findings_propose_at)

  @impl true
  def name, do: "update_board"

  @impl true
  def title, do: "Change a board's settings"

  @impl true
  def description,
    do:
      "Changes a board you own: name, description, color, simple, default_view, handoff_label, " <>
        "bar_required, evidence_required, verify_work, verify_pool, ship_via, lanes, " <>
        "job_log_hours, failure_log_hours, findings_propose_at. Only what you send changes."

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        board: %{type: "string", description: "Board id, code or name."},
        name: %{type: "string"},
        description: %{type: "string"},
        color: %{type: "string", description: "A palette colour."},
        simple: %{type: "boolean", description: "A plain to-do list."},
        default_view: %{type: "string", description: "What opening the board shows: board, wiki…"},
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
        lanes: %{
          type: "boolean",
          description: "Refuse agents starting cards whose paths overlap."
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
        }
      },
      required: ["board"],
      additionalProperties: false
    }
  end

  @impl true
  def read_only?, do: false

  @impl true
  def call(args, %{user: user} = context) do
    auth = Args.auth(context)
    changes = Map.take(args, @fields)

    with {:ok, ref} <- Args.required(args, "board"),
         :ok <- if(changes == %{}, do: {:error, "nothing to change: send a setting"}, else: :ok),
         {:ok, board} <- Args.refusal(Authorize.fetch_board(auth, ref, :owner)),
         {:ok, board} <- Args.refusal(Boards.update_board(board, changes)) do
      {:ok, Tools.ListBoards.summary(board, user)}
    end
  end
end
