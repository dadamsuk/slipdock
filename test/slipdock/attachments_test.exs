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
      Boards.add_attachment(card, %{filename: "../notes.TXT", content_type: "text/plain"}, src)

    assert a.filename == "notes.TXT"
    assert a.size == byte_size("hello attachment")
    assert a.key =~ ~r"^#{card.id}/[0-9a-f-]{36}\.txt$"
    assert File.read!(Boards.attachment_path(a)) == "hello attachment"
    assert String.starts_with?(Boards.attachment_path(a), Boards.uploads_dir())
    assert Boards.attachment_url(a) == "/attachments/#{a.id}/notes.TXT"
    assert [%Attachment{id: id}] = Boards.get_card!(card.id).attachments
    assert id == a.id
    assert [%{kind: "attachment"} | _] = Boards.list_activities(card.board_id)
  end

  test "rejects an empty file and an oversized one", %{card: card} do
    empty = Path.join(System.tmp_dir!(), "kanban-empty-#{System.unique_integer([:positive])}")
    File.write!(empty, "")

    assert {:error, cs} =
             Boards.add_attachment(card, %{filename: "e.bin", content_type: "x/y"}, empty)

    assert "must be greater than 0" in errors_on(cs).size

    assert {:error, cs} =
             Boards.add_attachment(
               card,
               %{filename: "big.bin", content_type: "x/y", size: Attachment.max_size() + 1},
               empty
             )

    assert errors_on(cs).size != []
    refute File.exists?(Path.join(Boards.uploads_dir(), Integer.to_string(card.id)))
  end

  test "deleting an attachment, the card or the board removes the files", %{
    board: board,
    card: card,
    src: src
  } do
    {:ok, a} = Boards.add_attachment(card, %{filename: "a.txt", content_type: "text/plain"}, src)
    {:ok, b} = Boards.add_attachment(card, %{filename: "b.txt", content_type: "text/plain"}, src)
    {:ok, _} = Boards.delete_attachment(a)
    refute File.exists?(Boards.attachment_path(a))
    assert File.exists?(Boards.attachment_path(b))
    assert [%{id: bid}] = Boards.get_card!(card.id).attachments
    assert bid == b.id

    {:ok, _} = Boards.delete_card(Boards.get_card!(card.id))
    refute File.exists?(Boards.attachment_path(b))
    refute File.exists?(Path.dirname(Boards.attachment_path(b)))

    [col | _] = board.columns
    other = card_fixture(col)
    {:ok, c} = Boards.add_attachment(other, %{filename: "c.txt", content_type: "text/plain"}, src)
    {:ok, _} = Boards.delete_board(Boards.get_board!(board.id))
    refute File.exists?(Boards.attachment_path(c))
  end

  test "images are recognised by content type" do
    assert Attachment.image?(%Attachment{content_type: "image/png"})
    refute Attachment.image?(%Attachment{content_type: "image/svg+xml"})
    assert Attachment.kind(%Attachment{content_type: "application/pdf"}) == :pdf
  end
end
