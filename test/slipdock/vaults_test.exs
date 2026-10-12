defmodule Slipdock.VaultsTest do
  @moduledoc """
  Vaults and their mappings (W-103 R1): a vault is a person's own, a mapping
  puts a vault path onto a board's wiki or one folder of it, the longest
  prefix wins, a target must be writable, and a board belongs to one vault.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Boards, Vaults, Wiki}
  alias Slipdock.Vaults.Vault

  setup do
    user = user_fixture()
    kb = board_fixture(%{"name" => "KnowledgeBase", "code" => "kb"}, owner: user)
    jobs = board_fixture(%{"name" => "Job Hunt", "code" => "jobs"}, owner: user)
    {:ok, vault} = Vaults.create_vault(user, %{"name" => "Notes"})
    %{user: user, kb: kb, jobs: jobs, vault: vault}
  end

  defp map!(vault, user, attrs) do
    {:ok, mapping} = Vaults.add_mapping(vault, user, attrs)
    mapping
  end

  describe "vaults" do
    test "are found by id or by name, case-insensitively", %{user: user, vault: vault} do
      assert {:ok, %Vault{id: id}} = Vaults.get_vault(user, "notes")
      assert id == vault.id
      assert {:ok, %Vault{id: ^id}} = Vaults.get_vault(user, to_string(vault.id))
      assert {:error, :not_found, _} = Vaults.get_vault(user, "nope")
    end

    test "are their owner's alone", %{vault: vault} do
      stranger = user_fixture("stranger@example.com")
      assert {:error, :not_found, _} = Vaults.get_vault(stranger, vault.id)
      assert Vaults.list_vaults(stranger) == []
    end

    test "names are unique per person, case and all, and cannot be blank or hold a slash",
         %{user: user} do
      assert {:error, cs} = Vaults.create_vault(user, %{"name" => "NOTES"})
      assert "you already have a vault with that name" in errors_on(cs).name
      assert {:error, cs} = Vaults.create_vault(user, %{"name" => "  "})
      assert errors_on(cs).name != []
      assert {:error, cs} = Vaults.create_vault(user, %{"name" => "a/b"})
      assert "cannot contain a slash" in errors_on(cs).name

      other = user_fixture("other@example.com")
      assert {:ok, _} = Vaults.create_vault(other, %{"name" => "Notes"})
    end

    test "rename and delete; deleting keeps every page", ctx do
      %{user: user, kb: kb, vault: vault} = ctx
      {:ok, page} = Wiki.create_page(kb, %{"title" => "Kept"}, user: user)
      map!(vault, user, %{path: "/", board: kb})

      assert {:ok, %Vault{name: "Brain"}} = Vaults.update_vault(vault, %{"name" => "Brain"})
      assert {:ok, _} = Vaults.delete_vault(vault)
      assert Vaults.list_vaults(user) == []
      assert Vaults.for_board(kb) == nil
      assert Wiki.get_page(page.id)
    end
  end

  describe "mappings" do
    test "map a path to a wiki root or a folder, stored without slashes", ctx do
      %{user: user, kb: kb, jobs: jobs, vault: vault} = ctx
      {:ok, folder} = Wiki.create_folder(jobs, %{"name" => "Notes"})

      root = map!(vault, user, %{path: "/", board: kb})
      sub = map!(vault, user, %{path: "/Jobs/", board: jobs, folder: folder})

      assert root.path == ""
      assert sub.path == "Jobs"
      assert sub.folder_id == folder.id

      assert {:ok, %Vault{mappings: [%{path: ""}, %{path: "Jobs"}]}} =
               Vaults.get_vault(user, "Notes")

      assert Vaults.for_board(jobs).id == vault.id
      assert Enum.sort(Vaults.board_ids(vault)) == Enum.sort([kb.id, jobs.id])
    end

    test "the same path twice in one vault is refused", %{
      user: user,
      kb: kb,
      jobs: jobs,
      vault: vault
    } do
      map!(vault, user, %{path: "/Jobs", board: kb})
      assert {:error, cs} = Vaults.add_mapping(vault, user, %{path: "Jobs", board: jobs})
      assert "is already mapped in this vault" in errors_on(cs).path
    end

    test "a board's root, or one folder, is mapped once", %{user: user, kb: kb, vault: vault} do
      {:ok, folder} = Wiki.create_folder(kb, %{"name" => "Inbox"})
      map!(vault, user, %{path: "/", board: kb})

      assert {:error, cs} = Vaults.add_mapping(vault, user, %{path: "/Again", board: kb})
      assert "is already mapped into a vault" in errors_on(cs).board_id

      # A folder of the same board, in the same vault, is a different target.
      map!(vault, user, %{path: "/Inbox", board: kb, folder: folder})

      assert {:error, cs} =
               Vaults.add_mapping(vault, user, %{path: "/In2", board: kb, folder: folder})

      assert "is already mapped into a vault" in errors_on(cs).folder_id
    end

    test "a board belongs to one vault", %{user: user, kb: kb, vault: vault} do
      {:ok, folder} = Wiki.create_folder(kb, %{"name" => "Inbox"})
      map!(vault, user, %{path: "/", board: kb})
      {:ok, other} = Vaults.create_vault(user, %{"name" => "Other"})

      assert {:error, :unprocessable_entity, message} =
               Vaults.add_mapping(other, user, %{path: "/", board: kb, folder: folder})

      assert message =~ "already in another vault"
    end

    test "only a board you can write to", %{user: user, vault: vault} do
      stranger = user_fixture("owner2@example.com")
      read_only = board_fixture(%{"name" => "Read only", "code" => "ro"}, owner: stranger)
      writable = board_fixture(%{"name" => "Writable", "code" => "rw"}, owner: stranger)
      share_fixture(read_only, user, "read")
      share_fixture(writable, user, "write")

      assert {:error, :forbidden, _} =
               Vaults.add_mapping(vault, user, %{path: "/R", board: read_only})

      assert {:ok, _} = Vaults.add_mapping(vault, user, %{path: "/W", board: writable})
    end

    test "not an archived board, nor another board's folder, nor no board at all", ctx do
      %{user: user, kb: kb, jobs: jobs, vault: vault} = ctx
      {:ok, folder} = Wiki.create_folder(jobs, %{"name" => "Theirs"})

      assert {:error, :unprocessable_entity, "that folder is not on that board"} =
               Vaults.add_mapping(vault, user, %{path: "/", board: kb, folder: folder})

      assert {:error, :unprocessable_entity, _} = Vaults.add_mapping(vault, user, %{path: "/"})

      {:ok, archived} = Boards.archive_board(kb)

      assert {:error, :unprocessable_entity, msg} =
               Vaults.add_mapping(vault, user, %{path: "/", board: archived})

      assert msg =~ "archived"
    end

    test "a path that climbs is refused", %{user: user, kb: kb, vault: vault} do
      assert {:error, :unprocessable_entity, _} =
               Vaults.add_mapping(vault, user, %{path: "/a/../b", board: kb})

      assert {:error, :unprocessable_entity, _} = Vaults.normalize_path("./x")
      assert {:ok, "a/b"} = Vaults.normalize_path("\\a\\\\b\\")
      assert {:ok, ""} = Vaults.normalize_path(nil)
    end

    test "removed by id or by path", %{user: user, kb: kb, jobs: jobs, vault: vault} do
      root = map!(vault, user, %{path: "/", board: kb})
      map!(vault, user, %{path: "/Jobs", board: jobs})

      assert {:ok, _} = Vaults.remove_mapping(vault, "/Jobs")
      assert {:ok, _} = Vaults.remove_mapping(vault, root.id)
      assert {:error, :not_found, _} = Vaults.remove_mapping(vault, "/Jobs")
      assert {:error, :not_found, _} = Vaults.remove_mapping(vault, "/../x")
      assert Vaults.for_board(kb) == nil
    end

    test "go when the board or the folder they point at is deleted", ctx do
      %{user: user, kb: kb, jobs: jobs, vault: vault} = ctx
      {:ok, folder} = Wiki.create_folder(jobs, %{"name" => "Notes"})
      map!(vault, user, %{path: "/", board: kb})
      map!(vault, user, %{path: "/Jobs", board: jobs, folder: folder})

      {:ok, _} = Wiki.delete_folder(folder)
      {:ok, _} = Boards.delete_board(kb)

      assert {:ok, %Vault{mappings: []}} = Vaults.get_vault(user, vault.id)
    end
  end

  describe "locate/2" do
    setup %{user: user, kb: kb, jobs: jobs, vault: vault} do
      map!(vault, user, %{path: "/", board: kb})
      map!(vault, user, %{path: "/Jobs", board: jobs})
      :ok
    end

    test "the longest matching prefix wins", %{vault: vault, kb: kb, jobs: jobs} do
      assert {:ok, %{board_id: id}, "Acme/Call.md"} = Vaults.locate(vault, "/Jobs/Acme/Call.md")
      assert id == jobs.id
      assert {:ok, %{board_id: ^id}, ""} = Vaults.locate(vault, "Jobs")
      assert {:ok, %{board_id: kb_id}, "Ideas.md"} = Vaults.locate(vault, "/Ideas.md")
      assert kb_id == kb.id
    end

    test "matches whole segments, so /Jobs does not swallow /Jobsearch", %{vault: vault, kb: kb} do
      assert {:ok, %{board_id: id}, "Jobsearch/x.md"} = Vaults.locate(vault, "/Jobsearch/x.md")
      assert id == kb.id
    end

    test "nothing mapped above the path is not found", %{user: user} do
      deep = board_fixture(%{"name" => "Deep", "code" => "deep"}, owner: user)
      {:ok, bare} = Vaults.create_vault(user, %{"name" => "Bare"})
      assert {:error, :not_found, _} = Vaults.locate(bare, "/x.md")

      {:ok, sub} = Vaults.create_vault(user, %{"name" => "Sub"})
      {:ok, folder} = Wiki.create_folder(deep, %{"name" => "Deep"})
      map!(sub, user, %{path: "/Only/Here", board: deep, folder: folder})
      assert {:error, :not_found, _} = Vaults.locate(sub, "/Only/x.md")
      assert {:ok, _, "x.md"} = Vaults.locate(sub, "/Only/Here/x.md")
    end
  end
end
