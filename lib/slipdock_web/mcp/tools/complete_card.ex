defmodule SlipdockWeb.MCP.Tools.CompleteCard do
  @moduledoc "Finishes a card the way the guide asks: completed, and in the done list."
  @behaviour SlipdockWeb.MCP.Tool

  alias Slipdock.Boards
  alias SlipdockWeb.API.{Authorize, CardWrites}
  alias SlipdockWeb.MCP.{Args, Tools}

  @impl true
  def name, do: "complete_card"

  @impl true
  def title, do: "Complete a card"

  @impl true
  def description,
    do:
      "Marks a card completed and moves it to its board's done list, with an optional " <>
        "closing comment saying what was done. An epic closes after its subcards."

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        card: %{type: "integer"},
        comment: %{type: "string", description: "What was done, added before closing."},
        evidence: %{
          type: "string",
          description: "What you checked (tests run, output); a board may require it."
        },
        commit: %{type: "string", description: "The commit the evidence is for."}
      },
      required: ["card"],
      additionalProperties: false
    }
  end

  @impl true
  def read_only?, do: false

  @impl true
  def call(args, context) do
    auth = Args.auth(context)

    with {:ok, id} <- Args.id(args, "card"),
         {:ok, note} <- Args.optional(args, "comment"),
         {:ok, evidence} <- Args.optional(args, "evidence"),
         {:ok, commit} <- Args.optional(args, "commit"),
         {:ok, card} <- Args.refusal(CardWrites.fetch_card(id)),
         :ok <- Args.refusal(Authorize.card(auth, card, :write)),
         :ok <- comment(card, note, context.user),
         done = done_list(card),
         params =
           %{"completed" => true, "evidence" => evidence, "evidence_commit" => commit}
           |> Map.reject(fn {_, v} -> is_nil(v) end)
           |> then(&if(done, do: Map.put(&1, "column", done.id), else: &1)),
         {:ok, card} <- Args.refusal(CardWrites.update(auth, card, params)) do
      {:ok,
       card
       |> Tools.card_written(context.base_url)
       |> Map.put(
         :note,
         if(done, do: nil, else: "this board has no done list, so the card stayed where it was")
       )}
    end
  end

  defp comment(_card, nil, _user), do: :ok

  defp comment(card, body, user) do
    with {:ok, _} <- Args.refusal(Boards.add_comment(card, body, by: user)), do: :ok
  end

  defp done_list(card) do
    SlipdockWeb.APIGuide.list_roles(Boards.get_board!(card.board_id).columns).done
  end
end
