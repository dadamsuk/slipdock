defmodule Slipdock.AccessFolderGrantsTest do
  @moduledoc "A grant on a wiki folder shares everything at home beneath it (#815)."
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Access, Accounts, Wiki}
  alias Slipdock.Access.Grant
  alias Slipdock.Wiki.{Drawings, Files, Placements}

  setup do
    owner = user_fixture()
    board = board_fixture(%{"name" => "Handbook"}, owner: owner)
    {:ok, top} = Wiki.create_folder(board, %{"name" => "Shared"})
    {:ok, one} = Wiki.create_folder(board, %{"name" => "One", "parent_id" => top.id})
    {:ok, two} = Wiki.create_folder(board, %{"name" => "Two", "parent_id" => one.id})
    {:ok, three} = Wiki.create_folder(board, %{"name" => "Three", "parent_id" => two.id})
    {:ok, outside} = Wiki.create_folder(board, %{"name" => "Private"})

    page = fn title, folder ->
      page_fixture(board, %{"title" => title, "folder_id" => folder && folder.id}, user: owner)
    end

    %{
      owner: owner,
      board: board,
      top: top,
      one: one,
      three: three,
      outside: outside,
      at0: page.("At the top", top),
      at1: page.("One down", one),
      at3: page.("Three down", three),
      private: page.("Private notes", outside),
      loose: page.("Loose", nil),
      sharee: user_fixture("sharee@example.com")
    }
  end

  describe "permission through a folder grant" do
    test "reaches pages at depth 0, 1 and 3, and nothing outside", c do
      {:ok, _} = Access.grant(c.top, c.sharee, "read", c.owner)

      assert Access.page_permission(c.sharee, c.at0) == :read
      assert Access.page_permission(c.sharee, c.at1) == :read
      assert Access.page_permission(c.sharee, c.at3) == :read
      assert Access.page_permission(c.sharee, c.private) == :none
      assert Access.page_permission(c.sharee, c.loose) == :none
      # And the folders themselves, to any depth; but not the board.
      assert Access.folder_permission(c.sharee, c.three) == :read
      assert Access.folder_permission(c.sharee, c.outside) == :none
      assert Access.board_permission(c.sharee, c.board) == :none
    end

    test "a grant lower down reaches only that subtree", c do
      {:ok, _} = Access.grant(c.one, c.sharee, "write", c.owner)

      assert Access.page_permission(c.sharee, c.at0) == :none
      assert Access.page_permission(c.sharee, c.at1) == :write
      assert Access.page_permission(c.sharee, c.at3) == :write
      assert Access.folder_permission(c.sharee, c.top) == :none
    end

    test "read and write are what was granted, and the higher of two wins", c do
      {:ok, _} = Access.grant(c.top, c.sharee, "read", c.owner)
      assert Access.page_permission(c.sharee, c.at3) == :read
      refute Access.can_write?(Access.page_permission(c.sharee, c.at3))

      {:ok, _} = Access.grant(c.three, c.sharee, "write", c.owner)
      assert Access.page_permission(c.sharee, c.at3) == :write
      assert Access.page_permission(c.sharee, c.at1) == :read
    end

    test "a group grant reaches every member", c do
      {:ok, group} = Accounts.create_group(c.owner, %{"name" => "Ops"})
      {:ok, _} = Accounts.add_group_member(group, c.sharee.email)
      {:ok, _} = Access.grant(c.top, group, "write", c.owner)

      assert Access.page_permission(c.sharee, c.at3) == :write
      assert Access.page_permission(user_fixture("nobody@example.com"), c.at3) == :none
    end

    test "a page from elsewhere only also filed in a shared folder stays unreadable", c do
      {:ok, _} = Placements.add(c.private, c.top, c.owner)
      {:ok, _} = Access.grant(c.top, c.sharee, "read", c.owner)

      assert Access.page_permission(c.sharee, c.private) == :none
      refute c.private.id in Enum.map(Access.shared_pages(c.sharee), & &1.id)
    end

    test "revoking it takes everything back", c do
      {:ok, grant} = Access.grant(c.top, c.sharee, "write", c.owner)
      assert Access.page_permission(c.sharee, c.at3) == :write

      {:ok, _} = Access.revoke(grant)
      assert Access.page_permission(c.sharee, c.at3) == :none
      assert Access.shared_pages(c.sharee) == []
      assert Access.shared_folders(c.sharee) == []
    end

    test "a board reader keeps reading, and is raised to a writer inside the share", c do
      {:ok, _} = Access.grant(c.board, c.sharee, "read", c.owner)
      {:ok, _} = Access.grant(c.one, c.sharee, "write", c.owner)

      assert Access.page_permission(c.sharee, c.private) == :read
      assert Access.page_permission(c.sharee, c.at3) == :write
      # What sharing alone gives, the board aside.
      assert Access.share_permission(c.sharee, c.private) == :none
      assert Access.share_permission(c.sharee, c.at3) == :write
    end

    test "the ancestry lookup is one query however deep the folder", c do
      {:ok, _} = Access.grant(c.top, c.sharee, "read", c.owner)

      assert count_queries(fn -> Access.folder_grant_level(c.sharee, c.top.id) end) == 1
      assert count_queries(fn -> Access.folder_grant_level(c.sharee, c.three.id) end) == 1
      assert Access.folder_grant_level(c.sharee, c.three.id) == :read
      assert Access.folder_grant_level(c.sharee, nil) == :none
    end
  end

  describe "files and drawings under a shared folder" do
    setup c do
      path = Path.join(System.tmp_dir!(), "share-#{System.unique_integer([:positive])}.png")
      File.write!(path, "png bytes")
      on_exit(fn -> File.rm(path) end)

      {:ok, inside} = Files.create(c.board, %{name: "diagram.png", folder_id: c.three.id}, path)
      {:ok, out} = Files.create(c.board, %{name: "secret.png", folder_id: c.outside.id}, path)

      drawing =
        page_fixture(
          c.board,
          %{
            "title" => "Flow",
            "file_name" => "Flow.excalidraw",
            "front_matter" => "---\nexcalidraw-plugin: parsed\n---\n",
            "folder_id" => c.one.id
          },
          user: c.owner
        )

      %{inside: inside, out: out, drawing: drawing}
    end

    test "are shared with the folder, and nothing outside it is", c do
      {:ok, _} = Access.grant(c.top, c.sharee, "write", c.owner)

      assert Access.file_permission(c.sharee, c.inside) == :write
      assert Access.file_permission(c.sharee, c.out) == :none
      assert Drawings.readable?(c.inside, c.sharee)
      refute Drawings.readable?(c.out, c.sharee)
      assert Drawings.readable?(c.drawing, c.sharee)

      assert Enum.map(Access.shared_files(c.sharee), & &1.id) == [c.inside.id]
    end
  end

  describe "what is shared with somebody" do
    test "shared_pages lists the folder's pages at any depth with direct page grants", c do
      {:ok, _} = Access.grant(c.one, c.sharee, "read", c.owner)
      {:ok, _} = Access.grant(c.loose, c.sharee, "read", c.owner)

      ids = c.sharee |> Access.shared_pages() |> Enum.map(& &1.id) |> Enum.sort()
      assert ids == Enum.sort([c.at1.id, c.at3.id, c.loose.id])
      assert Enum.map(Access.shared_folders(c.sharee), & &1.id) == [c.one.id]

      assert Enum.sort(Access.shared_folder_subtree_ids(c.sharee)) ==
               Enum.sort([c.one.id, Wiki.get_folder(c.three.parent_id).id, c.three.id])
    end

    test "their owner's tree can tell which folders carry a grant", c do
      {:ok, _} = Access.grant(c.one, c.sharee, "read", c.owner)

      assert Access.shared_folder_ids([c.top.id, c.one.id, c.three.id]) == MapSet.new([c.one.id])
      assert Access.shared_folder_ids([]) == MapSet.new()
    end

    test "a folder grant is listed and revoked like any other", c do
      {:ok, grant} = Access.grant(c.top, c.sharee, "read", c.owner)

      assert [%Grant{folder_id: id}] = Access.list_grants(c.top)
      assert id == c.top.id
      assert Grant.resource_type(grant) == :folder
      assert {:ok, _} = Access.revoke(grant)
      assert Access.list_grants(c.top) == []
    end

    test "a grant names exactly one resource", c do
      changeset =
        Grant.changeset(%Grant{}, %{
          level: "read",
          user_id: c.sharee.id,
          page_id: c.at0.id,
          folder_id: c.top.id
        })

      refute changeset.valid?
    end

    test "deleting the folder takes its grants with it", c do
      {:ok, _} = Access.grant(c.three, c.sharee, "read", c.owner)
      {:ok, _} = Wiki.delete_folder(Wiki.get_folder(c.three.id))

      assert Slipdock.Repo.aggregate(
               from(g in Grant, where: g.folder_id == ^c.three.id),
               :count
             ) == 0
    end
  end

  defp count_queries(fun) do
    ref = make_ref()
    me = self()
    handler = "count-#{inspect(ref)}"

    :telemetry.attach(
      handler,
      [:slipdock, :repo, :query],
      # Handlers run in the process that queried: count only this test's.
      fn _event, _measurements, _meta, _ -> if self() == me, do: send(me, {ref, :query}) end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(handler)
    end

    count(ref, 0)
  end

  defp count(ref, n) do
    receive do
      {^ref, :query} -> count(ref, n + 1)
    after
      0 -> n
    end
  end
end
