defmodule Slipdock.ArchivedCardLookupTest do
  @moduledoc """
  Finding archived cards (#1037): a typed reference — an id or a card's link —
  names one card, and the archive's search matches titles or that reference.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.Boards

  describe "card_ref/1" do
    test "reads an id, with or without a hash" do
      assert Boards.card_ref("123") == 123
      assert Boards.card_ref("#123") == 123
      assert Boards.card_ref("  # 123 ") == 123
    end

    test "reads a card's link, whole or as a path, from any view" do
      assert Boards.card_ref("https://app.slipdock.us/boards/3/cards/1037") == 1037
      assert Boards.card_ref("http://localhost:4000/boards/3/cards/1037") == 1037
      assert Boards.card_ref("/boards/3/cards/1037") == 1037
      assert Boards.card_ref("/boards/3/table/cards/1037?at=comment-9") == 1037
      assert Boards.card_ref("https://x.test/boards/3/swimlanes/cards/1037#top") == 1037
    end

    test "anything else names no card" do
      for q <- [
            "",
            "abc",
            "123x",
            "#",
            "fix 123",
            "/boards/3",
            "/boards/3/wiki/cards",
            "see /boards/3/cards/12",
            "https://x.test/boards/3/cards/",
            nil
          ] do
        assert Boards.card_ref(q) == nil, "expected no card for #{inspect(q)}"
      end
    end
  end

  describe "list_archived_cards/2" do
    setup do
      board = board_fixture(%{"name" => "Archive search"})
      col = hd(board.columns)
      refunds = archived(col, "Refunds 100% rounding")
      deploy = archived(col, "Deploy rollback")
      live = card_fixture(col, %{"title" => "Refunds still live"})
      %{board: board, refunds: refunds, deploy: deploy, live: live}
    end

    defp archived(col, title) do
      {:ok, card} = Boards.archive_card(card_fixture(col, %{"title" => title}))
      card
    end

    defp ids(cards), do: cards |> Enum.map(& &1.id) |> Enum.sort()

    test "with no query, every archived card and no live one", ctx do
      assert ids(Boards.list_archived_cards(ctx.board.id)) == ids([ctx.refunds, ctx.deploy])
      assert ids(Boards.list_archived_cards(ctx.board.id, "  ")) == ids([ctx.refunds, ctx.deploy])
    end

    test "a piece of a title matches regardless of case, and only archived cards", ctx do
      assert ids(Boards.list_archived_cards(ctx.board.id, "REFUNDS")) == [ctx.refunds.id]
      assert Boards.list_archived_cards(ctx.board.id, "nothing like it") == []
    end

    test "LIKE wildcards in the query are taken literally", ctx do
      assert ids(Boards.list_archived_cards(ctx.board.id, "100%")) == [ctx.refunds.id]
      assert Boards.list_archived_cards(ctx.board.id, "_%") == []
    end

    test "an id or a link names that one card", ctx do
      assert ids(Boards.list_archived_cards(ctx.board.id, "##{ctx.deploy.id}")) == [ctx.deploy.id]

      link = "https://app.slipdock.us/boards/#{ctx.board.id}/cards/#{ctx.deploy.id}"
      assert ids(Boards.list_archived_cards(ctx.board.id, link)) == [ctx.deploy.id]
    end

    test "naming a live card, or one on another board, finds nothing", ctx do
      other = board_fixture(%{"name" => "Elsewhere"})
      theirs = archived(hd(other.columns), "Elsewhere archived")

      assert Boards.list_archived_cards(ctx.board.id, "#{ctx.live.id}") == []
      assert Boards.list_archived_cards(ctx.board.id, "#{theirs.id}") == []
    end
  end

  describe "card_by_ref_across/3" do
    test "finds an archived card only when asked to, and never a stand-in" do
      board = board_fixture(%{"name" => "Refs"})
      {:ok, gone} = Boards.archive_card(card_fixture(hd(board.columns), %{"title" => "Gone"}))

      assert Boards.card_by_ref_across([board.id], "##{gone.id}") == nil
      assert %{id: id} = Boards.card_by_ref_across([board.id], "##{gone.id}", archived: true)
      assert id == gone.id

      link = "/boards/#{board.id}/cards/#{gone.id}"
      assert %{id: ^id} = Boards.card_by_ref_across([board.id], link, archived: true)
      assert Boards.card_by_ref_across([board.id + 1_000_000], link, archived: true) == nil
    end
  end
end
