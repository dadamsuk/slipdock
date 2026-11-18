defmodule SlipdockWeb.Ops.DeleteCard do
  @moduledoc """
  Deleting a card for good, its subcards, comments and files with it,
  defined once (#3187). `archive_card` is the undoable way, so MCP asks
  `confirm: true` first (`confirm/2`); REST and the CLI, whose callers name
  the card and the verb themselves, never did and still don't. Before it,
  REST answered `{ok}` and MCP `{deleted, card, title, board_id}`: now both
  answer `{ok, card, title, board_id}`.
  """
  @behaviour SlipdockWeb.Ops.Op

  alias Slipdock.Boards
  alias SlipdockWeb.API.{Authorize, CardWrites}

  @impl true
  def definition do
    %{
      name: "delete_card",
      title: "Delete a card",
      summary:
        "Deletes a card and its subcards, comments and files. Cannot be undone; " <>
          "archive_card is the safe way. Needs confirm = true.",
      verb: :delete,
      path: "/api/cards/:id",
      permission: {:card, :write},
      writes?: true,
      destructive?: true,
      params: [%{name: "card", type: :integer, required: true, in_path: "id"}],
      # Any value casts, so a wrong one ("yes") is refused by confirm/2,
      # which names the undoable way.
      confirm: %{
        type: :any,
        schema: %{type: "boolean"},
        doc: "Must be true: this cannot be undone."
      },
      cli: %{command: "delete", positional: ["card"], flags: %{}}
    }
  end

  @impl true
  def confirm(%{"confirm" => true}, _auth), do: :ok

  def confirm(_params, _auth),
    do:
      {:error,
       "not done: this cannot be undone, so it needs confirm = true. " <>
         "archive_card puts it away and can be undone."}

  @impl true
  def run(%{"card" => id}, auth) do
    with {:ok, card} <- CardWrites.fetch_card(id),
         :ok <- Authorize.card(auth, card, :write),
         {:ok, _} <- Boards.Cards.delete_card(card) do
      {:ok, %{ok: true, card: card.id, title: card.title, board_id: card.board_id}}
    end
  end
end
