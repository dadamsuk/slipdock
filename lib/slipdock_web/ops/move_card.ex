defmodule SlipdockWeb.Ops.MoveCard do
  @moduledoc """
  Spike #3165: moving a card, defined once. Before it, REST
  (`CardController.move/2`), MCP (`Tools.MoveCard`) and the CLI (`move`) each
  wrote this by hand, and they disagreed: with no position given REST and the
  CLI put the card at the bottom, MCP at the top; REST took `index`, MCP
  `position`; REST answered `{card, moved}`, MCP the card's line with
  `tags_dropped` beside it.
  """
  @behaviour SlipdockWeb.Ops.Op

  alias Slipdock.Boards
  alias SlipdockWeb.API.{Authorize, CardWrites}
  alias SlipdockWeb.API.JSON, as: V

  @impl true
  def definition do
    %{
      name: "move_card",
      title: "Move a card",
      summary:
        "Moves a card to a list on its board: to the doing list when you start it. With " <>
          "board, to another board, subcards and all. To finish a card use complete_card, " <>
          "which also marks it done.",
      verb: :post,
      path: "/api/cards/:id/move",
      permission: {:card, :write},
      writes?: true,
      params: [
        %{name: "card", type: :integer, required: true, in_path: "id"},
        %{name: "column", type: :string, doc: "List name or id; default the list it is in."},
        %{
          name: "index",
          type: :position,
          default: "bottom",
          doc: "top, bottom or a place in the list (0 is the top). Default bottom."
        },
        %{
          name: "board",
          type: :string,
          doc:
            "Another board (id, code or name); lands at the bottom of column, " <>
              "default its first list."
        }
      ],
      cli: %{
        command: "move",
        positional: ["card", "column..."],
        flags: %{
          "top" => %{param: "index", value: "top"},
          "bottom" => %{param: "index", value: "bottom"},
          "index" => %{param: "index"},
          "board" => %{param: "board"}
        }
      }
    }
  end

  @impl true
  def run(%{"card" => id, "board" => ref} = params, auth) do
    with {:ok, card} <- CardWrites.fetch_card(id),
         :ok <- Authorize.card(auth, card, :write),
         {:ok, board} <- Authorize.fetch_board(auth, ref, :write),
         {:ok, column} <- CardWrites.resolve_column(board, params["column"]),
         refusal = Authorize.tags_refusal(auth, board),
         {:ok, summary} <- move_to_board(card, column, auth, refusal) do
      moved =
        summary
        |> Map.delete(:card)
        |> Map.merge(tags_dropped(summary.tags_dropped, refusal))

      {:ok, %{card: card_json(auth, card), moved: moved}}
    end
  end

  def run(%{"card" => id} = params, auth) do
    with {:ok, card} <- CardWrites.fetch_card(id),
         :ok <- Authorize.card(auth, card, :write),
         board = Boards.get_board!(card.board_id),
         {:ok, column} <- CardWrites.resolve_column(board, params["column"] || card.column_id),
         :ok <-
           Boards.Cards.move_card_to_index(card, column, params["index"], actor: actor(auth)) do
      {:ok, %{card: card_json(auth, card)}}
    end
  end

  defp card_json(auth, card),
    do: V.card(Authorize.visible(auth, Boards.Cards.get_card!(card.id)))

  defp move_to_board(card, column, auth, refusal) do
    case Boards.Moves.move_card_to_board(card, column,
           actor: actor(auth),
           make_tags: is_nil(refusal)
         ) do
      {:ok, summary} -> {:ok, summary}
      {:error, %Ecto.Changeset{}} = refused -> refused
      {:error, message} -> {:error, :unprocessable_entity, message}
    end
  end

  # A conn carries its actor in `Actor.from_conn/1`; the MCP auth map in assigns.
  defp actor(%Plug.Conn{} = conn), do: Slipdock.Actor.from_conn(conn)
  defp actor(%{assigns: %{actor: actor}}), do: actor

  defp tags_dropped([], _refusal), do: %{tags_dropped: []}
  defp tags_dropped(names, refusal), do: %{tags_dropped: names, tags_dropped_reason: refusal}
end
