defmodule Slipdock.SearchTest do
  @moduledoc """
  The index and the search over it. Embeddings come from `Slipdock.AIStub`'s
  bag-of-words stand-in, which shares the one property that matters here:
  texts with words in common score higher than texts without.
  """
  use Slipdock.DataCase, async: false

  import Slipdock.Fixtures

  alias Slipdock.{Access, Boards, Search}
  alias Slipdock.Search.{Chunk, Embedding, Indexer, Vector}

  setup do
    Slipdock.AIStub.share()
    Slipdock.AIStub.stub_embeddings()

    owner = user_fixture("owner@example.com")
    board = board_fixture(%{"name" => "Delivery"}, owner: owner)
    column = hd(board.columns)

    %{owner: owner, board: board, column: column}
  end

  defp index(card), do: {:ok, _} = Search.index_card(card.id)

  describe "vectors" do
    test "pack and unpack round-trip, and cosine is the dot product" do
      a = Vector.pack([1.0, 0.0, 0.0, 0.0])
      b = Vector.pack([1.0, 0.0, 0.0, 0.0])
      c = Vector.pack([0.0, 1.0, 0.0, 0.0])

      assert Vector.size(a) == 4
      assert Enum.map(Vector.unpack(a), &round/1) == [1, 0, 0, 0]
      assert_in_delta Vector.similarity(a, b), 1.0, 0.0001
      assert_in_delta Vector.similarity(a, c), 0.0, 0.0001
    end

    test "the unrolled walk handles lengths that are not a multiple of four" do
      a = Vector.pack([1.0, 1.0, 1.0, 1.0, 1.0])
      assert_in_delta Vector.similarity(a, a), 5.0, 0.0001
    end

    test "vectors of different lengths score zero rather than raising" do
      assert Vector.similarity(Vector.pack([1.0]), Vector.pack([1.0, 1.0])) == 0.0
    end
  end

  describe "chunking" do
    test "a card becomes one chunk plus one per comment and status update", ctx do
      card = card_fixture(ctx.column, %{"title" => "Rotate the Stripe keys"})
      {:ok, _} = Boards.add_comment(card, "Blocked until finance approve the new plan")
      {:ok, _} = Boards.add_status_update(card, ctx.owner, %{"health" => "at_risk"})

      chunks = card.id |> then(&Repo.get(Search.card_query(), &1)) |> Chunk.for_card()

      assert Enum.map(chunks, & &1.kind) |> Enum.sort() == ["card", "comment", "status_update"]
      assert Enum.all?(chunks, &(&1.card_id == card.id and &1.board_id == ctx.board.id))

      card_chunk = Enum.find(chunks, &(&1.kind == "card"))
      assert card_chunk.body =~ "Board: Delivery"
      assert card_chunk.body =~ "Rotate the Stripe keys"

      comment_chunk = Enum.find(chunks, &(&1.kind == "comment"))
      # Every chunk repeats its card, so a lone comment still says what it is about.
      assert comment_chunk.body =~ "Rotate the Stripe keys"
      assert comment_chunk.body =~ "finance approve"
    end

    test "the card chunk carries the facets people search in words", ctx do
      card =
        card_fixture(ctx.column, %{
          "title" => "Ship it",
          "priority" => "critical",
          "due_date" => "2026-11-30",
          "flags" => ["blocked"]
        })

      {:ok, _} = Boards.set_card_tags(card, [tag_fixture(ctx.board, "billing")])
      body = Repo.get(Search.card_query(), card.id) |> Chunk.for_card() |> hd() |> Map.get(:body)

      assert body =~ "priority critical"
      assert body =~ "due 2026-11-30"
      assert body =~ "flags: blocked"
      assert body =~ "tags: billing"
    end
  end

  describe "indexing" do
    test "indexes a card, skips unchanged text, and re-embeds what changed", ctx do
      card = card_fixture(ctx.column, %{"title" => "Alpha", "description" => "first"})

      assert {:ok, %{embedded: 1, unchanged: 0}} = Search.index_card(card.id)
      # Nothing changed, so nothing is sent to the model a second time.
      assert {:ok, %{embedded: 0, unchanged: 1}} = Search.index_card(card.id)

      {:ok, card} = Boards.update_card(card, %{"description" => "second"})
      assert {:ok, %{embedded: 1, unchanged: 0}} = Search.index_card(card.id)

      assert [%Embedding{kind: "card", body: body}] =
               Repo.all(from(e in Embedding, where: e.card_id == ^card.id))

      assert body =~ "second"
    end

    test "a deleted comment loses its chunk on the next index", ctx do
      card = card_fixture(ctx.column, %{"title" => "Alpha"})
      {:ok, comment} = Boards.add_comment(card, "a note worth keeping")
      index(card)
      assert Repo.aggregate(from(e in Embedding, where: e.card_id == ^card.id), :count) == 2

      {:ok, _} = Boards.delete_comment(comment.id)
      assert {:ok, %{removed: 1}} = Search.index_card(card.id)
      assert Repo.aggregate(from(e in Embedding, where: e.card_id == ^card.id), :count) == 1
    end

    test "deleting a card forgets everything indexed for it", ctx do
      card = card_fixture(ctx.column, %{"title" => "Alpha"})
      {:ok, _} = Boards.add_comment(card, "something")
      index(card)

      {:ok, _} = Boards.delete_card(card)
      assert Repo.aggregate(from(e in Embedding, where: e.card_id == ^card.id), :count) == 0
    end

    test "writes queue the card, and a flush embeds it", ctx do
      card = card_fixture(ctx.column, %{"title" => "Queued work"})
      assert Indexer.pending() >= 1

      assert {:ok, %{embedded: n}} = Indexer.flush()
      assert n >= 1
      assert Indexer.pending() == 0
      assert Repo.aggregate(from(e in Embedding, where: e.card_id == ^card.id), :count) == 1
    end

    test "a model change makes every chunk stale", ctx do
      card = card_fixture(ctx.column, %{"title" => "Alpha"})
      index(card)

      Repo.update_all(from(e in Embedding), set: [model: "some/older-model"])
      assert {:ok, %{embedded: 1, unchanged: 0}} = Search.index_card(card.id)
    end
  end

  describe "searching" do
    setup ctx do
      billing = card_fixture(ctx.column, %{"title" => "Invoice rounding is wrong on refunds"})
      deploy = card_fixture(ctx.column, %{"title" => "Deploy pipeline needs a rollback step"})
      quiet = card_fixture(ctx.column, %{"title" => "Order new whiteboard markers"})

      {:ok, _} = Boards.add_comment(deploy, "the staging rollback was blocked on approvals")

      for card <- [billing, deploy, quiet], do: index(card)
      %{billing: billing, deploy: deploy, quiet: quiet}
    end

    test "finds cards by the words they share, best first", ctx do
      assert {:ok, results} = Search.search(ctx.owner, "invoice rounding refunds")
      assert hd(results).card.id == ctx.billing.id
      assert hd(results).score > 0.0
      assert [%{kind: "card"} | _] = hd(results).matches
    end

    test "a comment is enough to surface its card", ctx do
      assert {:ok, results} = Search.search(ctx.owner, "staging rollback blocked approvals")
      assert hd(results).card.id == ctx.deploy.id
      # And the reason is shown: the match is the comment, not the card body.
      assert Enum.any?(hd(results).matches, &(&1.kind == "comment"))
    end

    test "an empty query searches for nothing", ctx do
      assert {:ok, []} = Search.search(ctx.owner, "   ")
    end

    test "results roll up: one entry per card however many chunks matched", ctx do
      {:ok, _} = Boards.add_comment(ctx.deploy, "rollback rollback rollback")
      index(ctx.deploy)

      assert {:ok, results} = Search.search(ctx.owner, "rollback")
      assert Enum.count(results, &(&1.card.id == ctx.deploy.id)) == 1
      assert length(Enum.find(results, &(&1.card.id == ctx.deploy.id)).matches) >= 2
    end

    test "archived cards are left out unless asked for", ctx do
      {:ok, _} = Boards.archive_card(ctx.billing)
      index(ctx.billing)

      assert {:ok, results} = Search.search(ctx.owner, "invoice rounding refunds")
      refute Enum.any?(results, &(&1.card.id == ctx.billing.id))

      assert {:ok, results} = Search.search(ctx.owner, "invoice rounding refunds", archived: true)
      assert Enum.any?(results, &(&1.card.id == ctx.billing.id))
    end

    test "a board filter narrows to that board's tree", ctx do
      other = board_fixture(%{"name" => "Elsewhere"}, owner: ctx.owner)
      stray = card_fixture(hd(other.columns), %{"title" => "Invoice rounding elsewhere"})
      index(stray)

      assert {:ok, results} = Search.search(ctx.owner, "invoice rounding", board_id: other.id)
      assert Enum.map(results, & &1.card.id) == [stray.id]
    end

    test "the limit caps how many cards come back", ctx do
      assert {:ok, results} = Search.search(ctx.owner, "rollback invoice markers", limit: 1)
      assert length(results) == 1
    end
  end

  describe "permissions" do
    setup ctx do
      stranger = user_fixture("stranger@example.com")
      card = card_fixture(ctx.column, %{"title" => "Confidential salary review"})
      index(card)
      %{stranger: stranger, card: card}
    end

    test "a stranger finds nothing on a board they cannot read", ctx do
      assert {:ok, []} = Search.search(ctx.stranger, "confidential salary review")
    end

    test "nobody at all finds nothing" do
      assert {:ok, []} = Search.search(nil, "confidential salary review")
    end

    test "a board reader finds it", ctx do
      {:ok, _} = Access.grant(ctx.board, ctx.stranger, "read", ctx.owner)
      assert {:ok, [result]} = Search.search(ctx.stranger, "confidential salary review")
      assert result.card.id == ctx.card.id
    end

    test "a card grant reaches that card and no other on the board", ctx do
      neighbour = card_fixture(ctx.column, %{"title" => "Confidential bonus pool"})
      index(neighbour)

      {:ok, _} = Access.grant(ctx.card, ctx.stranger, "read", ctx.owner)

      assert {:ok, results} = Search.search(ctx.stranger, "confidential")
      assert Enum.map(results, & &1.card.id) == [ctx.card.id]
    end

    test "a view-only grant reaches nothing: a search has no view to apply", ctx do
      {:ok, view} =
        Boards.create_saved_view(ctx.board, %{
          "name" => "Just the open ones",
          "config" => %{"mode" => "board"}
        })

      {:ok, _} = Access.grant(view, ctx.stranger, "read", ctx.owner)

      # The board is listed for them, because the view is reachable…
      assert ctx.board.id in Enum.map(Access.list_boards(ctx.stranger), & &1.id)
      # …but it contributes nothing to the search scope.
      assert ctx.board.id not in Access.readable_scope(ctx.stranger).board_ids
      assert {:ok, []} = Search.search(ctx.stranger, "confidential salary review")
    end

    test "moving a card to another board moves who can search it up", ctx do
      elsewhere = board_fixture(%{"name" => "Elsewhere"}, owner: ctx.owner)
      {:ok, _} = Access.grant(elsewhere, ctx.stranger, "read", ctx.owner)

      # Before the move, the stranger can read Elsewhere but not the card.
      assert {:ok, []} = Search.search(ctx.stranger, "confidential salary review")

      {:ok, _} = Boards.move_card_to_board(ctx.card, hd(elsewhere.columns))

      # The board recorded against its chunks is corrected inline, without
      # waiting for the queue to catch the text up.
      assert {:ok, [result]} = Search.search(ctx.stranger, "confidential salary review")
      assert result.card.id == ctx.card.id
      assert {:ok, []} = Search.search(ctx.owner, "confidential", board_id: ctx.board.id)
    end
  end

  describe "stats" do
    test "counts what is indexed", ctx do
      assert Search.stats().chunks == 0
      refute Search.available?()

      card = card_fixture(ctx.column, %{"title" => "Something"})
      index(card)

      assert %{chunks: 1, cards: 1} = Search.stats()
      assert Search.available?()
    end
  end
end
