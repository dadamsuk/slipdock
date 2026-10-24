defmodule SlipdockWeb.MCP.Tools.GetCard do
  @moduledoc "One card in full: handoff, description, checklist, comments, dependencies and docs."
  @behaviour SlipdockWeb.MCP.Tool

  alias Slipdock.Boards
  alias SlipdockWeb.API.Authorize
  alias SlipdockWeb.API.JSON, as: V
  alias SlipdockWeb.MCP.Args

  @impl true
  def name, do: "get_card"

  @impl true
  def title, do: "Get a card"

  @impl true
  def description,
    do:
      "A card in full: its handoff (where it was left: read it first, before the comments), " <>
        "description (the brief), checklist, comments (often where the real constraint is), " <>
        "dependencies, subcards, wiki pages, recurrence and wait (on a person)."

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        card: %{type: "integer", description: "The card's number, e.g. 129."},
        timeline: %{
          type: "boolean",
          description: "Also return its timeline: how long it sat in each list, waits, jobs."
        },
        waits: %{
          type: "boolean",
          description: "Also return every question it has asked, with the answers (newest first)."
        }
      },
      required: ["card"],
      additionalProperties: false
    }
  end

  @impl true
  def read_only?, do: true

  @impl true
  def call(args, context) do
    auth = Args.auth(context)

    with {:ok, id} <- Args.id(args, "card"),
         {:ok, card} <- fetch(id),
         :ok <- Args.refusal(Authorize.card(auth, card, :read)) do
      docs = card |> Slipdock.Wiki.pages_for_card(context.user) |> Enum.map(&doc/1)

      {:ok,
       auth
       |> Authorize.visible(Boards.with_state(card))
       |> V.card()
       |> Map.put(:docs, docs)
       |> Map.put(:wait, V.wait(Boards.current_wait(card)))
       |> Map.put(:last_wait, V.wait(Boards.last_wait(card)))
       |> Map.put(:url, url(card, context.base_url))
       |> V.put_delivery(card)
       |> V.put_handbook(card, context.user, context[:token])
       |> put_timeline(card, args["timeline"] == true)
       |> put_waits(card, args["waits"] == true)}
    end
  end

  # Only when asked: most reads want the brief, not the history (#1131).
  defp put_timeline(map, card, true),
    do: Map.put(map, :timeline, V.timeline(Slipdock.CardTimeline.for_card(card)))

  defp put_timeline(map, _card, _), do: map

  # Every wait, asked and answered (#1220), only when asked for.
  defp put_waits(map, card, true),
    do: Map.put(map, :waits, Enum.map(Boards.list_waits(card), &V.wait/1))

  defp put_waits(map, _card, _), do: map

  @doc "A wiki page about a card, as a card's `docs` lists it."
  def doc(link), do: %{code: link.page.code, title: link.page.title, pinned: link.pinned}

  @doc "Where the card opens in the web app."
  def url(card, base_url), do: base_url <> "/boards/#{card.board_id}/cards/#{card.id}"

  defp fetch(id) do
    case Boards.get_card(id) do
      nil -> {:error, "no card you can see matches that"}
      card -> {:ok, card}
    end
  end
end
