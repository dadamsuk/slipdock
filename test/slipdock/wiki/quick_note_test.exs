defmodule Slipdock.Wiki.QuickNoteTest do
  @moduledoc "Quick notes (#1538): the name, the place, and what happens without a model."
  use Slipdock.DataCase, async: true

  import ExUnit.CaptureLog
  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Vaults, Wiki}
  alias Slipdock.Wiki.{Folders, QuickNote}

  @at ~U[2026-10-30 15:39:12Z]

  setup do
    user = user_fixture()
    board = board_fixture(%{"name" => "Brain QN"})
    {:ok, inbox} = Wiki.create_folder(board, %{"name" => "Inbox"})
    {:ok, projects} = Wiki.create_folder(board, %{"name" => "Projects"})
    {:ok, acme} = Wiki.create_folder(board, %{"name" => "Acme", "parent_id" => projects.id})
    {:ok, vault} = user |> Vaults.root() |> Vaults.update_vault(%{"name" => "Mind"})
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
        "folder" => "brain qn/projects/ACME"
      })

      assert {:ok, note} = save(ctx.user)
      assert note.page.title == "2026-10-30 15.39 Printers banners call"
      assert note.page.body == "Ring the printers about the banners"
      assert note.page.folder_id == ctx.acme.id
      assert note.location == "Brain QN/Projects/Acme"
      assert note.placed_by == :ai
      assert note.vault.id == ctx.vault.id

      assert_received {:ai_request, %{"messages" => [_, %{"content" => shown}]}}
      assert shown =~ "- Brain QN/Projects/Acme"
      assert shown =~ "Ring the printers"
    end

    test "the time is the writer's own", ctx do
      {:ok, user} = Accounts.update_profile(ctx.user, %{timezone: "Asia/Tokyo"})
      Slipdock.AIStub.reply_with(%{"title" => "Late"})

      assert {:ok, note} = save(user)
      assert note.page.title == "2026-10-31 00.39 Late"
    end

    test "the model may add one folder under a real one", ctx do
      Slipdock.AIStub.reply_with(%{"title" => "Beta", "folder" => "Brain QN/Projects/Beta"})

      assert {:ok, note} = save(ctx.user)
      assert note.location == "Brain QN/Projects/Beta"
      assert {:ok, folder} = Folders.find(ctx.board, "Projects/Beta")
      assert note.page.folder_id == folder.id
    end

    test "a folder it made up, or one that climbs, lands at the setting", ctx do
      user = at_home(ctx.user, ctx.vault, "Brain QN/Inbox")

      for path <- ["Nowhere", "Nowhere/Deeper", "", "/", "../Brain QN/Projects", 7] do
        Slipdock.AIStub.reply_sequence([
          %{"title" => "Lost", "folder" => path},
          %{"title" => "Lost", "folder" => path}
        ])

        assert {:ok, note} = save(user)
        assert note.page.folder_id == ctx.inbox.id, inspect(path)
        assert note.placed_by == :settings
      end

      assert {:error, :not_found, _} = Folders.find(ctx.board, "Nowhere")
    end

    test "a path too deep stops at the last real place on it", ctx do
      Slipdock.AIStub.reply_with(%{"title" => "Deep", "folder" => "Brain QN/Projects/New/Deeper"})

      assert {:ok, note} = save(ctx.user)
      assert note.location == "Brain QN/Projects"
      assert note.placed_by == :ai
      assert {:error, :not_found, _} = Folders.find(ctx.board, "Projects/New")
    end

    test "the examples copied along with a folder are dropped", ctx do
      Slipdock.AIStub.reply_with(%{
        "title" => "T",
        "folder" => ~s(Brain QN/Projects/Acme (e.g. "A"; "B"\))
      })

      assert {:ok, note} = save(ctx.user)
      assert note.page.folder_id == ctx.acme.id
    end

    test "with nothing usable it asks once more, and the second answer counts", ctx do
      Slipdock.AIStub.reply_sequence([
        %{"title" => "First title"},
        %{"folder" => "Brain QN/Projects/Acme"}
      ])

      assert {:ok, note} = save(ctx.user)
      assert note.page.folder_id == ctx.acme.id
      assert note.placed_by == :ai
      assert note.page.title == "2026-10-30 15.39 First title"

      assert_received {:ai_request, %{"messages" => first}}
      assert_received {:ai_request, %{"messages" => second}}
      assert length(second) == length(first) + 2
      refute_received {:ai_request, _}
    end

    test "a good first answer is not asked for twice", ctx do
      Slipdock.AIStub.reply_with(%{"title" => "T", "folder" => "Brain QN/Inbox"})

      assert {:ok, _} = save(ctx.user)
      assert_received {:ai_request, _}
      refute_received {:ai_request, _}
    end

    test "the top of the vault is not offered, and a folder is required", ctx do
      Slipdock.AIStub.reply_with(%{"title" => "T", "folder" => "Brain QN/Inbox"})
      assert {:ok, _} = save(ctx.user)

      assert_received {:ai_request, %{"messages" => [system, %{"content" => shown}]}}
      refute shown =~ "top of the vault"
      assert system["content"] =~ "always give one"
      refute system["content"] =~ "Leave it out"
    end

    test "a second board takes notes, new folders too", ctx do
      jobs = board_fixture(%{"name" => "Jobs QN"})
      {:ok, nourish} = Wiki.create_folder(jobs, %{"name" => "Nourish"})

      Slipdock.AIStub.reply_with(%{"title" => "Call", "folder" => "Jobs QN/Nourish"})
      assert {:ok, note} = save(ctx.user)
      assert note.page.board_id == jobs.id
      assert note.page.folder_id == nourish.id
      assert_received {:ai_request, %{"messages" => [_, %{"content" => shown}]}}
      assert shown =~ "- Jobs QN/Nourish"

      Slipdock.AIStub.reply_with(%{"title" => "Call", "folder" => "Jobs QN/Acme"})
      assert {:ok, note} = save(ctx.user)
      assert note.location == "Jobs QN/Acme"
      assert note.page.board_id == jobs.id
      assert {:ok, _} = Folders.find(jobs, "Acme")
    end

    test "a title that isn't fit for a file name is cleaned", ctx do
      Slipdock.AIStub.reply_with(%{"title" => "a/b: [[c]] #d\nand a very long line of words"})

      assert {:ok, note} = save(ctx.user)
      assert note.page.title == "2026-10-30 15.39 a b c d and a"
      assert Vaults.addresses(ctx.vault).pages[note.page.id] == "Brain QN/" <> note.page.title
    end
  end

  describe "without a usable answer" do
    test "a model that fails still saves the note, at the setting", ctx do
      Slipdock.AIStub.fail_with(500, "down")
      user = at_home(ctx.user, ctx.vault, "Brain QN/Inbox")

      log =
        capture_log(fn ->
          assert {:ok, note} = save(user, "First line here\nsecond line")
          send(self(), {:note, note})
        end)

      assert log =~ "Quick note"
      refute log =~ "First line here"
      assert_received {:note, note}
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

    test "a setting that has gone falls back to the first board", ctx do
      Slipdock.AIStub.reply_with(%{"title" => "T"})
      user = at_home(ctx.user, ctx.vault, "Renamed since")

      assert {:ok, note} = save(user)
      assert note.location == "Brain QN"
      assert note.page.board_id == ctx.board.id
      assert note.page.folder_id == nil
    end
  end

  describe "refused" do
    test "an empty note writes nothing", ctx do
      assert {:error, :unprocessable_entity, message} = save(ctx.user, "  \n ")
      assert message =~ "something"
      assert Wiki.list_pages(ctx.board) == []
    end

    test "somebody with no boards has nowhere to put one" do
      user = user_fixture("novault@example.com")
      assert {:error, :unprocessable_entity, message} = save(user)
      assert message =~ "can be written to"
    end

    test "boards a token can't write to are no place for it", ctx do
      assert {:error, :unprocessable_entity, message} =
               save(ctx.user, "Text", allow: fn _board -> false end)

      assert message =~ "Mind"
      assert Wiki.list_pages(ctx.board) == []
    end

    test "a vault id that isn't theirs is ignored", ctx do
      other = user_fixture("othervault@example.com")
      {:ok, theirs} = other |> Vaults.root() |> Vaults.update_vault(%{"name" => "Theirs"})
      {:ok, user} = Accounts.update_quick_note(ctx.user, %{quick_note_vault_id: theirs.id})

      assert QuickNote.vault(user).id == ctx.vault.id
    end
  end

  test "places lists the board and its folders, top first", ctx do
    assert [%{path: "Brain QN", folder_id: nil} | rest] = QuickNote.places(ctx.vault, ctx.user)

    assert Enum.map(rest, & &1.path) ==
             ["Brain QN/Inbox", "Brain QN/Projects", "Brain QN/Projects/Acme"]
  end
end
