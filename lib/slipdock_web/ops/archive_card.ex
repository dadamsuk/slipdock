defmodule SlipdockWeb.Ops.ArchiveCard do
  @moduledoc """
  Archiving a card, or bringing it back, defined once (#3187). REST has two
  routes for it, `POST /api/cards/:id/archive` and `/restore`: the second
  is this definition with `restore` settled true (`CardController.restore/2`).
  Before it, MCP (`Tools.ArchiveCard`) answered the card's line and REST
  `{card}`; REST archived an archived card again (a new date, another line
  in the activity) and restored a live one to the bottom of its list. Now
  every surface answers `{card}`, and asking for what is already so changes
  nothing.
  """
  @behaviour SlipdockWeb.Ops.Op

  import SlipdockWeb.Ops.Shared, only: [card_json: 2]

  alias Slipdock.Boards
  alias SlipdockWeb.API.{Authorize, CardWrites}

  @impl true
  def definition do
    %{
      name: "archive_card",
      title: "Archive a card",
      summary:
        "Archives a card: off the board and out of listings, kept and restorable. " <>
          "restore = true brings it back. Finished work goes to done, not here.",
      verb: :post,
      path: "/api/cards/:id/archive",
      permission: {:card, :write},
      writes?: true,
      params: [
        %{name: "card", type: :integer, required: true, in_path: "id"},
        %{
          name: "restore",
          type: :boolean,
          default: false,
          doc: "Unarchive instead (default false)."
        }
      ],
      cli: %{
        command: "archive",
        positional: ["card"],
        flags: %{"restore" => %{param: "restore", value: true}}
      }
    }
  end

  @impl true
  def run(%{"card" => id, "restore" => restore}, auth) do
    with {:ok, card} <- CardWrites.fetch_card(id),
         :ok <- Authorize.card(auth, card, :write),
         {:ok, card} <- change(card, restore) do
      {:ok, %{card: card_json(auth, card)}}
    end
  end

  # Asking for what is already so is answered with the card as it is.
  defp change(%{archived_at: nil} = card, true), do: {:ok, card}
  defp change(card, true), do: Boards.Cards.unarchive_card(card)
  defp change(%{archived_at: nil} = card, false), do: Boards.Cards.archive_card(card)
  defp change(card, false), do: {:ok, card}
end
