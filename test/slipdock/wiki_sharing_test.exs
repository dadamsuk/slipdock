defmodule Slipdock.WikiSharingTest do
  @moduledoc """
  What a read-write sharee may and may not do, through the contexts (#816).
  The API's half is `SlipdockWeb.API.SharedWritesTest`.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Access, Wiki}
  alias Slipdock.Wiki.{AutoOrganise, Drawings, FolderMove, Files, Move, Sharing}

  setup do
    owner = user_fixture()
    board = board_fixture(%{"name" => "Handbook"}, owner: owner)
    {:ok, shared} = Wiki.create_folder(board, %{"name" => "Shared"})
    {:ok, inner} = Wiki.create_folder(board, %{"name" => "Inner", "parent_id" => shared.id})
    {:ok, other} = Wiki.create_folder(board, %{"name" => "Other", "parent_id" => shared.id})
    {:ok, private} = Wiki.create_folder(board, %{"name" => "Private"})
    page = page_fixture(board, %{"title" => "Plan", "folder_id" => inner.id}, user: owner)
    sharee = user_fixture("sharee@example.com")
    {:ok, _} = Access.grant(shared, sharee, "write", owner)

    %{
      owner: owner,
      board: board,
      shared: shared,
      inner: inner,
      other: other,
      private: private,
      page: page,
      sharee: sharee
    }
  end

  defp refused?(result, code), do: match?({:error, :shared, ^code, _}, result)

  describe "a read-write sharee can" do
    test "edit and rename a page", c do
      assert {:ok, page} =
               Wiki.update_page(c.page, %{"title" => "Plan B", "body" => "new"}, user: c.sharee)

      assert page.title == "Plan B"
      assert page.updated_by_id == c.sharee.id
    end

    test "make a page inside the shared folder, on the owner's board, as its creator", c do
      assert {:ok, page} =
               Wiki.create_page(c.board, %{"title" => "Mine", "folder_id" => c.inner.id},
                 user: c.sharee
               )

      assert page.board_id == c.board.id
      assert page.created_by_id == c.sharee.id
    end

    test "make a subfolder, a drawing and a file inside it", c do
      assert {:ok, sub} =
               Wiki.create_folder(c.board, %{"name" => "Sub", "parent_id" => c.inner.id},
                 user: c.sharee
               )

      assert sub.parent_id == c.inner.id

      assert {:ok, drawing} = Drawings.create(c.board, sub, user: c.sharee)
      assert drawing.folder_id == sub.id

      path = tmp_file()

      assert {:ok, file} =
               Files.create(c.board, %{name: "a.png", folder_id: sub.id}, path, c.sharee)

      assert file.created_by_id == c.sharee.id
      assert file.board_id == c.board.id
    end

    test "rename a folder, and move pages, files and folders within the share", c do
      assert {:ok, renamed} = Wiki.update_folder(c.inner, %{"name" => "Renamed"}, user: c.sharee)
      assert renamed.name == "Renamed"

      assert {:ok, moved} = Wiki.update_page(c.page, %{"folder_id" => c.other.id}, user: c.sharee)
      assert moved.folder_id == c.other.id

      assert {:ok, folder} =
               Wiki.update_folder(c.inner, %{"parent_id" => c.other.id}, user: c.sharee)

      assert folder.parent_id == c.other.id

      {:ok, file} = Files.create(c.board, %{name: "b.png", folder_id: c.inner.id}, tmp_file())
      assert {:ok, file} = Files.move(file, %{folder_id: c.shared.id}, user: c.sharee)
      assert file.folder_id == c.shared.id
    end
  end

  describe "a read-write sharee cannot" do
    test "delete, archive or restore", c do
      for item <- [c.page, c.inner, c.shared] do
        assert refused?(Sharing.check(c.sharee, :delete, item), "shared_no_delete")
      end
    end

    test "move a page out of the share, to the top, or to another board", c do
      assert refused?(
               Wiki.update_page(c.page, %{"folder_id" => c.private.id}, user: c.sharee),
               "shared_no_move_out"
             )

      assert refused?(
               Wiki.update_page(c.page, %{"folder_id" => nil}, user: c.sharee),
               "shared_no_move_out"
             )

      elsewhere = board_fixture(%{"name" => "Theirs"}, owner: c.sharee)

      assert refused?(Move.to_board(c.page, elsewhere, nil, c.sharee), "shared_no_move_out")
      assert Wiki.get_page!(c.page.id).folder_id == c.inner.id
    end

    test "move a folder out of the share, or the shared folder itself", c do
      assert refused?(
               Wiki.update_folder(c.inner, %{"parent_id" => c.private.id}, user: c.sharee),
               "shared_no_move_out"
             )

      assert refused?(
               Wiki.update_folder(c.inner, %{"parent_id" => nil}, user: c.sharee),
               "shared_no_move_out"
             )

      # The top of the share sits in the owner's tree: it stays put.
      assert refused?(
               Wiki.update_folder(c.shared, %{"parent_id" => c.private.id}, user: c.sharee),
               "shared_no_move"
             )

      elsewhere = board_fixture(%{"name" => "Theirs"}, owner: c.sharee)
      assert refused?(FolderMove.to_board(c.inner, elsewhere, c.sharee), "shared_no_move_out")
    end

    test "move a file out of the share", c do
      {:ok, file} = Files.create(c.board, %{name: "c.png", folder_id: c.inner.id}, tmp_file())

      assert refused?(
               Files.move(file, %{folder_id: c.private.id}, user: c.sharee),
               "shared_no_move_out"
             )
    end

    test "make things outside the share", c do
      assert refused?(
               Wiki.create_page(c.board, %{"title" => "X", "folder_id" => c.private.id},
                 user: c.sharee
               ),
               "shared_no_create"
             )

      assert refused?(
               Wiki.create_folder(c.board, %{"name" => "Top"}, user: c.sharee),
               "shared_no_create"
             )

      assert refused?(
               Files.create(c.board, %{name: "d.png", folder_id: nil}, tmp_file(), c.sharee),
               "shared_no_create"
             )
    end

    test "turn on encryption", c do
      meld = "%%🔐α secret 🔐%%"
      assert Slipdock.Wiki.Meld.encrypted?(meld)

      assert refused?(
               Wiki.update_page(c.page, %{"body" => meld}, user: c.sharee),
               "shared_no_encrypt"
             )

      attrs = %{"title" => "E", "body" => meld, "folder_id" => c.inner.id}
      assert refused?(Wiki.create_page(c.board, attrs, user: c.sharee), "shared_no_encrypt")
    end

    test "change or pass on the share, or reorganise the folders", c do
      assert refused?(Sharing.check(c.sharee, :share, c.page), "shared_no_reshare")
      assert refused?(Sharing.check(c.sharee, :share, c.shared), "shared_no_reshare")
      assert {:error, message} = AutoOrganise.plan(c.shared, "flatten", user: c.sharee)
      assert message =~ "reorganise"
    end
  end

  test "a reader of the share changes nothing", c do
    reader = user_fixture("reader@example.com")
    {:ok, _} = Access.grant(c.shared, reader, "read", c.owner)

    assert refused?(Sharing.check(reader, :edit, c.page), "shared_read_only")
  end

  test "a sharee of one page edits and renames it, and cannot move it", c do
    loose =
      page_fixture(c.board, %{"title" => "Loose", "folder_id" => c.private.id}, user: c.owner)

    one = user_fixture("one@example.com")
    {:ok, _} = Access.grant(loose, one, "write", c.owner)

    assert {:ok, %{title: "Loose 2"}} =
             Wiki.update_page(loose, %{"title" => "Loose 2"}, user: one)

    assert refused?(
             Wiki.update_page(loose, %{"folder_id" => c.shared.id}, user: one),
             "shared_no_move"
           )

    parent =
      page_fixture(c.board, %{"title" => "Parent", "folder_id" => c.private.id}, user: c.owner)

    assert refused?(Wiki.move_page(loose, parent, :bottom, user: one), "shared_no_move")
  end

  test "board writers keep everything", c do
    writer = user_fixture("writer@example.com")
    {:ok, _} = Access.grant(c.board, writer, "write", c.owner)

    assert {:ok, _} = Wiki.update_page(c.page, %{"folder_id" => c.private.id}, user: writer)
    assert {:ok, _} = Wiki.create_folder(c.board, %{"name" => "Top"}, user: writer)
    assert :ok = Sharing.check(writer, :delete, c.page)
    assert :ok = Sharing.check(writer, :share, c.shared)
    assert :ok = Sharing.check(c.owner, :encrypt, c.page)
  end

  defp tmp_file do
    path = Path.join(System.tmp_dir!(), "sharing-#{System.unique_integer([:positive])}.png")
    File.write!(path, "png bytes")
    on_exit(fn -> File.rm(path) end)
    path
  end
end
