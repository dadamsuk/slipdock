defmodule Slipdock.AttachmentsTest do
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures
  alias Slipdock.Boards
  alias Slipdock.Boards.Attachment

  setup do
    Slipdock.TestConfig.own_uploads_dir()
    board = board_fixture()
    [col | _] = board.columns
    card = card_fixture(col)
    src = Path.join(System.tmp_dir!(), "kanban-attach-#{System.unique_integer([:positive])}.txt")
    File.write!(src, "hello attachment")
    on_exit(fn -> File.rm(src) end)
    %{board: board, card: card, src: src}
  end

  test "attaches a file, copying it into the uploads directory", %{card: card, src: src} do
    {:ok, a} =
      Boards.Attachments.add_attachment(
        card,
        %{filename: "../notes.TXT", content_type: "text/plain"},
        src
      )

    assert a.filename == "notes.TXT"
    assert a.size == byte_size("hello attachment")
    assert a.key =~ ~r"^#{card.id}/[0-9a-f-]{36}\.txt$"
    assert File.read!(Boards.Attachments.attachment_path(a)) == "hello attachment"

    assert String.starts_with?(
             Boards.Attachments.attachment_path(a),
             Boards.Attachments.uploads_dir()
           )

    assert Boards.Attachments.attachment_url(a) == "/attachments/#{a.id}/notes.TXT"
    assert [%Attachment{id: id}] = Boards.Cards.get_card!(card.id).attachments
    assert id == a.id
    assert [%{kind: "attachment"} | _] = Boards.ActivityLog.list_activities(card.board_id)
  end

  describe "sha256 (#1015)" do
    defp sha(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

    defp forget_hash(a) do
      Repo.update_all(from(x in Attachment, where: x.id == ^a.id), set: [sha256: nil])
      Repo.get!(Attachment, a.id)
    end

    test "is recorded from the file as stored", %{card: card, src: src} do
      {:ok, a} =
        Boards.Attachments.add_attachment(
          card,
          %{filename: "n.txt", content_type: "text/plain"},
          src
        )

      assert a.sha256 == sha("hello attachment")

      assert Repo.get!(Attachment, a.id).sha256 ==
               sha(File.read!(Boards.Attachments.attachment_path(a)))
    end

    test "a wiki page's file gets one too", %{board: board} do
      page = page_fixture(board, %{"title" => "Hashed"})
      src = Path.join(System.tmp_dir!(), "kanban-page-#{System.unique_integer([:positive])}")
      File.write!(src, "page bytes")
      on_exit(fn -> File.rm(src) end)

      {:ok, a} =
        Slipdock.Wiki.add_attachment(page, %{filename: "p.txt", content_type: "text/plain"}, src)

      assert a.sha256 == sha("page bytes")
    end

    test "file_sha256 reads a file bigger than one chunk", %{src: src} do
      big = :binary.copy("x", 1_048_576 * 2 + 7)
      File.write!(src, big)
      assert Attachment.file_sha256(src) == {sha(big), byte_size(big)}
    end

    test "the backfill hashes old rows, skips missing files and keeps existing hashes", %{
      card: card,
      src: src
    } do
      {:ok, old} =
        Boards.Attachments.add_attachment(
          card,
          %{filename: "o.txt", content_type: "text/plain"},
          src
        )

      {:ok, gone} =
        Boards.Attachments.add_attachment(
          card,
          %{filename: "g.txt", content_type: "text/plain"},
          src
        )

      {:ok, kept} =
        Boards.Attachments.add_attachment(
          card,
          %{filename: "k.txt", content_type: "text/plain"},
          src
        )

      old = forget_hash(old)
      gone = forget_hash(gone)
      File.rm!(Boards.Attachments.attachment_path(gone))
      # A stored hash is never rewritten, even if it no longer matches the
      # disk: the backfill only fills gaps.
      Repo.update_all(from(x in Attachment, where: x.id == ^kept.id), set: [sha256: "keep"])

      assert old.sha256 == nil
      assert Boards.Attachments.backfill_attachment_hashes() == 1
      assert Repo.get!(Attachment, old.id).sha256 == sha("hello attachment")
      assert Repo.get!(Attachment, gone.id).sha256 == nil
      assert Repo.get!(Attachment, kept.id).sha256 == "keep"

      # Safe to run again: nothing left it can fill.
      assert Boards.Attachments.backfill_attachment_hashes() == 0
    end
  end

  test "rejects an empty file and an oversized one", %{card: card} do
    empty = Path.join(System.tmp_dir!(), "kanban-empty-#{System.unique_integer([:positive])}")
    File.write!(empty, "")

    assert {:error, cs} =
             Boards.Attachments.add_attachment(
               card,
               %{filename: "e.bin", content_type: "x/y"},
               empty
             )

    assert "must be greater than 0" in errors_on(cs).size

    assert {:error, cs} =
             Boards.Attachments.add_attachment(
               card,
               %{filename: "big.bin", content_type: "x/y", size: Attachment.max_size() + 1},
               empty
             )

    assert errors_on(cs).size != []
    refute File.exists?(Path.join(Boards.Attachments.uploads_dir(), Integer.to_string(card.id)))
  end

  test "deleting an attachment, the card or the board removes the files", %{
    board: board,
    card: card,
    src: src
  } do
    {:ok, a} =
      Boards.Attachments.add_attachment(
        card,
        %{filename: "a.txt", content_type: "text/plain"},
        src
      )

    {:ok, b} =
      Boards.Attachments.add_attachment(
        card,
        %{filename: "b.txt", content_type: "text/plain"},
        src
      )

    {:ok, _} = Boards.Attachments.delete_attachment(a)
    refute File.exists?(Boards.Attachments.attachment_path(a))
    assert File.exists?(Boards.Attachments.attachment_path(b))
    assert [%{id: bid}] = Boards.Cards.get_card!(card.id).attachments
    assert bid == b.id

    {:ok, _} = Boards.Cards.delete_card(Boards.Cards.get_card!(card.id))
    refute File.exists?(Boards.Attachments.attachment_path(b))
    refute File.exists?(Path.dirname(Boards.Attachments.attachment_path(b)))

    [col | _] = board.columns
    other = card_fixture(col)

    {:ok, c} =
      Boards.Attachments.add_attachment(
        other,
        %{filename: "c.txt", content_type: "text/plain"},
        src
      )

    {:ok, _} = Boards.delete_board(Boards.get_board!(board.id))
    refute File.exists?(Boards.Attachments.attachment_path(c))
  end

  test "images are recognised by content type" do
    assert Attachment.image?(%Attachment{content_type: "image/png"})
    refute Attachment.image?(%Attachment{content_type: "image/svg+xml"})
    assert Attachment.kind(%Attachment{content_type: "application/pdf"}) == :pdf
  end

  test "an image pasted or dropped in may be up to 50 MB; a card front shows one of 10 MB at most" do
    assert Attachment.image_max_size() == 50_000_000
    assert Attachment.thumbnail_max() == 10 * 1024 * 1024

    Slipdock.TestConfig.put(:image_max_size, 1234)
    assert Attachment.image_max_size() == 1234
  end
end
