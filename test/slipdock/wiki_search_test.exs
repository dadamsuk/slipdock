defmodule Slipdock.WikiSearchTest do
  @moduledoc """
  Pages in the semantic index: chunked by heading, ranked against cards in one
  list, and never visible to somebody who could not open the page.

  The embedding model is stubbed (see `Slipdock.AIStub`), so what is asserted
  here is the chunking, the permission filtering and the roll-up — not the
  quality of anybody's vectors.
  """
  # Sync: drives `Slipdock.Search.Indexer`, one queue for the node in a process
  # started at boot, so the AI stub has to be shared (see CONTRIBUTING.md).
  use Slipdock.DataCase, async: false

  import Slipdock.Fixtures

  alias Slipdock.{Access, Search, Wiki}
  alias Slipdock.Search.{Chunk, Embedding, Indexer}

  setup do
    Slipdock.AIStub.stub_embeddings()
    Slipdock.AIStub.share()

    user = user_fixture()
    board = board_fixture(%{"name" => "Indexed", "code" => "indexed"}, owner: user)
    %{user: user, board: board, column: hd(board.columns)}
  end

  defp index(page), do: {:ok, _} = Search.index_page(page.id)

  describe "chunking" do
    test "a short page is one chunk", %{board: board, user: user} do
      {:ok, page} =
        Wiki.create_page(board, %{"title" => "Retry policy", "body" => "We retry three times."},
          user: user
        )

      assert [%{kind: "page", section: "", page_id: id}] =
               Chunk.for_page(Slipdock.Repo.preload(page, :board))

      assert id == page.id
    end

    test "a long page is one chunk per heading, each carrying its context", %{
      board: board,
      user: user
    } do
      body =
        """
        Everything about how we deploy, at length.
        #{String.duplicate("Preamble words. ", 60)}

        ## Rollback

        #{String.duplicate("Stop the queue and drain it. ", 30)}

        ## Log

        #{String.duplicate("Dated notes go here. ", 30)}
        """

      {:ok, page} = Wiki.create_page(board, %{"title" => "Runbook", "body" => body}, user: user)
      chunks = Chunk.for_page(Slipdock.Repo.preload(page, :board))

      sections = Enum.map(chunks, & &1.section)
      assert "Rollback" in sections
      assert "Log" in sections
      # The words before the first heading are often the summary of the whole
      # thing, and would otherwise never be embedded at all.
      assert "" in sections

      assert Enum.all?(chunks, &(&1.body =~ "Board: Indexed"))
      assert Enum.all?(chunks, &(&1.body =~ "Runbook"))
    end

    test "a draft and an archived page are not indexed", %{board: board, user: user} do
      {:ok, draft} =
        Wiki.create_page(board, %{"title" => "Half", "status" => "draft", "body" => "secret"},
          user: user
        )

      {:ok, page} = Wiki.create_page(board, %{"title" => "Open", "body" => "words"}, user: user)
      {:ok, archived} = Wiki.archive_page(page)

      assert Chunk.for_page(Slipdock.Repo.preload(draft, :board)) == []
      assert Chunk.for_page(Slipdock.Repo.preload(archived, :board)) == []
    end

    test "a query block embeds as nothing and a link embeds as its words", %{
      board: board,
      user: user
    } do
      body = "See [[Retry policy]].\n\n```kanban\nview: count\nfilter: flag=blocked\n```\n"
      {:ok, page} = Wiki.create_page(board, %{"title" => "Digest", "body" => body}, user: user)

      [chunk] = Chunk.for_page(Slipdock.Repo.preload(page, :board))
      assert chunk.body =~ "See Retry policy."
      refute chunk.body =~ "flag=blocked"
    end
  end

  describe "indexing" do
    test "editing one section re-embeds one section", %{board: board, user: user} do
      body = """
      Intro.
      #{String.duplicate("Long enough to be split by heading. ", 40)}

      ## One

      #{String.duplicate("First section words. ", 30)}

      ## Two

      #{String.duplicate("Second section words. ", 30)}
      """

      {:ok, page} = Wiki.create_page(board, %{"title" => "Runbook", "body" => body}, user: user)
      {:ok, first} = Search.index_page(page.id)
      assert first.embedded > 1

      {:ok, page} = Wiki.replace_section(page, "Two", "## Two\n\nRewritten entirely.", user: user)
      {:ok, second} = Search.index_page(page.id)

      assert second.embedded == 1
      assert second.unchanged >= 1
    end

    test "archiving takes a page out of the index at once", %{board: board, user: user} do
      {:ok, page} = Wiki.create_page(board, %{"title" => "Open", "body" => "words"}, user: user)
      index(page)
      assert Search.stats().pages == 1

      {:ok, _} = Wiki.archive_page(page)
      assert Search.stats().pages == 0
    end

    test "a page saved through the context is queued", %{board: board, user: user} do
      {:ok, _} = Wiki.create_page(board, %{"title" => "Queued", "body" => "words"}, user: user)
      assert Indexer.pending() > 0
      {:ok, _} = Indexer.flush()
      assert Search.stats().pages == 1
    end
  end

  describe "searching" do
    setup %{board: board, column: column, user: user} do
      card = card_fixture(column, %{"title" => "Refund rounding is wrong"})
      {:ok, _} = Slipdock.Boards.add_comment(card, "finance want the rounding fixed")

      {:ok, page} =
        Wiki.create_page(
          board,
          %{
            "title" => "Refund policy",
            "summary" => "How refunds are calculated",
            "body" => "Refunds round to the nearest penny, and we decided that in March."
          },
          user: user
        )

      {:ok, _} = Search.index_card(card.id)
      index(page)

      %{card: card, page: page}
    end

    test "a page comes back as its own kind of result", %{user: user, page: page} do
      {:ok, results} = Search.search(user, "refund rounding")

      page_result = Enum.find(results, &(&1.kind == "page"))
      assert page_result
      assert page_result.page.id == page.id
      assert page_result.subject.id == page.id
      assert is_nil(page_result.card)

      card_result = Enum.find(results, &(&1.kind == "card"))
      assert card_result
      assert card_result.page == nil
    end

    test "kind: narrows to one or the other", %{user: user} do
      {:ok, cards} = Search.search(user, "refund rounding", kind: :card)
      {:ok, pages} = Search.search(user, "refund rounding", kind: :page)

      assert Enum.all?(cards, &(&1.kind == "card"))
      assert Enum.all?(pages, &(&1.kind == "page"))
      assert pages != []
    end

    test "a page a reader cannot see does not come back", %{board: board, user: user} do
      outsider = user_fixture("search.outsider@example.com")
      assert {:ok, []} = Search.search(outsider, "refund rounding")

      reader = user_fixture("search.reader@example.com")
      {:ok, _} = Access.grant(board, reader, "read", user)
      {:ok, results} = Search.search(reader, "refund rounding")
      assert Enum.any?(results, &(&1.kind == "page"))
    end

    test "a page shared on its own reaches its reader without the board", %{
      user: user,
      page: page
    } do
      outsider = user_fixture("search.shared@example.com")
      {:ok, _} = Access.grant(page, outsider, "read", user)

      {:ok, results} = Search.search(outsider, "refund rounding")
      assert [%{kind: "page", page: %{id: id}}] = results
      assert id == page.id
    end

    test "a page made a draft after it was indexed is filtered on the way out", %{
      user: user,
      page: page
    } do
      # The index is not re-read on a permission change, so the reader's own
      # permission is what decides — belt as well as braces.
      {:ok, _} = Slipdock.Repo.update(Ecto.Changeset.change(page, status: "draft"))

      reader = user_fixture("search.draft@example.com")
      {:ok, _} = Access.grant(Wiki.board_of(page), reader, "read", user)

      {:ok, results} = Search.search(reader, "refund rounding")
      refute Enum.any?(results, &(&1.kind == "page"))
    end

    test "stats count pages as well as cards", %{} do
      stats = Search.stats()
      assert stats.pages == 1
      assert stats.cards >= 1
      assert stats.chunks > 1
    end

    test "a chunk knows it came from a page", %{} do
      assert Embedding.page?("page")
      assert Embedding.page?("page_section")
      refute Embedding.page?("card")
      assert Embedding.label("page_section") == "page section"
    end
  end
end
