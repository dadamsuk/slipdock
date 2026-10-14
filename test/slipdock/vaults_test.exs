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
    kb = board_fixture(%{"name" => "Keystone", "code" => "kb4"}, owner: user)
    jobs = board_fixture(%{"name" => "Journal Desk", "code" => "jobs3"}, owner: user)
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
      sub = map!(vault, user, %{path: "/Journal/", board: jobs, folder: folder})

      assert root.path == ""
      assert sub.path == "Journal"
      assert sub.folder_id == folder.id

      assert {:ok, %Vault{mappings: [%{path: ""}, %{path: "Journal"}]}} =
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
      map!(vault, user, %{path: "/Journal", board: kb})
      assert {:error, cs} = Vaults.add_mapping(vault, user, %{path: "Journal", board: jobs})
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
      map!(vault, user, %{path: "/Journal", board: jobs})

      assert {:ok, _} = Vaults.remove_mapping(vault, "/Journal")
      assert {:ok, _} = Vaults.remove_mapping(vault, root.id)
      assert {:error, :not_found, _} = Vaults.remove_mapping(vault, "/Journal")
      assert {:error, :not_found, _} = Vaults.remove_mapping(vault, "/../x")
      assert Vaults.for_board(kb) == nil
    end

    test "go when the board or the folder they point at is deleted", ctx do
      %{user: user, kb: kb, jobs: jobs, vault: vault} = ctx
      {:ok, folder} = Wiki.create_folder(jobs, %{"name" => "Notes"})
      map!(vault, user, %{path: "/", board: kb})
      map!(vault, user, %{path: "/Journal", board: jobs, folder: folder})

      {:ok, _} = Wiki.delete_folder(folder)
      {:ok, _} = Boards.delete_board(kb)

      assert {:ok, %Vault{mappings: []}} = Vaults.get_vault(user, vault.id)
    end
  end

  describe "locate/2" do
    setup %{user: user, kb: kb, jobs: jobs, vault: vault} do
      map!(vault, user, %{path: "/", board: kb})
      map!(vault, user, %{path: "/Journal", board: jobs})
      :ok
    end

    test "the longest matching prefix wins", %{vault: vault, kb: kb, jobs: jobs} do
      assert {:ok, %{board_id: id}, "Acme/Call.md"} =
               Vaults.locate(vault, "/Journal/Acme/Call.md")

      assert id == jobs.id
      assert {:ok, %{board_id: ^id}, ""} = Vaults.locate(vault, "Journal")
      assert {:ok, %{board_id: kb_id}, "Ideas.md"} = Vaults.locate(vault, "/Ideas.md")
      assert kb_id == kb.id
    end

    test "matches whole segments, so /Journal does not swallow /Journalsearch", %{
      vault: vault,
      kb: kb
    } do
      assert {:ok, %{board_id: id}, "Journalsearch/x.md"} =
               Vaults.locate(vault, "/Journalsearch/x.md")

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

  describe "page counts and mirrors" do
    test "each live page counts once, under the deepest mapping above it", ctx do
      %{user: user, kb: kb, jobs: jobs, vault: vault} = ctx
      {:ok, notes} = Wiki.create_folder(jobs, %{"name" => "Notes"})
      {:ok, _} = Wiki.create_page(kb, %{"title" => "One"}, user: user)
      {:ok, gone} = Wiki.create_page(kb, %{"title" => "Gone"}, user: user)
      {:ok, _} = Wiki.archive_page(gone)
      {:ok, _} = Wiki.create_page(jobs, %{"title" => "Loose"}, user: user)

      {:ok, _} =
        Wiki.create_page(jobs, %{"title" => "Filed", "folder_id" => notes.id}, user: user)

      root = map!(vault, user, %{path: "/", board: kb})
      jobs_root = map!(vault, user, %{path: "/Journal", board: jobs})
      filed = map!(vault, user, %{path: "/Filed", board: jobs, folder: notes})

      assert Vaults.page_counts(vault) == %{root.id => 1, jobs_root.id => 1, filed.id => 1}
    end

    test "an empty vault counts nothing", %{vault: vault} do
      assert Vaults.page_counts(vault) == %{}
    end

    test "a sync token is recorded once per vault, with its label and the last time", ctx do
      %{user: user, vault: vault} = ctx
      {_raw, token} = Slipdock.Accounts.create_api_token(user, "slipdock CLI on laptop")

      assert Vaults.mirrors(vault) == []
      assert :ok = Vaults.touch_mirror(vault, token)
      assert :ok = Vaults.touch_mirror(vault, token)

      assert [%{label: "slipdock CLI on laptop", last_synced_at: %DateTime{}}] =
               Vaults.mirrors(vault)

      # A browser session has no token and is no mirror.
      assert :ok = Vaults.touch_mirror(vault, nil)
      assert length(Vaults.mirrors(vault)) == 1

      # Deleting the vault takes its mirrors with it.
      {:ok, _} = Vaults.delete_vault(vault)
      assert Slipdock.Repo.all(Slipdock.Vaults.Mirror) == []
    end
  end

  describe "previews" do
    test "a new mapping lists the pages it brings in, with their vault paths", ctx do
      %{user: user, kb: kb, jobs: jobs, vault: vault} = ctx
      map!(vault, user, %{path: "/", board: kb})
      {:ok, _} = Wiki.create_page(jobs, %{"title" => "Acme"}, user: user)
      {:ok, _} = Wiki.create_page(jobs, %{"title" => "Beta"}, user: user)

      assert {:ok, preview} =
               Vaults.preview_mapping(vault, user, %{path: "/Journal", board: jobs})

      assert preview.path == "/Journal"
      assert preview.arriving == %{count: 2, sample: ["Journal/Acme.md", "Journal/Beta.md"]}
      assert preview.moving.count == 0
      # Nothing is written.
      assert length(Slipdock.Repo.preload(vault, :mappings, force: true).mappings) == 1
    end

    test "a mapping inside another takes over the pages under its path", ctx do
      %{user: user, kb: kb, vault: vault} = ctx
      {:ok, notes} = Wiki.create_folder(kb, %{"name" => "Notes"})
      {:ok, _} = Wiki.create_page(kb, %{"title" => "Top"}, user: user)

      {:ok, _} =
        Wiki.create_page(kb, %{"title" => "Inside", "folder_id" => notes.id}, user: user)

      map!(vault, user, %{path: "/", board: kb})

      assert {:ok, preview} =
               Vaults.preview_mapping(vault, user, %{path: "/Notes", board: kb, folder: notes})

      assert preview.arriving.count == 0

      assert preview.moving == %{
               count: 1,
               sample: [%{from: "Notes/Inside.md", to: "Notes/Inside.md"}]
             }
    end

    test "names the synced folders that will gain the files", ctx do
      %{user: user, kb: kb, vault: vault} = ctx
      {_raw, token} = Slipdock.Accounts.create_api_token(user, "slipdock CLI on laptop")
      Vaults.touch_mirror(vault, token)

      assert {:ok, %{mirrors: ["slipdock CLI on laptop"]}} =
               Vaults.preview_mapping(vault, user, %{path: "/", board: kb})
    end

    test "is refused for the reasons a mapping is", ctx do
      %{user: user, kb: kb, jobs: jobs, vault: vault} = ctx
      map!(vault, user, %{path: "/", board: kb})

      assert {:error, :unprocessable_entity, "/ is already mapped in this vault"} =
               Vaults.preview_mapping(vault, user, %{path: "/", board: jobs})

      assert {:error, :unprocessable_entity, "Keystone is already mapped into a vault"} =
               Vaults.preview_mapping(vault, user, %{path: "/Again", board: kb})

      {:ok, other} = Vaults.create_vault(user, %{"name" => "Other"})

      assert {:error, :unprocessable_entity, "Keystone is already in another vault"} =
               Vaults.preview_mapping(other, user, %{path: "/", board: kb})

      assert {:error, :unprocessable_entity, _} =
               Vaults.preview_mapping(vault, user, %{path: "/../x", board: jobs})
    end

    test "taking a mapping out lists the pages that leave, and those that fall back", ctx do
      %{user: user, kb: kb, jobs: jobs, vault: vault} = ctx
      {:ok, notes} = Wiki.create_folder(kb, %{"name" => "Notes"})
      {:ok, _} = Wiki.create_page(kb, %{"title" => "Inside", "folder_id" => notes.id}, user: user)
      {:ok, _} = Wiki.create_page(jobs, %{"title" => "Acme"}, user: user)
      map!(vault, user, %{path: "/", board: kb})
      inner = map!(vault, user, %{path: "/Filed", board: kb, folder: notes})
      map!(vault, user, %{path: "/Journal", board: jobs})

      assert {:ok, gone} = Vaults.preview_unmapping(vault, "/Journal")
      assert gone.leaving == %{count: 1, sample: ["Journal/Acme.md"]}
      assert gone.moving.count == 0

      assert {:ok, back} = Vaults.preview_unmapping(vault, inner.id)
      assert back.leaving.count == 0
      assert back.moving.sample == [%{from: "Filed/Inside.md", to: "Notes/Inside.md"}]

      assert {:error, :not_found, _} = Vaults.preview_unmapping(vault, "/Nope")
    end

    test "candidates say why a board can't be mapped", ctx do
      %{user: user, kb: kb, jobs: jobs, vault: vault} = ctx
      stranger = user_fixture("lender@example.com")
      read_only = board_fixture(%{"name" => "Read only", "code" => "ro2"}, owner: stranger)
      share_fixture(read_only, user, "read")
      old = board_fixture(%{"name" => "Old", "code" => "old2"}, owner: user)
      {:ok, _} = Boards.archive_board(old)
      {:ok, other} = Vaults.create_vault(user, %{"name" => "Other"})
      map!(other, user, %{path: "/", board: jobs})
      map!(vault, user, %{path: "/", board: kb})

      reasons = vault |> Vaults.mapping_candidates(user) |> Map.new(fn {b, r} -> {b.name, r} end)

      # Mapping the same board twice in one vault is allowed.
      assert reasons["Keystone"] == nil
      assert reasons["Journal Desk"] == "is already in another vault"
      assert reasons["Read only"] == "you can't write to it"
      assert reasons["Old"] == "is archived"
    end
  end

  describe "addresses (#752)" do
    test "pages, folders and mappings by their vault paths, nested mappings too", ctx do
      %{user: user, kb: kb, jobs: jobs, vault: vault} = ctx
      {:ok, notes} = Wiki.create_folder(kb, %{"name" => "Big Ideas"})

      {:ok, idea} =
        Wiki.create_page(kb, %{"title" => "Plain text", "folder_id" => notes.id}, user: user)

      {:ok, parent} = Wiki.create_page(jobs, %{"title" => "Acme"}, user: user)

      {:ok, child} =
        Wiki.create_page(jobs, %{"title" => "Call", "parent_id" => parent.id}, user: user)

      map!(vault, user, %{path: "/", board: kb})
      jobs_map = map!(vault, user, %{path: "/Journal", board: jobs})

      addresses = Vaults.addresses(vault)
      assert addresses.pages[idea.id] == "Big Ideas/Plain text"
      # A page with pages under it is addressed by its own name, not its index.md.
      assert addresses.pages[parent.id] == "Journal/Acme"
      assert addresses.pages[child.id] == "Journal/Acme/Call"
      assert addresses.folders[notes.id] == "Big Ideas"

      assert Vaults.resolve_address(vault, "big ideas/plain text.md") == {:page, idea.id}
      assert Vaults.resolve_address(vault, "/Journal/Acme/") == {:page, parent.id}
      assert Vaults.resolve_address(vault, "Big Ideas") == {:folder, notes.id}
      assert {:mapping, %{id: id}} = Vaults.resolve_address(vault, "journal")
      assert id == jobs_map.id
      assert Vaults.resolve_address(vault, "Nope") == :error
    end
  end

  describe "a board kept inside its vault (#757)" do
    test "a whole board can be kept inside, and let out again", %{
      user: user,
      kb: kb,
      vault: vault
    } do
      mapping = map!(vault, user, %{path: "/", board: kb})
      refute mapping.inside
      assert Vaults.inside_boards(user) == %{}

      assert {:ok, %{inside: true}} = Vaults.set_inside(vault, "/", true)
      assert %{} = inside = Vaults.inside_boards(user)
      assert %Vault{name: "Notes"} = inside[kb.id]

      assert {:ok, %{inside: false}} = Vaults.set_inside(vault, mapping.id, false)
      assert Vaults.inside_boards(user) == %{}
    end

    test "only a whole board: never one folder of it", %{user: user, jobs: jobs, vault: vault} do
      {:ok, notes} = Wiki.create_folder(jobs, %{"name" => "Notes"})
      map!(vault, user, %{path: "/Journal", board: jobs, folder: notes})

      assert {:error, :unprocessable_entity, message} = Vaults.set_inside(vault, "/Journal", true)
      assert message =~ "only a whole board"
      # Letting a folder's mapping out is a no-op, not an error.
      assert {:ok, %{inside: false}} = Vaults.set_inside(vault, "/Journal", false)

      {:error, changeset} =
        Vaults.add_mapping(vault, user, %{
          path: "/Other",
          board: jobs,
          folder: notes,
          inside: true
        })

      assert changeset.errors[:inside] || changeset.errors[:folder_id]
      assert {:error, :not_found, _} = Vaults.set_inside(vault, "/Nowhere", true)
    end

    test "mapped inside from the start, and gone with the mapping or the vault", %{
      user: user,
      kb: kb,
      vault: vault
    } do
      map!(vault, user, %{path: "/", board: kb, inside: true})
      assert Map.has_key?(Vaults.inside_boards(user), kb.id)

      {:ok, _} = Vaults.remove_mapping(vault, "/")
      assert Vaults.inside_boards(user) == %{}

      map!(vault, user, %{path: "/", board: kb, inside: true})
      {:ok, _} = Vaults.delete_vault(vault)
      assert Vaults.inside_boards(user) == %{}
    end

    test "somebody else's vault keeps nothing out of your list", %{
      user: user,
      kb: kb,
      vault: vault
    } do
      map!(vault, user, %{path: "/", board: kb, inside: true})
      other = user_fixture("inside-other@example.com")
      assert Vaults.inside_boards(other) == %{}
    end

    test "a new vault with a board to hold its pages", %{user: user} do
      assert {:ok, vault} = Vaults.create_vault_with_board(user, %{"name" => "Brain"})
      assert [%{path: "", inside: true, folder_id: nil, board: board}] = vault.mappings
      assert board.name == "Brain"
      assert board.owner_id == user.id
      assert Map.has_key?(Vaults.inside_boards(user), board.id)

      # A name that won't do makes neither.
      boards = length(Slipdock.Access.list_boards(user))
      assert {:error, _} = Vaults.create_vault_with_board(user, %{"name" => "brain"})
      assert length(Slipdock.Access.list_boards(user)) == boards
    end
  end
end
