defmodule Slipdock.OCRSearchTest do
  @moduledoc """
  The point of #1527: words that only exist inside an uploaded file are found
  by search, by the people who may read it, and stop being found when the file
  goes.
  """
  # Sync, as `Slipdock.SearchTest`: the indexer is a process started at boot.
  use Slipdock.DataCase, async: false

  import Slipdock.Fixtures

  alias Slipdock.{Boards, OCR, Repo, Search, TestConfig, Wiki}
  alias Slipdock.Search.{Chunk, Embedding, Indexer}
  alias Slipdock.Wiki.Files

  @words "quarterly zanzibar shipment manifest reconciliation"

  setup do
    TestConfig.own_uploads_dir()
    Slipdock.AIStub.share()
    Slipdock.AIStub.stub_embeddings()
    Indexer.reset()
    TestConfig.put(:ocr, run: fn _, _ -> {@words, 0} end)

    owner = user_fixture("ocr-search@example.com")
    board = board_fixture(%{"name" => "Scans", "code" => "ocrs1"}, owner: owner)
    card = card_fixture(hd(board.columns), %{"title" => "Paperwork"})
    source = Path.join(System.tmp_dir!(), "ocrs-#{System.unique_integer([:positive])}")
    File.write!(source, <<0x89, "PNG", 0, 0, 0, 0>>)
    on_exit(fn -> File.rm(source) end)

    %{owner: owner, board: board, card: card, source: source}
  end

  defp found(user, opts \\ []) do
    {:ok, results} = Search.search(user, "zanzibar shipment manifest", opts)
    results
  end

  defp read_and_index do
    assert OCR.run_next() == :ok
    {:ok, _} = Indexer.flush()
  end

  defp attach(card, source) do
    {:ok, a} =
      Boards.add_attachment(card, %{filename: "scan.png", content_type: "image/png"}, source)

    a
  end

  test "text read from a card's attachment finds the card", ctx do
    a = attach(ctx.card, ctx.source)
    read_and_index()

    assert [%{kind: "card", card: card, matches: [match | _]}] =
             found(ctx.owner, kind: :card)

    assert card.id == ctx.card.id
    assert match.kind == "document"
    assert match.source_id == a.id
    assert match.body =~ "Text of the file “scan.png” on card “Paperwork”"
  end

  test "nothing is indexed until it has been read", ctx do
    attach(ctx.card, ctx.source)
    {:ok, _} = Search.index_card(ctx.card.id)

    assert found(ctx.owner) == []
  end

  test "someone who can't read the board doesn't find it", ctx do
    attach(ctx.card, ctx.source)
    read_and_index()

    assert found(user_fixture("ocr-stranger@example.com")) == []
  end

  test "deleting the attachment takes its text out of search", ctx do
    a = attach(ctx.card, ctx.source)
    read_and_index()

    {:ok, _} = Boards.delete_attachment(a)
    {:ok, _} = Indexer.flush()

    assert Repo.aggregate(from(e in Embedding, where: e.kind == "document"), :count) == 0
  end

  test "text read from a page's attachment finds the page", ctx do
    page = page_fixture(ctx.board, %{"title" => "Runbook"}, user: ctx.owner)

    {:ok, a} =
      Wiki.add_attachment(page, %{filename: "s.png", content_type: "image/png"}, ctx.source)

    read_and_index()

    assert [%{kind: "page", page: found_page, matches: [match | _]}] =
             found(ctx.owner, kind: :page)

    assert found_page.id == page.id
    assert match.kind == "page_document"
    assert match.source_id == a.id

    {:ok, _} = Boards.delete_attachment(a)
    {:ok, _} = Indexer.flush()
    assert found(ctx.owner, kind: :page) == []
  end

  test "a draft page's attachments stay out of search", ctx do
    page = page_fixture(ctx.board, %{"title" => "Draft", "status" => "draft"}, user: ctx.owner)

    {:ok, _} =
      Wiki.add_attachment(page, %{filename: "s.png", content_type: "image/png"}, ctx.source)

    read_and_index()

    assert found(ctx.owner) == []
  end

  describe "a wiki file" do
    setup ctx do
      {:ok, file} = Files.create(ctx.board, %{name: "scan.png"}, ctx.source, ctx.owner)
      read_and_index()
      %{wiki_file: file}
    end

    test "is a result of its own", ctx do
      assert [%{kind: "file", file: file, subject: subject, card: nil, page: nil}] =
               found(ctx.owner)

      assert file.id == ctx.wiki_file.id
      assert subject.board.id == ctx.board.id
    end

    test "only when asked for files or everything", ctx do
      assert [_] = found(ctx.owner, kind: :file)
      assert found(ctx.owner, kind: :card) == []
      assert found(ctx.owner, kind: :page) == []
    end

    test "is not found by a stranger", ctx do
      assert found(ctx.owner) != []
      assert found(user_fixture("ocr-stranger2@example.com")) == []
    end

    test "archiving takes it out, and deleting removes the chunks", ctx do
      {:ok, archived} = Files.archive(ctx.wiki_file)
      {:ok, _} = Indexer.flush()
      assert found(ctx.owner) == []

      {:ok, _} = Files.delete(archived)
      assert Repo.aggregate(from(e in Embedding, where: e.kind == "file_document"), :count) == 0
    end

    test "renaming re-embeds it under the new name", ctx do
      {:ok, _} = Files.move(ctx.wiki_file, %{name: "renamed.png"})
      {:ok, _} = Indexer.flush()

      assert [%{matches: [match | _]}] = found(ctx.owner)
      assert match.body =~ "“renamed.png”"
    end

    test "a reindex walks it", ctx do
      assert ctx.wiki_file.id in Search.all_file_ids()

      assert {:ok, %{unchanged: 1}} =
               ctx.wiki_file.id |> List.wrap() |> Search.load_files() |> Search.index_files()
    end
  end

  describe "chunks" do
    test "a long document is split into numbered parts", ctx do
      long =
        Enum.map_join(1..200, "\n", &"Line #{&1} of a long scanned document, with some words.")

      TestConfig.put(:ocr, run: fn _, _ -> {long, 0} end)
      a = attach(ctx.card, ctx.source)
      OCR.run_next()

      chunks = ctx.card.id |> List.wrap() |> Search.load_cards() |> hd() |> Chunk.for_card()
      documents = Enum.filter(chunks, &(&1.kind == "document"))

      assert length(documents) > 1
      assert Enum.all?(documents, &(&1.source_id == a.id))
      assert hd(documents).section == "part 1"
      assert hd(documents).body =~ "part 1 of #{length(documents)}:"
    end

    test "a file with no words adds none", ctx do
      TestConfig.put(:ocr, run: fn _, _ -> {"  ", 0} end)
      attach(ctx.card, ctx.source)
      OCR.run_next()

      chunks = ctx.card.id |> List.wrap() |> Search.load_cards() |> hd() |> Chunk.for_card()
      refute Enum.any?(chunks, &(&1.kind == "document"))
    end
  end
end
