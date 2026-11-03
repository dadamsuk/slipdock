defmodule SlipdockWeb.MCP.Tools.VerifyCard do
  @moduledoc """
  Accepts or rejects a card waiting for verification (#1633), as
  `POST /api/cards/:id/verify` does: on a board that verifies work, an
  agent's completion waits for a different agent, or a person, to decide.
  """
  @behaviour SlipdockWeb.MCP.Tool

  alias Slipdock.Boards
  alias SlipdockWeb.API.CardWrites
  alias SlipdockWeb.MCP.{Args, Tools}

  @impl true
  def name, do: "verify_card"

  @impl true
  def title, do: "Verify a card's work"

  @impl true
  def description,
    do:
      "Accepts or rejects a card waiting for verification, after checking its work against " <>
        "its bar at the evidence's commit. accept completes it; reject needs the reason. " <>
        "Not on a card you submitted."

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        card: %{type: "integer"},
        decision: %{
          type: "string",
          enum: ["accept", "reject", "merged"],
          description: "merged: a person merged a merging card's pull request by hand."
        },
        reason: %{
          type: "string",
          description:
            "Why: required to reject (what falls short of the bar), optional to accept."
        },
        commit: %{
          type: "string",
          description: "The commit you checked the work at (for merged: the merge commit)."
        }
      },
      required: ["card", "decision"],
      additionalProperties: false
    }
  end

  @impl true
  def read_only?, do: false

  @impl true
  def call(args, context) do
    auth = Args.auth(context)

    with {:ok, id} <- Args.id(args, "card"),
         {:ok, decision} <- Args.required(args, "decision"),
         {:ok, reason} <- Args.optional(args, "reason"),
         {:ok, commit} <- Args.optional(args, "commit"),
         {:ok, card} <- Args.refusal(CardWrites.fetch_card(id)),
         {:ok, card} <-
           Args.refusal(
             CardWrites.verify(auth, card, %{
               "decision" => decision,
               "reason" => reason,
               "commit" => commit
             })
           ) do
      {:ok, card |> Map.get(:id) |> Boards.get_card!() |> Tools.card_written(context.base_url)}
    end
  end
end
