defmodule SlipdockWeb.MCP.Tools.Comment do
  @moduledoc "A comment on a card: the running log of the work."
  @behaviour SlipdockWeb.MCP.Tool

  alias Slipdock.Boards
  alias SlipdockWeb.API.{Authorize, CardWrites}
  alias SlipdockWeb.MCP.Args

  @impl true
  def name, do: "comment"

  @impl true
  def title, do: "Comment on a card"

  @impl true
  def description,
    do:
      "Adds a comment to a card. Comment as you work: when you start, at each decision " <>
        "or surprise, and when you finish. Markdown; @name mentions notify."

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{card: %{type: "integer"}, body: %{type: "string"}},
      required: ["card", "body"],
      additionalProperties: false
    }
  end

  @impl true
  def read_only?, do: false

  @impl true
  def call(args, context) do
    auth = Args.auth(context)

    with {:ok, id} <- Args.id(args, "card"),
         {:ok, body} <- Args.required(args, "body"),
         {:ok, card} <- Args.refusal(CardWrites.fetch_card(id)),
         :ok <- Args.refusal(Authorize.card(auth, card, :write)),
         {:ok, comment} <- Args.refusal(Boards.add_comment(card, body, by: context.user)) do
      {:ok, %{card: card.id, comment: SlipdockWeb.API.JSON.comment(comment)}}
    end
  end
end
