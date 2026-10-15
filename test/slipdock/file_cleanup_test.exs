defmodule Slipdock.FileCleanupTest do
  @moduledoc """
  Deleting something deletes the files on disk that went with it — not only
  the rows. The database cascades take a card's subcards, a list's cards and
  a page's images by themselves; the bytes are left behind unless the delete
  gathers their keys first. Each case here also keeps a file that must stay.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Boards, Wiki}

  setup do
    Slipdock.TestConfig.own_uploads_dir()
    src = Path.join(System.tmp_dir!(), "cleanup-#{System.unique_integer([:positive])}")
    File.write!(src, "bytes")
    on_exit(fn -> File.rm(src) end)

    board = board_fixture(%{"name" => "Cleanup"})
    {:ok, template} = Boards.find_template(nil, "Simple")
    %{board: board, column: hd(board.columns), src: src, template: template}
  end

  defp attach(%Slipdock.Wiki.Page{} = page, src, name) do
    {:ok, a} = Wiki.add_attachment(page, %{filename: name, content_type: "image/png"}, src)
    a
  end

  defp attach(card, src, name) do
    {:ok, a} = Boards.add_attachment(card, %{filename: name, content_type: "text/plain"}, src)
    a
  end

  defp on_disk?(a), do: File.exists?(Boards.attachment_path(a))

  # epic → its sub-board (a card, a page) → a deeper sub-board (a card).
  defp tree(%{column: column, src: src, template: t}) do
    epic = card_fixture(column, %{"title" => "Epic"})
    {:ok, sub} = sub_board(epic, t)
    sub = Boards.get_board!(sub.id)
    child = card_fixture(hd(sub.columns), %{"title" => "Child"})
    page = page_fixture(sub, %{"title" => "Sub page"})
    {:ok, deeper} = sub_board(child, t)
    deeper = Boards.get_board!(deeper.id)
    grandchild = card_fixture(hd(deeper.columns), %{"title" => "Grandchild"})

    %{
      epic: epic,
      files: [
        attach(epic, src, "epic.txt"),
        attach(child, src, "child.txt"),
        attach(page, src, "page.png"),
        attach(grandchild, src, "grandchild.txt")
      ]
    }
  end

  test "deleting a card deletes its files and every file beneath it", ctx do
    %{epic: epic, files: files} = tree(ctx)
    bystander = attach(card_fixture(ctx.column, %{"title" => "Other"}), ctx.src, "keep.txt")
    assert Enum.all?(files, &on_disk?/1)

    {:ok, _} = Boards.delete_card(Boards.get_card!(epic.id))

    refute Enum.any?(files, &on_disk?/1)
    assert on_disk?(bystander)
  end

  test "deleting a list deletes its cards' files, archived ones and subtrees too", ctx do
    %{epic: _epic, files: files} = tree(ctx)
    archived = card_fixture(ctx.column, %{"title" => "Archived"})
    archived_file = attach(archived, ctx.src, "archived.txt")
    {:ok, _} = Boards.archive_card(archived)

    [_, other_column | _] = ctx.board.columns
    bystander = attach(card_fixture(other_column, %{"title" => "Elsewhere"}), ctx.src, "keep.txt")

    {:ok, _} = Boards.delete_column(ctx.column)

    refute Enum.any?([archived_file | files], &on_disk?/1)
    assert on_disk?(bystander)
  end

  test "deleting an empty list removes nothing", ctx do
    [_, other_column | _] = ctx.board.columns
    keep = attach(card_fixture(ctx.column, %{"title" => "Stays"}), ctx.src, "keep.txt")

    {:ok, _} = Boards.delete_column(other_column)
    assert on_disk?(keep)
  end

  test "deleting a page deletes its images, and no other page's", ctx do
    page = page_fixture(ctx.board, %{"title" => "Runbook"})
    other = page_fixture(ctx.board, %{"title" => "Other"})
    image = attach(page, ctx.src, "diagram.png")
    keep = attach(other, ctx.src, "keep.png")

    {:ok, _} = Wiki.delete_page(page)

    refute on_disk?(image)
    assert on_disk?(keep)
  end

  test "purging a folder deletes its pages' images", ctx do
    {:ok, folder} = Wiki.create_folder(ctx.board, %{"name" => "Old"})
    page = page_fixture(ctx.board, %{"title" => "Filed"})
    {:ok, _} = Wiki.file_page(page, folder)
    image = attach(page, ctx.src, "diagram.png")

    {:ok, _} = Wiki.delete_folder(folder, :purge)

    refute on_disk?(image)
  end

  test "card_file_keys/1 of no cards is nothing" do
    assert Boards.card_file_keys([]) == []
  end
end
