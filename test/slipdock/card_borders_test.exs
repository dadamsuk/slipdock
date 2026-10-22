defmodule Slipdock.CardBordersTest do
  @moduledoc """
  A colour on each edge of a card (#1209): checked against the palette,
  cleared with a blank, and kept by a copy and a portable export and import.
  """
  # Sync, as the other import tests: imports derive board codes.
  use Slipdock.DataCase, async: false

  import Slipdock.Fixtures

  alias Slipdock.{Boards, Portable, Repo}
  alias Slipdock.Boards.Card

  setup do
    owner = user_fixture("owner@example.com")
    board = board_fixture(%{"name" => "Edges", "code" => unique_code()}, owner: owner)
    card = card_fixture(hd(board.columns), %{"title" => "Framed"})
    %{owner: owner, board: board, card: card}
  end

  defp edges(card), do: Enum.map(Card.borders(), &Map.get(card, &1))

  test "each edge takes its own palette colour", ctx do
    {:ok, card} =
      Boards.update_card(ctx.card, %{
        "border_top" => "red",
        "border_right" => "sky",
        "border_bottom" => "amber",
        "border_left" => "emerald"
      })

    assert edges(Repo.reload!(card)) == ~w(red sky amber emerald)
  end

  test "a colour that isn't in the palette is refused, edge by edge", ctx do
    {:error, cs} =
      Boards.update_card(ctx.card, %{"border_left" => "chartreuse", "border_top" => "red"})

    assert %{border_left: [_]} = errors_on(cs)
    refute Map.has_key?(errors_on(cs), :border_top)
    assert edges(Repo.reload!(ctx.card)) == [nil, nil, nil, nil]
  end

  test "a blank takes an edge's colour off and leaves the others", ctx do
    {:ok, card} = Boards.update_card(ctx.card, %{"border_top" => "red", "border_left" => "sky"})
    {:ok, card} = Boards.update_card(card, %{"border_top" => ""})
    assert edges(Repo.reload!(card)) == [nil, nil, nil, "sky"]
  end

  test "the edges are apart from the cover colour", ctx do
    {:ok, card} = Boards.update_card(ctx.card, %{"color" => "violet", "border_top" => "red"})
    {:ok, card} = Boards.update_card(card, %{"color" => ""})
    card = Repo.reload!(card)
    assert card.color == nil and card.border_top == "red"
  end

  test "a copy keeps the edges", ctx do
    {:ok, card} =
      Boards.update_card(ctx.card, %{"border_right" => "rose", "border_bottom" => "teal"})

    {:ok, copy} = Boards.copy_card(card, nil, at: :after, by: ctx.owner)
    assert edges(copy) == [nil, "rose", "teal", nil]
  end

  describe "portable" do
    setup ctx do
      {:ok, card} = Boards.update_card(ctx.card, %{"border_top" => "red", "border_left" => "sky"})
      %{card: card}
    end

    defp import_as(user, document) do
      {:ok, report} = Portable.import(user, Jason.encode!(document))
      board = Boards.get_board!(hd(report.boards).id)
      [card] = Boards.list_cards(board)
      Repo.get!(Card, card.id)
    end

    test "the export carries each edge and the import puts them back", ctx do
      document = Portable.export(ctx.owner, boards: [ctx.board])
      [card] = hd(document.boards).cards

      assert %{border_top: "red", border_right: nil, border_bottom: nil, border_left: "sky"} =
               card

      assert edges(import_as(ctx.owner, document)) == ["red", nil, nil, "sky"]
    end

    test "an edge colour the palette doesn't know arrives as none, not a lost card", ctx do
      document =
        ctx.owner
        |> Portable.export(boards: [ctx.board])
        |> put_in([:boards, Access.at(0), :cards, Access.at(0), :border_top], "chartreuse")

      assert edges(import_as(ctx.owner, document)) == [nil, nil, nil, "sky"]
    end
  end
end
