defmodule Slipdock.OCRTest do
  @moduledoc """
  The queue: what gets read, what comes of it, and how it recovers. Search
  over the result is in `Slipdock.OCRSearchTest`.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Boards, OCR, Repo, TestConfig, Wiki}
  alias Slipdock.OCR.Text
  alias Slipdock.Wiki.{Files, WikiFile}

  setup do
    TestConfig.own_uploads_dir()
    owner = user_fixture("ocr-owner@example.com")
    board = board_fixture(%{"name" => "Scans", "code" => "ocrq1"}, owner: owner)
    card = card_fixture(hd(board.columns), %{"title" => "Paperwork"})
    source = Path.join(System.tmp_dir!(), "ocr-#{System.unique_integer([:positive])}")
    File.write!(source, <<0x89, "PNG", 0, 0, 0, 0>>)
    on_exit(fn -> File.rm(source) end)

    %{owner: owner, board: board, card: card, source: source}
  end

  defp reads(fun), do: TestConfig.put(:ocr, run: fn program, args -> fun.(program, args) end)
  defp reads_as(text), do: reads(fn _, _ -> {text, 0} end)

  defp attach(card, source, name \\ "scan.png", type \\ "image/png") do
    {:ok, a} = Boards.add_attachment(card, %{filename: name, content_type: type}, source)
    a
  end

  defp row(attachment), do: OCR.text_of(attachment)

  # The files other tests leave are in other sandboxes, so the queue is ours.
  defp drain do
    case OCR.run_next() do
      :ok -> drain()
      other -> other
    end
  end

  describe "an upload" do
    test "of an image or a PDF is queued", %{card: card, source: source} do
      assert %Text{status: "queued", attempts: 0} = card |> attach(source) |> row()

      assert %Text{status: "queued"} =
               card |> attach(source, "a.pdf", "application/pdf") |> row()
    end

    test "of anything else isn't", %{card: card, source: source} do
      assert card |> attach(source, "notes.txt", "text/plain") |> row() == nil
    end

    test "to a wiki page is queued too", %{board: board, owner: owner, source: source} do
      page = page_fixture(board, %{"title" => "Runbook"}, user: owner)

      {:ok, a} =
        Wiki.add_attachment(page, %{filename: "s.png", content_type: "image/png"}, source)

      assert %Text{status: "queued"} = row(a)
    end
  end

  describe "reading" do
    test "keeps the text, and tells the card's board", %{card: card, source: source} do
      Boards.subscribe(card.board_id)
      a = attach(card, source)
      reads_as("Invoice 42")

      assert OCR.run_next() == :ok

      assert %Text{status: "done", text: "Invoice 42", pages: 1, attempts: 1, error: nil} = row(a)
      assert_received {:board_changed, _}
      assert drain() == :none
    end

    test "a failure keeps the reason", %{card: card, source: source} do
      a = attach(card, source)
      reads(fn _, _ -> {"", 1} end)

      assert OCR.run_next() == :ok
      assert %Text{status: "failed", error: "the image can't be read", text: nil} = row(a)
    end

    test "a program that raises fails the file, not the worker", %{card: card, source: source} do
      a = attach(card, source)
      reads(fn _, _ -> raise "boom" end)

      assert OCR.run_next() == :ok
      assert %Text{status: "failed", error: "boom"} = row(a)
    end

    test "a file gone from disk fails with a reason", %{card: card, source: source} do
      a = attach(card, source)
      File.rm!(Boards.attachment_path(a))
      reads_as("never")

      OCR.run_next()
      assert %Text{status: "failed", error: "the file is not on disk"} = row(a)
    end

    test "goes oldest first", %{card: card, source: source} do
      first = attach(card, source)
      second = attach(card, source)
      reads_as("words")

      OCR.run_next()
      assert row(first).status == "done"
      assert row(second).status == "queued"
    end

    test "a file deleted in the queue is simply gone", %{card: card, source: source} do
      a = attach(card, source)
      {:ok, _} = Boards.delete_attachment(a)
      reads_as("never")

      assert OCR.run_next() == :none
      assert Repo.aggregate(from(t in Text, where: t.attachment_id == ^a.id), :count) == 0
    end

    test "waits on a machine without the programs", %{card: card, source: source} do
      a = attach(card, source)
      TestConfig.put(:ocr, programs: ["no-such-program-here"])

      assert OCR.run_next() == :unavailable
      assert row(a).status == "queued"
      assert OCR.sweep() == :ok
      assert row(a).status == "queued"
    end
  end

  describe "retry/1" do
    test "reads a failed file again", %{card: card, source: source} do
      a = attach(card, source)
      reads(fn _, _ -> {"", 1} end)
      OCR.run_next()

      reads_as("second time lucky")
      assert {:ok, %Text{status: "queued", error: nil, attempts: 0}} = OCR.retry(a)
      OCR.run_next()
      assert %Text{status: "done", text: "second time lucky"} = row(a)
    end

    test "refuses a file that isn't read, and one being read", %{card: card, source: source} do
      assert {:error, :not_readable} =
               card |> attach(source, "n.txt", "text/plain") |> OCR.retry()

      a = attach(card, source)
      row(a) |> Ecto.Changeset.change(status: "running") |> Repo.update!()
      assert {:error, :running} = OCR.retry(a)
      assert OCR.describe(:running) =~ "already"
      assert OCR.describe(:not_readable) =~ "PDFs and images"
    end

    test "queues a file from before there was a row", %{card: card, source: source} do
      a = attach(card, source)
      Repo.delete!(row(a))

      assert {:ok, %Text{status: "queued"}} = OCR.retry(a)
    end
  end

  describe "wiki files" do
    defp wiki_file(board, owner, source, name \\ "scan.pdf") do
      {:ok, file} = Files.create(board, %{name: name}, source, owner)
      file
    end

    defp file_row(%WikiFile{id: id}), do: Repo.get_by(Text, wiki_file_id: id)

    test "are queued and read", %{board: board, owner: owner, source: source} do
      file = wiki_file(board, owner, source)
      reads(fn "pdftotext", _ -> {"A vault PDF with quite enough words on the page\f", 0} end)

      OCR.run_next()
      assert %Text{status: "done", text: "A vault PDF" <> _} = file_row(file)
    end

    test "new bytes throw away what was read from the old ones", ctx do
      file = wiki_file(ctx.board, ctx.owner, ctx.source)
      reads(fn "pdftotext", _ -> {"The first version of this document's text\f", 0} end)
      OCR.run_next()

      {:ok, file} = Files.replace(file, %{}, ctx.source)

      assert %Text{status: "queued", text: nil} = file_row(file)
    end

    test "bytes replaced mid-read aren't overwritten by the old result", ctx do
      file = wiki_file(ctx.board, ctx.owner, ctx.source)

      reads(fn "pdftotext", _ ->
        {:ok, _} = Files.replace(file, %{}, ctx.source)
        {"The old version's text, read too late to count\f", 0}
      end)

      OCR.run_next()
      assert %Text{status: "queued", text: nil} = file_row(file)
    end

    test "renamed into something that isn't read, the row goes", ctx do
      file = wiki_file(ctx.board, ctx.owner, ctx.source)
      {:ok, file} = Files.replace(file, %{name: "notes.txt"}, ctx.source)

      assert file_row(file) == nil
    end

    test "deleting the file deletes the row", ctx do
      file = wiki_file(ctx.board, ctx.owner, ctx.source)
      {:ok, _} = Files.delete(file)
      assert file_row(file) == nil
    end
  end

  describe "sweep/0" do
    setup do
      TestConfig.put(:ocr, run: fn _, _ -> {"words", 0} end)
    end

    test "queues what was uploaded before there was a queue", ctx do
      a = attach(ctx.card, ctx.source)
      pdf = attach(ctx.card, ctx.source, "x.PDF", "application/octet-stream")
      text = attach(ctx.card, ctx.source, "x.txt", "text/plain")
      {:ok, file} = Files.create(ctx.board, %{name: "f.png"}, ctx.source, ctx.owner)
      Repo.delete_all(Text)

      OCR.sweep()

      assert row(a).status == "queued"
      assert row(pdf).status == "queued"
      assert row(text) == nil
      assert Repo.get_by(Text, wiki_file_id: file.id).status == "queued"
    end

    test "leaves alone what is done, and archived wiki files", ctx do
      a = attach(ctx.card, ctx.source)
      OCR.run_next()
      {:ok, file} = Files.create(ctx.board, %{name: "f.png"}, ctx.source, ctx.owner)
      {:ok, _} = Files.archive(file)
      Repo.delete_all(from(t in Text, where: t.wiki_file_id == ^file.id))

      OCR.sweep()

      assert row(a).status == "done"
      assert Repo.get_by(Text, wiki_file_id: file.id) == nil
    end

    test "takes back a job a restart cut off, and gives up on one that keeps dying", ctx do
      a = attach(ctx.card, ctx.source)
      b = attach(ctx.card, ctx.source)
      now = DateTime.utc_now(:second)
      old = DateTime.add(now, -3 * 60 * 60, :second)

      for {x, attempts} <- [{a, 1}, {b, 3}] do
        row(x)
        |> Ecto.Changeset.change(status: "running", started_at: old, attempts: attempts)
        |> Repo.update!()
      end

      OCR.sweep(now)

      assert row(a).status == "queued"
      assert %Text{status: "failed", error: "reading it never finished"} = row(b)
    end

    test "leaves a job that is only just running", ctx do
      a = attach(ctx.card, ctx.source)
      now = DateTime.utc_now(:second)
      row(a) |> Ecto.Changeset.change(status: "running", started_at: now) |> Repo.update!()

      OCR.sweep(now)
      assert row(a).status == "running"
    end
  end

  test "stats/0 counts the queue by status", %{card: card, source: source} do
    attach(card, source)
    attach(card, source)
    reads_as("words")
    OCR.run_next()

    assert %{"done" => 1, "queued" => 1} = OCR.stats()
  end
end
