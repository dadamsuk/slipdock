defmodule Slipdock.Wiki.QuickNoteTest do
  @moduledoc "Quick notes (#1538): the name, the place, and what happens without a model."
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Repo, Vaults, Wiki}
  alias Slipdock.Wiki.{Folders, QuickNote}

  @at ~U[2026-10-30 15:39:12Z]

  setup do
    user = user_fixture()
    board = board_fixture(%{"name" => "Brain QN"})
    {:ok, inbox} = Wiki.create_folder(board, %{"name" => "Inbox"})
    {:ok, projects} = Wiki.create_folder(board, %{"name" => "Projects"})
    {:ok, acme} = Wiki.create_folder(board, %{"name" => "Acme", "parent_id" => projects.id})
    {:ok, vault} = Vaults.create_vault(user, %{"name" => "Mind"})
    {:ok, _} = Vaults.add_mapping(vault, user, %{path: "/", board: board})
    %{user: user, board: board, vault: vault, inbox: inbox, acme: acme}
  end

  defp save(user, text \\ "Ring the printers about the banners", opts \\ []),
    do: QuickNote.save(user, text, [at: @at] ++ opts)

  defp at_home(user, vault, path) do
    {:ok, user} =
      Accounts.update_quick_note(user, %{quick_note_vault_id: vault.id, quick_note_folder: path})

    user
  end

  describe "with a model" do
    test "the model's title and folder make the page", ctx do
      Slipdock.AIStub.reply_with(%{
        "title" => "Printers banners call",
        "folder" => "projects/ACME"
      })

      assert {:ok, note} = save(ctx.user)
      assert note.page.title == "2026-10-30 15.39 Printers banners call"
      assert note.page.body == "Ring the printers about the banners"
      assert note.page.folder_id == ctx.acme.id
      assert note.location == "Projects/Acme"
      assert note.placed_by == :ai
      assert note.vault.id == ctx.vault.id

      assert_received {:ai_request, %{"messages" => [_, %{"content" => shown}]}}
      assert shown =~ "- Projects/Acme"
      assert shown =~ "Ring the printers"
    end

    test "the time is the writer's own", ctx do
      {:ok, user} = Accounts.update_profile(ctx.user, %{timezone: "Asia/Tokyo"})
      Slipdock.AIStub.reply_with(%{"title" => "Late"})

      assert {:ok, note} = save(user)
      assert note.page.title == "2026-10-31 00.39 Late"
    end

    test "the model may add one folder under a real one", ctx do
      Slipdock.AIStub.reply_with(%{"title" => "Beta", "folder" => "Projects/Beta"})

      assert {:ok, note} = save(ctx.user)
      assert note.location == "Projects/Beta"
      assert {:ok, folder} = Folders.find(ctx.board, "Projects/Beta")
      assert note.page.folder_id == folder.id
    end

    test "a folder it made up, or one that climbs, lands at the setting", ctx do
      user = at_home(ctx.user, ctx.vault, "Inbox")

      for path <- ["Nowhere", "Nowhere/Deeper", "Projects/New/Deeper", "../Projects", 7] do
        Slipdock.AIStub.reply_with(%{"title" => "Lost", "folder" => path})
        assert {:ok, note} = save(user)
        assert note.page.folder_id == ctx.inbox.id, inspect(path)
        assert note.placed_by == :settings
      end

      assert {:error, :not_found, _} = Folders.find(ctx.board, "Nowhere")
    end

    test "a title that isn't fit for a file name is cleaned", ctx do
      Slipdock.AIStub.reply_with(%{"title" => "a/b: [[c]] #d\nand a very long line of words"})

      assert {:ok, note} = save(ctx.user)
      assert note.page.title == "2026-10-30 15.39 a b c d and a"
      assert Vaults.addresses(ctx.vault).pages[note.page.id] == note.page.title
    end
  end

  describe "without a usable answer" do
    test "a model that fails still saves the note, at the setting", ctx do
      Slipdock.AIStub.fail_with(500, "down")
      user = at_home(ctx.user, ctx.vault, "Inbox")

      assert {:ok, note} = save(user, "First line here\nsecond line")
      assert note.page.title == "2026-10-30 15.39 First line here"
      assert note.page.body == "First line here\nsecond line"
      assert note.page.folder_id == ctx.inbox.id
      assert note.placed_by == :settings
    end

    test "a note with no usable words is still named", ctx do
      Slipdock.AIStub.reply_with("not json")
      assert {:ok, note} = save(ctx.user, "???")
      assert note.page.title == "2026-10-30 15.39 Note"
    end

    test "a setting that has gone falls back to the top", ctx do
      Slipdock.AIStub.reply_with(%{"title" => "T"})
      user = at_home(ctx.user, ctx.vault, "Renamed since")

      assert {:ok, note} = save(user)
      assert note.location == ""
      assert note.page.folder_id == nil
    end
  end

  describe "refused" do
    test "an empty note writes nothing", ctx do
      assert {:error, :unprocessable_entity, message} = save(ctx.user, "  \n ")
      assert message =~ "something"
      assert Wiki.list_pages(ctx.board) == []
    end

    test "nobody with no vault can save one" do
      user = user_fixture("novault@example.com")
      assert {:error, :unprocessable_entity, message} = save(user)
      assert message =~ "vault"
    end

    test "boards a token can't write to are no place for it", ctx do
      assert {:error, :unprocessable_entity, message} =
               save(ctx.user, "Text", allow: fn _board -> false end)

      assert message =~ "Mind"
      assert Wiki.list_pages(ctx.board) == []
    end

    test "a vault id that isn't theirs is ignored", ctx do
      other = user_fixture("othervault@example.com")
      {:ok, theirs} = Vaults.create_vault(other, %{"name" => "Theirs"})
      {:ok, user} = Accounts.update_quick_note(ctx.user, %{quick_note_vault_id: theirs.id})

      assert QuickNote.vault(user).id == ctx.vault.id
    end
  end

  test "deleting the vault clears the setting", ctx do
    user = at_home(ctx.user, ctx.vault, "Inbox")
    {:ok, _} = Vaults.delete_vault(ctx.vault)

    assert Repo.reload!(user).quick_note_vault_id == nil
  end

  test "places lists the mapping and its folders, top first", ctx do
    assert [%{path: ""} | rest] = QuickNote.places(ctx.vault, ctx.user)
    assert Enum.map(rest, & &1.path) == ["Inbox", "Projects", "Projects/Acme"]
  end
end
