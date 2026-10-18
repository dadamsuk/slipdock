defmodule SlipdockWeb.MCP.Tools.LeaveHandoff do
  @moduledoc """
  Where a card was left, as `POST /api/cards/:id/handoff` takes it: the one
  next step and a short note, for whoever picks the card up next (W-1804).
  """
  @behaviour SlipdockWeb.MCP.Tool

  alias SlipdockWeb.API.{Authorize, CardWrites}
  alias SlipdockWeb.MCP.Args

  @impl true
  def name, do: "leave_handoff"

  @impl true
  def title, do: "Leave a handoff on a card"

  @impl true
  def description,
    do:
      "Leaves the card's handoff: where you left it, for whoever picks it up next. Write one " <>
        "whenever you stop with the card unfinished. It replaces the last one (older ones are " <>
        "kept as history) and get_card shows it first. next_step is the one next step, one " <>
        "line; body is the note: State, Next, Gotchas, Open, Pointers. clear: true clears it."

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        card: %{type: "integer"},
        next_step: %{type: "string", description: "The one next step. One line, at most 280."},
        body: %{
          type: "string",
          description:
            "Markdown, at most 8000. State: what is done and half-done. Gotchas: what bit you. " <>
              "Open: questions waiting on someone. Pointers: branch, files, commits, pages."
        },
        clear: %{type: "boolean", description: "Clear the handoff instead of writing one."}
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
         {:ok, clear} <- Args.boolean(args, "clear", false),
         {:ok, next_step} <- Args.optional(args, "next_step"),
         {:ok, body} <- Args.optional(args, "body"),
         {:ok, card} <- Args.refusal(CardWrites.fetch_card(id)),
         :ok <- Args.refusal(Authorize.card(auth, card, :comment)),
         {:ok, handoff} <-
           Args.refusal(
             CardWrites.write_handoff(
               card,
               context.user,
               %{"clear" => clear, "next_step" => next_step, "body" => body},
               "mcp"
             )
           ) do
      {:ok, %{card: card.id, handoff: SlipdockWeb.API.JSON.handoff(handoff)}}
    end
  end
end
