defmodule SlipdockWeb.MCP.Tools.GetCard do
  @moduledoc "One card in full: description, checklist, comments, dependencies and docs."
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
      "A card in full: description (the brief), checklist, comments (often where the real " <>
        "constraint is), dependencies, subcards (sub_board) and the wiki pages about it."

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{card: %{type: "integer", description: "The card's number, e.g. 129."}},
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
       |> Authorize.visible(card)
       |> V.card()
       |> Map.put(:docs, docs)
       |> Map.put(:url, url(card, context.base_url))}
    end
  end

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
