defmodule SlipdockWeb.MCP.Tools.StatusUpdate do
  @moduledoc """
  A stated health on a card, as `POST /api/cards/:id/status` takes it: on
  track, at risk or off track, with an optional note. The progress report a
  person posts on an epic, rather than another comment.
  """
  @behaviour SlipdockWeb.MCP.Tool

  alias Slipdock.Boards
  alias Slipdock.Boards.StatusUpdate
  alias SlipdockWeb.API.{Authorize, CardWrites}
  alias SlipdockWeb.MCP.Args

  @impl true
  def name, do: "status_update"

  @impl true
  def title, do: "Post a status update"

  @impl true
  def description,
    do:
      "Posts a status update on a card: its health (on_track, at_risk, off_track) and an " <>
        "optional note. The latest is the card's stated health. Use it to report an epic's " <>
        "progress; comments stay the running log."

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        card: %{type: "integer"},
        health: %{type: "string", enum: StatusUpdate.health_keys()},
        body: %{type: "string", description: "What the health is based on. Markdown."}
      },
      required: ["card", "health"],
      additionalProperties: false
    }
  end

  @impl true
  def read_only?, do: false

  @impl true
  def call(args, context) do
    auth = Args.auth(context)

    with {:ok, id} <- Args.id(args, "card"),
         {:ok, health} <- Args.required(args, "health"),
         {:ok, body} <- Args.optional(args, "body"),
         {:ok, card} <- Args.refusal(CardWrites.fetch_card(id)),
         :ok <- Args.refusal(Authorize.card(auth, card, :comment)),
         {:ok, update} <-
           Args.refusal(
             Boards.add_status_update(card, context.user, %{"health" => health, "body" => body})
           ) do
      {:ok,
       %{
         card: card.id,
         status_update: SlipdockWeb.API.JSON.status_update(update),
         stated_health: update.health
       }}
    end
  end
end
