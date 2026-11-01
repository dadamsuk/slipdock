defmodule Slipdock.VaultsTest do
  @moduledoc """
  The root vault (W-2201): each person has one, made on first need, and it is
  derived from their boards. Every root board they own is a folder off the
  root, archived ones too, and a sub-board sits in its epic's folder.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Boards, Repo, Vaults, Wiki}
  alias Slipdock.Vaults.{Layout, Sync, Vault}
  alias Slipdock.Wiki.{CardFolders, QuickNote}

  setup do
    user = user_fixture()
    kb = board_fixture(%{"name" => "Keystone", "code" => "vtkb"}, owner: user)
    jobs = board_fixture(%{"name" => "Journal Desk", "code" => "vtjobs"}, owner: user)
    %{user: user, kb: kb, jobs: jobs, vault: Vaults.root(user)}
  end

  defp paths(vault), do: vault |> Vaults.boards() |> Enum.map(& &1.path)

  defp entry(vault, board), do: Enum.find(Vaults.boards(vault), &(&1.board.id == board.id))

  defp simple do
    {:ok, template} = Boards.find_template(nil, "Simple")
    template
  end

  # An epic on `board`, with a sub-board.
  defp epic!(board, title) do
    [column | _] = Boards.get_board!(board.id).columns
    card = card_fixture(column, %{"title" => title})
    {:ok, sub} = sub_board(card, simple())
    {card, Boards.get_board!(sub.id)}
  end

  describe "root/1" do
    test "makes one row however often it is asked for", %{user: user, vault: vault} do
      assert Vaults.root(user).id == vault.id
      assert Vaults.root(user.id).id == vault.id
      assert Repo.aggregate(from(v in Vault, where: v.user_id == ^user.id), :count) == 1
      assert [%Vault{id: id}] = Vaults.list_vaults(user)
      assert id == vault.id
    end

    test "the database holds one per person, whatever is asked of it (#1603)", ctx do
      assert_raise Ecto.ConstraintError, ~r/vaults_one_per_user_index/, fn ->
        Repo.insert!(%Vault{user_id: ctx.user.id, name: "Second"})
      end
    end

    test "gives each person their own", %{vault: vault} do
      other = user_fixture("root-other@example.com")
      assert Vaults.root(other).id != vault.id
      assert Vaults.root(other).shortcut
    end
  end

  describe "get_vault/2" do
    test "finds it by id or by name, case aside", %{user: user, vault: vault} do
      id = vault.id
      name = String.upcase(vault.name)
      assert {:ok, %Vault{id: ^id}} = Vaults.get_vault(user, name)
      assert {:ok, %Vault{id: ^id}} = Vaults.get_vault(user, to_string(id))
      assert {:error, :not_found, _} = Vaults.get_vault(user, "nope")
    end

    test "somebody else's is not found", %{vault: vault} do
      stranger = user_fixture("stranger@example.com")
      assert {:error, :not_found, _} = Vaults.get_vault(stranger, vault.id)
    end
  end

  describe "update_vault/2" do
    test "renames it, and a blank name or a slash is refused", %{vault: vault} do
      assert {:ok, %Vault{name: "Brain"}} = Vaults.update_vault(vault, %{"name" => "Brain"})
      assert {:error, cs} = Vaults.update_vault(vault, %{"name" => "  "})
      assert errors_on(cs).name != []
      assert {:error, cs} = Vaults.update_vault(vault, %{"name" => "a/b"})
      assert "cannot contain a slash" in errors_on(cs).name
    end
  end

  describe "the boards in it" do
    test "every root board its owner has is a folder off the root", ctx do
      assert paths(ctx.vault) == ["Journal Desk", "Keystone"]
      assert Enum.sort(Vaults.board_ids(ctx.vault)) == Enum.sort([ctx.kb.id, ctx.jobs.id])
      assert Vaults.for_board(ctx.kb).id == ctx.vault.id
      assert Vaults.in_vault?(ctx.jobs)
    end

    test "a new board shows with no other call", ctx do
      board_fixture(%{"name" => "Fresh", "code" => "vtfresh"}, owner: ctx.user)
      assert "Fresh" in paths(ctx.vault)
    end

    test "a rename moves its folder with no other call", ctx do
      {:ok, page} = Wiki.create_page(ctx.kb, %{"title" => "Kept"}, user: ctx.user)
      {:ok, _} = Boards.update_board(ctx.kb, %{"name" => "Cornerstone"})

      assert paths(ctx.vault) == ["Cornerstone", "Journal Desk"]
      assert Vaults.addresses(ctx.vault).pages[page.id] == "Cornerstone/Kept"
    end

    test "archived is a flag, and the path stays the same through it and back", ctx do
      {:ok, page} = Wiki.create_page(ctx.kb, %{"title" => "Kept"}, user: ctx.user)
      refute entry(ctx.vault, ctx.kb).board.archived_at

      {:ok, archived} = Boards.archive_board(ctx.kb)
      assert entry(ctx.vault, ctx.kb).path == "Keystone"
      assert entry(ctx.vault, ctx.kb).board.archived_at
      assert Vaults.addresses(ctx.vault).pages[page.id] == "Keystone/Kept"

      {:ok, _} = Boards.unarchive_board(archived)
      assert entry(ctx.vault, ctx.kb).path == "Keystone"
      refute entry(ctx.vault, ctx.kb).board.archived_at
    end

    test "a deleted board goes, its vault staying", ctx do
      {:ok, _} = Boards.delete_board(ctx.kb)
      assert paths(ctx.vault) == ["Journal Desk"]
    end

    test "two boards clashing case aside are numbered, the oldest plain", ctx do
      second = board_fixture(%{"name" => "KEYSTONE", "code" => "vtkb2"}, owner: ctx.user)
      third = board_fixture(%{"name" => "keystone", "code" => "vtkb3"}, owner: ctx.user)

      assert entry(ctx.vault, ctx.kb).path == "Keystone"
      assert entry(ctx.vault, second).path == "KEYSTONE (2)"
      assert entry(ctx.vault, third).path == "keystone (3)"
    end

    test "a board somebody else shared is not in it", ctx do
      stranger = user_fixture("lender@example.com")
      lent = board_fixture(%{"name" => "Lent", "code" => "vtlent"}, owner: stranger)
      share_fixture(lent, ctx.user, "write")

      refute "Lent" in paths(ctx.vault)
      refute lent.id in Vaults.board_ids(ctx.vault)
      assert Vaults.for_board(lent).id == Vaults.root(stranger).id
      assert {:error, :not_found, _} = Vaults.locate(ctx.vault, "/Lent/x.md")
    end

    test "for_board answers with the top owner's vault for a sub-board", ctx do
      {_epic, sub} = epic!(ctx.kb, "Epic")
      {_inner, deeper} = epic!(sub, "Inner")

      assert Vaults.for_board(sub).id == ctx.vault.id
      assert Vaults.for_board(deeper).id == ctx.vault.id
      assert sub.id in Vaults.board_ids(ctx.vault)
      assert deeper.id in Vaults.board_ids(ctx.vault)
    end

    test "an empty vault counts nothing, a live page once, an archived one not", ctx do
      assert Vaults.page_count(ctx.vault) == 0
      {:ok, _} = Wiki.create_page(ctx.kb, %{"title" => "One"}, user: ctx.user)
      {:ok, gone} = Wiki.create_page(ctx.jobs, %{"title" => "Gone"}, user: ctx.user)
      {:ok, _} = Wiki.archive_page(gone)
      assert Vaults.page_count(ctx.vault) == 1
    end
  end

  describe "a sub-board in its epic's folder" do
    test "without a folder row, the way down is laid out all the same", ctx do
      {_epic, sub} = epic!(ctx.kb, "Launch")
      {_inner, deeper} = epic!(sub, "Press")
      {:ok, page} = Wiki.create_page(deeper, %{"title" => "Note"}, user: ctx.user)

      assert entry(ctx.vault, sub).path == "Keystone/Cards/Launch"
      assert entry(ctx.vault, deeper).path == "Keystone/Cards/Launch/Cards/Press"

      layout = Layout.build(ctx.vault)
      assert layout.pages[page.id].path == "Keystone/Cards/Launch/Cards/Press/Note.md"
    end

    test "with a real card folder for the epic, it shares that directory", ctx do
      {epic, sub} = epic!(ctx.kb, "Launch")
      {:ok, folder} = CardFolders.ensure(epic)
      {inner, deeper} = epic!(sub, "Press")
      {:ok, inner_folder} = CardFolders.ensure(inner)
      {:ok, page} = Wiki.create_page(deeper, %{"title" => "Note"}, user: ctx.user)

      dirs = Layout.dirs(ctx.vault)
      assert dirs.folders[folder.id] == "Keystone/Cards/Launch"
      assert dirs.boards[sub.id] == "Keystone/Cards/Launch"
      assert dirs.folders[inner_folder.id] == "Keystone/Cards/Launch/Cards/Press"
      assert dirs.boards[deeper.id] == "Keystone/Cards/Launch/Cards/Press"

      layout = Layout.build(ctx.vault)
      assert layout.pages[page.id].path == "Keystone/Cards/Launch/Cards/Press/Note.md"
    end

    test "writing to the path lands on the deep board, with no folder rows", ctx do
      {_epic, sub} = epic!(ctx.kb, "Launch")
      {_inner, deeper} = epic!(sub, "Press")

      assert {:ok, entry} =
               Sync.write_page(ctx.vault, ctx.user, %{
                 "path" => "Keystone/Cards/Launch/Cards/Press/page.md",
                 "content" => "Words"
               })

      assert entry.path == "Keystone/Cards/Launch/Cards/Press/page.md"
      assert Wiki.get_page(entry.id).board_id == deeper.id
    end

    test "writing to the path lands on the deep board, with real folder rows", ctx do
      {epic, sub} = epic!(ctx.kb, "Launch")
      {:ok, _} = CardFolders.ensure(epic)
      {inner, deeper} = epic!(sub, "Press")
      {:ok, folder} = CardFolders.ensure(inner)

      assert {:ok, entry} =
               Sync.write_page(ctx.vault, ctx.user, %{
                 "path" => "Keystone/Cards/Launch/Cards/Press/page.md",
                 "content" => "Words"
               })

      page = Wiki.get_page(entry.id)
      assert entry.path == "Keystone/Cards/Launch/Cards/Press/page.md"
      # The folder answers for the directory it shares with the sub-board.
      assert page.board_id == sub.id
      assert page.folder_id == folder.id
      refute page.board_id == deeper.id
    end

    test "a page in the sub-board's own folder keeps its path through a write", ctx do
      {_epic, sub} = epic!(ctx.kb, "Launch")

      assert {:ok, entry} =
               Sync.write_page(ctx.vault, ctx.user, %{
                 "path" => "Keystone/Cards/Launch/page.md",
                 "content" => "Words"
               })

      assert Wiki.get_page(entry.id).board_id == sub.id
    end
  end

  describe "writing" do
    test "at the vault's root is refused", ctx do
      assert {:error, :unprocessable_entity, message} =
               Sync.write_page(ctx.vault, ctx.user, %{"path" => "Stray.md", "content" => "x"})

      assert message =~ "root"
    end

    test "to a path with no such board is refused", ctx do
      assert {:error, :unprocessable_entity, message} =
               Sync.write_page(ctx.vault, ctx.user, %{
                 "path" => "Nowhere/Stray.md",
                 "content" => "x"
               })

      assert message =~ "Nowhere"
      assert Repo.aggregate(Wiki.Page, :count) == 0
    end

    test "to a board's folder makes the page there", ctx do
      assert {:ok, entry} =
               Sync.write_page(ctx.vault, ctx.user, %{
                 "path" => "Journal Desk/Acme/Call.md",
                 "content" => "x"
               })

      assert Wiki.get_page(entry.id).board_id == ctx.jobs.id
    end
  end

  describe "locate/2" do
    test "answers with the board and the rest", %{vault: vault, kb: kb, jobs: jobs} do
      jobs_id = jobs.id
      assert {:ok, ^jobs_id, "Acme/Call.md"} = Vaults.locate(vault, "/Journal Desk/Acme/Call.md")
      assert {:ok, ^jobs_id, ""} = Vaults.locate(vault, "journal desk")
      kb_id = kb.id
      assert {:ok, ^kb_id, "Ideas.md"} = Vaults.locate(vault, "/Keystone/Ideas.md")
    end

    test "the deepest board wins", ctx do
      {_epic, sub} = epic!(ctx.kb, "Launch")
      id = sub.id
      assert {:ok, ^id, "Note.md"} = Vaults.locate(ctx.vault, "/Keystone/Cards/Launch/Note.md")
    end

    test "matches whole segments", %{vault: vault} do
      assert {:error, :not_found, _} = Vaults.locate(vault, "/Keystones/x.md")
    end

    test "the root and a path that climbs are not in a board", %{vault: vault} do
      assert {:error, :not_found, _} = Vaults.locate(vault, "/")
      assert {:error, :not_found, _} = Vaults.locate(vault, "/x.md")
      assert {:error, :unprocessable_entity, _} = Vaults.locate(vault, "/Keystone/../x")
    end
  end

  describe "normalize_path/1" do
    test "stores paths without slashes and refuses a climb" do
      assert {:error, :unprocessable_entity, _} = Vaults.normalize_path("./x")
      assert {:ok, "a/b"} = Vaults.normalize_path("\\a\\\\b\\")
      assert {:ok, ""} = Vaults.normalize_path(nil)
    end
  end

  describe "addresses (#752)" do
    test "pages, folders and boards by their vault paths", ctx do
      %{user: user, kb: kb, jobs: jobs, vault: vault} = ctx
      {:ok, notes} = Wiki.create_folder(kb, %{"name" => "Big Ideas"})

      {:ok, idea} =
        Wiki.create_page(kb, %{"title" => "Plain text", "folder_id" => notes.id}, user: user)

      {:ok, parent} = Wiki.create_page(jobs, %{"title" => "Acme"}, user: user)

      {:ok, child} =
        Wiki.create_page(jobs, %{"title" => "Call", "parent_id" => parent.id}, user: user)

      addresses = Vaults.addresses(vault)
      assert addresses.pages[idea.id] == "Keystone/Big Ideas/Plain text"
      # A page with pages under it is addressed by its own name, not its index.md.
      assert addresses.pages[parent.id] == "Journal Desk/Acme"
      assert addresses.pages[child.id] == "Journal Desk/Acme/Call"
      assert addresses.folders[notes.id] == "Keystone/Big Ideas"
      assert addresses.boards[kb.id] == "Keystone"

      assert Vaults.resolve_address(vault, "keystone/big ideas/plain text.md") == {:page, idea.id}
      assert Vaults.resolve_address(vault, "/Journal Desk/Acme/") == {:page, parent.id}
      assert Vaults.resolve_address(vault, "Keystone/Big Ideas") == {:folder, notes.id}
      assert Vaults.resolve_address(vault, "journal desk") == {:board, jobs.id}
      assert Vaults.resolve_address(vault, "Nope") == :error
    end
  end

  describe "links" do
    test "a link finds a page on another board of the root", ctx do
      {:ok, target} = Wiki.create_page(ctx.jobs, %{"title" => "Far Note"}, user: ctx.user)

      assert {:ok, page, "Journal Desk/Far Note"} =
               Vaults.resolve_link(ctx.vault, "[[Far Note]]", ctx.user)

      assert page.id == target.id

      {:ok, linker} =
        Wiki.create_page(ctx.kb, %{"title" => "Linker", "body" => "[[Far Note]]"}, user: ctx.user)

      assert Enum.map(Wiki.outgoing_links(linker), & &1.target_page_id) == [target.id]
    end

    test "the page's own board still wins", ctx do
      {:ok, far} = Wiki.create_page(ctx.jobs, %{"title" => "Same"}, user: ctx.user)
      {:ok, near} = Wiki.create_page(ctx.kb, %{"title" => "Same"}, user: ctx.user)

      {:ok, kb_linker} =
        Wiki.create_page(ctx.kb, %{"title" => "L1", "body" => "[[Same]]"}, user: ctx.user)

      {:ok, jobs_linker} =
        Wiki.create_page(ctx.jobs, %{"title" => "L2", "body" => "[[Same]]"}, user: ctx.user)

      assert Enum.map(Wiki.outgoing_links(kb_linker), & &1.target_page_id) == [near.id]
      assert Enum.map(Wiki.outgoing_links(jobs_linker), & &1.target_page_id) == [far.id]
    end
  end

  describe "what hangs off the vault" do
    test "a quick note goes to a board's folder in the root", ctx do
      {:ok, inbox} = Wiki.create_folder(ctx.kb, %{"name" => "Inbox"})
      assert QuickNote.vault(ctx.user).id == ctx.vault.id

      places = QuickNote.places(ctx.vault, ctx.user)
      assert %{folder_id: id} = Enum.find(places, &(&1.path == "Keystone/Inbox"))
      assert id == inbox.id
      assert Enum.find(places, &(&1.path == "Keystone")).folder_id == nil

      {:ok, user} =
        Slipdock.Accounts.update_quick_note(ctx.user, %{
          quick_note_vault_id: ctx.vault.id,
          quick_note_folder: "Keystone/Inbox"
        })

      Slipdock.AIStub.reply_with(%{"title" => "Printers"})
      assert {:ok, note} = QuickNote.save(user, "Ring the printers")
      assert note.page.board_id == ctx.kb.id
      assert note.page.folder_id == inbox.id
      assert note.vault.id == ctx.vault.id
    end

    test "the recordings folder is set on the root and read from a board in it", ctx do
      Slipdock.GoogleStub.connect!(ctx.user)

      Slipdock.GoogleStub.drive!([
        %{
          "id" => "fold",
          "name" => "Meeting Recordings",
          "mimeType" => "application/vnd.google-apps.folder",
          "parents" => ["root"]
        }
      ])

      assert {:ok, %{recordings_folder: "Meeting Recordings"}} =
               Vaults.set_recordings_folder(ctx.vault, "Meeting Recordings")

      assert Vaults.for_board(ctx.kb).recordings_folder == "Meeting Recordings"
      assert {:ok, %{recordings_folder: nil}} = Vaults.set_recordings_folder(ctx.vault, "")
    end

    test "a sync token is recorded once, with its label and the last time", ctx do
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
    end
  end
end
