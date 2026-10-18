defmodule SlipdockWeb.MCP.Tools.GardenDecide do
  @moduledoc """
  Applies, dismisses or undoes one gardener suggestion, as `POST
  /api/garden/suggestions/:id/apply|dismiss|undo` do (W-1807). It wants
  `confirm: true`, because the decision is the person's, not the model's.
  """
  @behaviour SlipdockWeb.MCP.Tool

  alias Slipdock.Boards.Board
  alias Slipdock.Gardener
  alias Slipdock.Repo
  alias SlipdockWeb.API.Authorize
  alias SlipdockWeb.API.GardenJSON, as: G
  alias SlipdockWeb.MCP.Args

  @impl true
  def name, do: "garden_decide"

  @impl true
  def title, do: "Apply or dismiss a tidy-up suggestion"

  @impl true
  def description,
    do:
      "Applies or dismisses one suggestion from garden. Apply only what the person has approved, " <>
        "one by one; never apply a whole list on your own judgment. A dismissal is remembered and " <>
        "the suggestion won't come back unless its subject changes. decision undo puts an applied " <>
        "one back. keep: the card that stays, for a duplicate; choice: one of its alternatives " <>
        "instead of the proposal. Needs confirm = true."

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        suggestion: %{type: "integer"},
        decision: %{type: "string", enum: ["apply", "dismiss", "undo"]},
        keep: %{type: "integer", description: "For a duplicate: the card that stays."},
        choice: %{type: "string", description: "One of the suggestion's alternatives, by name."},
        confirm: %{type: "boolean", description: "Must be true: the person approved this."}
      },
      required: ["suggestion", "decision", "confirm"],
      additionalProperties: false
    }
  end

  @impl true
  def read_only?, do: false

  @impl true
  def call(args, context) do
    auth = Args.auth(context)

    with {:ok, id} <- Args.id(args, "suggestion"),
         {:ok, decision} <- decision(args["decision"]),
         :ok <- approved(args),
         {:ok, s} <- fetch(id),
         board = Repo.get!(Board, s.board_id),
         :ok <- readable(auth, board, id),
         :ok <- Args.refusal(Authorize.board(auth, board, :write)),
         {:ok, s} <- refusal(decide(s, context.user, decision, args)) do
      {:ok, %{suggestion: G.suggestion(s)}}
    end
  end

  defp decision(d) when d in ~w(apply dismiss undo), do: {:ok, d}
  defp decision(_), do: {:error, "decision must be apply, dismiss or undo"}

  defp approved(%{"confirm" => true}), do: :ok

  defp approved(_),
    do:
      {:error,
       "not done: garden_decide needs confirm = true, and only for a suggestion the person has approved. " <>
         "Show them the suggestion and ask first."}

  defp readable(auth, board, id) do
    case Authorize.board(auth, board, :read) do
      :ok -> :ok
      _ -> {:error, "no suggestion ##{id}"}
    end
  end

  defp fetch(id) do
    case Gardener.get_suggestion(id) do
      nil -> {:error, "no suggestion ##{id}"}
      s -> {:ok, s}
    end
  end

  defp decide(s, user, "undo", _args), do: Gardener.undo(s, user)

  defp decide(s, user, decision, args),
    do: Gardener.decide(s, user, decision, keep: args["keep"], choice: args["choice"])

  defp refusal({:error, :forbidden}),
    do: {:error, "you can't change everything this suggestion touches"}

  defp refusal(other), do: Args.refusal(other)
end
