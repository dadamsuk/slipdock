defmodule SlipdockWeb.MCP.Tools.UpdateBoard do
  @moduledoc """
  Changes a board's settings, as `PATCH /api/boards/:board` does, for the
  ones an agent is asked to set (#1620): its name, description, colour,
  simple mode, default view, handoff label, and the Verified work switches.
  Only the board's owner may.
  """
  @behaviour SlipdockWeb.MCP.Tool

  alias Slipdock.Boards
  alias SlipdockWeb.API.Authorize
  alias SlipdockWeb.MCP.{Args, Tools}

  @fields ~w(name description color simple default_view handoff_label bar_required
             evidence_required verify_work verify_pool)

  @impl true
  def name, do: "update_board"

  @impl true
  def title, do: "Change a board's settings"

  @impl true
  def description,
    do:
      "Changes settings on a board you own: name, description, color, simple, default_view, " <>
        "handoff_label, and Verified work's bar_required, evidence_required, verify_work and " <>
        "verify_pool. Only what you send changes."

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
        verify_pool: %{type: "string", description: "Runner pool for verify jobs; \"\" none."}
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
