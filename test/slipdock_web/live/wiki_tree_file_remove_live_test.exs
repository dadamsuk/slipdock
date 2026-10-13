defmodule SlipdockWeb.WikiTreeFileRemoveLiveTest do
  @moduledoc """
  Archiving and deleting a file from the wiki's tree (#769): each asks
  first; archiving keeps the bytes, deleting takes the row and the bytes and
  tells a sync, and only the board's owner may delete. A reader does
  neither.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures
  import SlipdockWeb.WikiTreeHelpers

  import Ecto.Query

  alias Slipdock.Repo
  alias Slipdock.Wiki.{Change, Files}

  setup %{user: user} do
    kb = board_fixture(%{"name" => "KB", "code" => "kbfrm"}, owner: user)
    cat = file_fixture(kb, "cat.png")
    %{kb: kb, cat: cat}
  end

  defp file_fixture(board, name) do
    path = Path.join(System.tmp_dir!(), "frm-#{System.unique_integer([:positive])}")
    File.write!(path, "BYTES")
    {:ok, file} = Files.create(board, %{name: name}, path)
    file
  end

  defp actions(file),
    do:
      Repo.all(
        from(c in Change,
          where: c.subject == "file" and c.subject_id == ^file.id,
          order_by: c.id,
          select: c.action
        )
      )

  defp in_tree?(view, name),
    do: tree_load(view).nodes["root"] |> Enum.any?(&(&1.title == name))

  test "Archive asks, Cancel keeps it, Archive puts it away with its bytes kept", ctx do
    %{conn: conn, kb: kb, cat: cat} = ctx
    {:ok, view, _} = live(conn, ~p"/boards/#{kb}/wiki")
    assert in_tree?(view, "cat.png")

    render_hook(view, "ask_archive_file", %{"id" => to_string(cat.id)})
    assert render(view) =~ "Archive cat.png?"
    view |> element("button[phx-click='close_tree_prompt']", "Cancel") |> render_click()
    assert is_nil(Files.get(cat.id).archived_at)

    render_hook(view, "ask_archive_file", %{"id" => to_string(cat.id)})
    assert view |> element("#tree-archive-file-confirm") |> render_click() =~ "Archived cat.png."

    refute is_nil(Files.get(cat.id).archived_at)
    assert File.exists?(Files.disk_path(cat))
    refute has_element?(view, "#tree-prompt")
    refute in_tree?(view, "cat.png")
    assert List.last(actions(cat)) == "archived"
  end

  test "the owner deletes a file for good: row, bytes and a `deleted` for a sync", ctx do
    %{conn: conn, kb: kb, cat: cat} = ctx
    {:ok, view, _} = live(conn, ~p"/boards/#{kb}/wiki")
    assert File.exists?(Files.disk_path(cat))

    render_hook(view, "ask_delete_file", %{"id" => to_string(cat.id)})
    assert render(view) =~ "Delete cat.png?"
    refute has_element?(view, "#tree-delete-file-owner-only")

    html = view |> element("#tree-delete-file-confirm") |> render_click()
    assert html =~ "Deleted cat.png for good."

    assert is_nil(Files.get(cat.id))
    refute File.exists?(Files.disk_path(cat))
    refute in_tree?(view, "cat.png")
    assert List.last(actions(cat)) == "deleted"
  end

  test "an archived file can still be deleted, and a deleted one asks for nothing", ctx do
    %{conn: conn, kb: kb, cat: cat} = ctx
    {:ok, view, _} = live(conn, ~p"/boards/#{kb}/wiki")
    {:ok, _} = Files.delete(cat)

    render_hook(view, "ask_delete_file", %{"id" => to_string(cat.id)})
    render_hook(view, "ask_archive_file", %{"id" => "nonsense"})
    refute has_element?(view, "#tree-prompt")
  end

  test "a writer who isn't the owner may archive, but is told only the owner deletes", ctx do
    %{kb: kb, cat: cat, user: owner} = ctx
    writer = user_fixture("file-writer@example.com")
    {:ok, _} = Slipdock.Access.grant(kb, writer, "write", owner)
    {:ok, view, _} = live(log_in_user(build_conn(), writer), ~p"/boards/#{kb}/wiki")

    render_hook(view, "ask_delete_file", %{"id" => to_string(cat.id)})
    assert has_element?(view, "#tree-delete-file-owner-only")
    refute has_element?(view, "#tree-delete-file-confirm")

    # Sent anyway, the server still refuses.
    assert render_click(view, "delete_file", %{}) =~
             "Only the board&#39;s owner can delete a file."

    assert Files.get(cat.id)
    assert File.exists?(Files.disk_path(cat))

    render_hook(view, "ask_archive_file", %{"id" => to_string(cat.id)})
    view |> element("#tree-archive-file-confirm") |> render_click()
    refute is_nil(Files.get(cat.id).archived_at)
  end

  test "a reader is asked nothing, and a stray delete or archive changes nothing", ctx do
    %{kb: kb, cat: cat, user: owner} = ctx
    reader = user_fixture("file-reader@example.com")
    {:ok, _} = Slipdock.Access.grant(kb, reader, "read", owner)
    {:ok, view, _} = live(log_in_user(build_conn(), reader), ~p"/boards/#{kb}/wiki")

    render_hook(view, "ask_delete_file", %{"id" => to_string(cat.id)})
    render_hook(view, "ask_archive_file", %{"id" => to_string(cat.id)})
    refute has_element?(view, "#tree-prompt")

    assert render_click(view, "delete_file", %{}) =~ "That file couldn&#39;t be deleted."
    assert render_click(view, "archive_file", %{}) =~ "That file couldn&#39;t be archived."
    assert %{archived_at: nil} = Files.get(cat.id)
  end

  test "Files.delete gives the bytes back and logs the deletion", %{kb: kb} do
    dog = file_fixture(kb, "dog.png")
    path = Files.disk_path(dog)

    assert {:ok, _} = Files.delete(dog)
    assert is_nil(Files.get(dog.id))
    refute File.exists?(path)
    assert actions(dog) == ["changed", "deleted"]
  end
end
