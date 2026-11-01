defmodule Slipdock.WikiCardFoldersTest do
  @moduledoc "A card's own folder (W-2201 rules 3 and 4)."
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Boards, Repo, Vaults, Wiki}
  alias Slipdock.Boards.Card
  alias Slipdock.Vaults.{Layout, Sync}
  alias Slipdock.Wiki.{Archive, CardFolders, Changes, Folder, Page}

  @long "Agent supervision 5/9: Parked jobs must be released on timeout"

  setup do
    user = user_fixture()
    board = board_fixture(%{"name" => "Folders"}, owner: user)
    card = card_fixture(hd(board.columns), %{"title" => "Fix the thing"})
    %{user: user, board: board, card: card}
  end

  defp write_up(card, user, opts \\ []) do
    {:ok, page} = Wiki.create_page_from_card(card, [user: user] ++ opts)
    Repo.get!(Page, page.id)
  end

  defp folders(board), do: Repo.all(from(f in Folder, where: f.board_id == ^board.id))

  describe "a write-up's file" do
    defp vault_path(user, page) do
      Layout.build(Vaults.root(user)).pages[page.id].path
    end

    defp long_card(board) do
      card_fixture(hd(board.columns), %{"title" => @long})
    end

    test "keeps the page's title and takes the card's short name on disk",
         %{board: board, user: user} do
      card = long_card(board)
      page = write_up(card, user)

      assert page.title == @long
      assert page.file_name == nil

      assert vault_path(user, page) ==
               "Folders/Cards/#{card.short_name}/#{card.short_name}.md"
    end

    test "with no short name, the title it shares with the folder", ctx do
      page = write_up(ctx.card, ctx.user)
      assert vault_path(ctx.user, page) == "Folders/Cards/Fix the thing/Fix the thing.md"
    end

    test "follows a new short name, and the feed says so", %{board: board, user: user} do
      card = long_card(board)
      page = write_up(card, user)
      vault = Vaults.root(user)
      cursor = Changes.since(vault, nil, user).cursor
      was = vault_path(user, page)

      {:ok, _} = Boards.update_card(Repo.get!(Card, card.id), %{"short_name" => "Parked jobs"})

      assert vault_path(user, page) == "Folders/Cards/Parked jobs/Parked jobs.md"

      assert %{from_path: ^was, path: "Folders/Cards/Parked jobs/Parked jobs.md"} =
               Enum.find(
                 Changes.since(vault, cursor, user).changes,
                 &(&1.subject == "page" and &1.id == page.id)
               )
    end

    test "goes back to its own title when the card is retitled", ctx do
      page = write_up(ctx.card, ctx.user)
      {:ok, _} = Boards.update_card(Repo.get!(Card, ctx.card.id), %{"title" => "Renamed"})

      assert vault_path(ctx.user, page) == "Folders/Cards/Renamed/Fix the thing.md"
    end

    test "only the page titled like the card", %{board: board, user: user} do
      card = long_card(board)
      other = write_up(card, user, title: "Notes")
      assert vault_path(user, other) == "Folders/Cards/#{card.short_name}/Notes.md"
    end

    test "not a child page titled like the card", %{board: board, user: user} do
      card = long_card(board)
      parent = write_up(card, user, title: "Parent")
      child = write_up(card, user, title: @long, parent: parent.id)
      dir = "Folders/Cards/#{card.short_name}/Parent"

      assert String.starts_with?(vault_path(user, child), dir <> "/Agent supervision 5-9")
    end

    test "a second page titled like the card is numbered", %{board: board, user: user} do
      card = long_card(board)
      write_up(card, user)
      second = write_up(card, user)

      assert vault_path(user, second) ==
               "Folders/Cards/#{card.short_name}/#{card.short_name} (2).md"
    end

    test "a page with children takes it too", %{board: board, user: user} do
      card = long_card(board)
      page = write_up(card, user)
      write_up(card, user, title: "Child", parent: page.id)

      assert vault_path(user, page) ==
               "Folders/Cards/#{card.short_name}/#{card.short_name}/index.md"
    end

    test "a name the file was given is kept", %{board: board, user: user} do
      card = long_card(board)
      page = write_up(card, user)
      {:ok, page} = Wiki.update_page(page, %{"file_name" => "My note"}, user: user)

      assert vault_path(user, page) == "Folders/Cards/#{card.short_name}/My note.md"
    end

    test "the same page in another folder is its title", %{board: board, user: user} do
      card = long_card(board)
      {:ok, folder} = Wiki.create_folder(board, %{"name" => "Elsewhere"})
      page = write_up(card, user, folder: folder.id)

      assert String.starts_with?(vault_path(user, page), "Folders/Elsewhere/Agent supervision")
    end

    test "the export agrees, and a round trip keeps the title", %{board: board, user: user} do
      card = long_card(board)
      write_up(card, user)
      files = Map.new(Archive.files(board))
      path = "Cards/#{card.short_name}/#{card.short_name}.md"

      assert files[path] =~ "title: #{@long}"

      other = board_fixture(%{"name" => "Back"}, owner: user)
      assert %{skipped: []} = Archive.import_files(other, Map.to_list(files), user: user)
      assert [%Page{title: @long}] = Wiki.list_pages(other)
    end

    test "the export's child pages are not touched", %{board: board, user: user} do
      card = long_card(board)
      parent = write_up(card, user, title: "Parent")
      write_up(card, user, title: @long, parent: parent.id)

      assert Enum.any?(Archive.files(board), fn {path, _} ->
               String.starts_with?(
                 path,
                 "Cards/#{card.short_name}/Parent/Agent supervision 5-9"
               )
             end)
    end

    test "a link finds it by its whole title, never the shortened name (W-2201 rule 5)",
         %{board: board, user: user} do
      title = "Parked jobs must be released when their lease runs out"
      card = card_fixture(hd(board.columns), %{"title" => title})
      page = write_up(card, user)
      index = Vaults.Index.build(Vaults.root(user))

      assert card.short_name
      assert [%{id: id}] = Vaults.Index.match(index, title)
      assert id == page.id
      assert Vaults.Index.match(index, card.short_name) == []
    end

    test "an edit synced back at the same path changes nothing of its name",
         %{board: board, user: user} do
      card = long_card(board)
      page = write_up(card, user)
      vault = Vaults.root(user)
      path = vault_path(user, page)

      {:ok, %{hash: base}} = Sync.read_page(vault, user, page.id)

      assert {:ok, _} =
               Sync.write_page(vault, user, %{
                 "id" => page.id,
                 "path" => path,
                 "content" => "edited\n",
                 "base" => base
               })

      saved = Repo.get!(Page, page.id)
      assert saved.title == @long
      assert saved.body =~ "edited"
      assert saved.file_name == nil
      assert vault_path(user, saved) == path
    end

    test "a card moved off the board leaves the page its title", %{board: board, user: user} do
      card = long_card(board)
      page = write_up(card, user)
      other = board_fixture(%{"name" => "Other"}, owner: user)
      {:ok, _} = Boards.move_card_to_board(Repo.get!(Card, card.id), hd(other.columns))
      CardFolders.find(Repo.get!(Card, card.id))

      assert vault_path(user, page) =~ ~r{\AFolders/Cards/.*/Agent supervision 5-9}
    end
  end

  describe "the folder" do
    test "isn't made until the card gets a page", %{board: board, card: card} do
      assert card.id
      assert folders(board) == []
    end

    test "is made on the first page, under Cards, tied to the card",
         %{board: board, card: card, user: user} do
      page = write_up(card, user)
      folder = Repo.get!(Folder, page.folder_id)

      assert folder.card_id == card.id
      assert folder.name == "Fix the thing"
      assert Repo.get!(Folder, folder.parent_id).name == "Cards"
      assert length(folders(board)) == 2
    end

    test "is reused by the second page", %{board: board, card: card, user: user} do
      first = write_up(card, user, title: "One")
      second = write_up(card, user, title: "Two")

      assert first.folder_id == second.folder_id
      assert length(folders(board)) == 2
    end

    test "shares one Cards folder between cards", %{board: board, card: card, user: user} do
      other = card_fixture(hd(board.columns), %{"title" => "Other"})
      a = Repo.get!(Folder, write_up(card, user).folder_id)
      b = Repo.get!(Folder, write_up(other, user).folder_id)

      assert a.parent_id == b.parent_id
    end

    test "uses a Cards folder that's already there, case aside", %{board: board, card: card} do
      {:ok, cards} = Wiki.create_folder(board, %{"name" => "cards"})
      {:ok, folder} = CardFolders.ensure(card)

      assert folder.parent_id == cards.id
    end

    test "follows the card's title", %{card: card, user: user} do
      page = write_up(card, user)

      {:ok, _} = Boards.update_card(card, %{"title" => "Fixed name"})

      assert Repo.get!(Folder, page.folder_id).name == "Fixed name"
    end

    test "a slash in the title is part of its name, not a path", %{card: card} do
      {:ok, card} = Boards.update_card(card, %{"title" => "Step 5/9 of it"})
      {:ok, folder} = CardFolders.ensure(card)

      assert folder.name == "Step 5/9 of it"
      assert Repo.get!(Folder, folder.parent_id).name == "Cards"
    end

    test "a title longer than a folder's name is held to it", %{board: board} do
      card = card_fixture(hd(board.columns), %{"title" => String.duplicate("x", 200)})
      {:ok, folder} = CardFolders.ensure(card)

      assert String.length(folder.name) == Folder.name_length()
    end

    test "stays when the card is archived", %{card: card, user: user} do
      page = write_up(card, user)
      {:ok, _} = Boards.archive_card(card)

      assert Repo.get!(Folder, page.folder_id).card_id == card.id
    end

    test "is let go when the card moves board, and made anew there",
         %{card: card, user: user} do
      page = write_up(card, user)
      elsewhere = board_fixture(%{"name" => "Elsewhere"}, owner: user)
      {:ok, _} = Boards.move_card_to_board(card, hd(elsewhere.columns))
      moved = Boards.get_card!(card.id)

      again = write_up(moved, user)
      left = Repo.get!(Folder, page.folder_id)

      assert left.card_id == nil
      assert left.board_id == card.board_id
      assert again.board_id == elsewhere.id
      assert Repo.get!(Folder, again.folder_id).card_id == card.id
    end

    test "becomes an ordinary folder when the card is deleted", %{card: card, user: user} do
      page = write_up(card, user)
      {:ok, _} = Repo.delete(card)

      assert Repo.get!(Folder, page.folder_id).card_id == nil
    end
  end

  describe "on disk" do
    setup %{user: user} do
      {:ok, vault} = user |> Vaults.root() |> Vaults.update_vault(%{"name" => "Disk"})
      %{vault: vault}
    end

    test "it's the short name, not the title", %{board: board, user: user, vault: vault} do
      card = card_fixture(hd(board.columns), %{"title" => @long, "short_name" => "Parked jobs"})
      page = write_up(card, user, title: "Log")

      assert Layout.build(vault).pages[page.id].path == "Folders/Cards/Parked jobs/Log.md"
    end

    test "changing the short name renames it", %{board: board, user: user, vault: vault} do
      card = card_fixture(hd(board.columns), %{"title" => @long})
      page = write_up(card, user, title: "Log")
      {:ok, _} = Boards.update_card(Repo.get!(Boards.Card, card.id), %{"short_name" => "New"})

      assert Layout.build(vault).pages[page.id].path == "Folders/Cards/New/Log.md"
    end

    test "a card with nothing usable in its name is Card <id>",
         %{card: card, user: user, vault: vault} do
      {:ok, card} = Boards.update_card(card, %{"title" => "###"})
      page = write_up(card, user, title: "Log")

      assert Layout.build(vault).pages[page.id].path == "Folders/Cards/Card #{card.id}/Log.md"
    end

    test "two cards of one name are numbered, oldest first",
         %{board: board, user: user, vault: vault} do
      a = card_fixture(hd(board.columns), %{"title" => "Same"})
      b = card_fixture(hd(board.columns), %{"title" => "same"})
      first = write_up(a, user, title: "Log")
      second = write_up(b, user, title: "Log")
      layout = Layout.build(vault)

      assert layout.pages[first.id].path == "Folders/Cards/Same/Log.md"
      assert layout.pages[second.id].path == "Folders/Cards/same (2)/Log.md"
    end

    test "an export agrees with the layout", %{board: board, user: user, vault: vault} do
      card = card_fixture(hd(board.columns), %{"title" => @long, "short_name" => "Parked jobs"})
      page = write_up(card, user, title: "Log")

      paths = Archive.files(board) |> Enum.map(&("Folders/" <> elem(&1, 0)))

      assert Layout.build(vault).pages[page.id].path in paths
    end
  end

  describe "pages and cards" do
    test "pinning an existing page moves nothing", %{board: board, card: card, user: user} do
      {:ok, folder} = Wiki.create_folder(board, %{"name" => "Decisions"})

      {:ok, page} =
        Wiki.create_page(board, %{"title" => "Why", "folder_id" => folder.id}, user: user)

      {:ok, _} = Wiki.pin(page, {:card, card})

      assert Repo.get!(Page, page.id).folder_id == folder.id
      assert CardFolders.find(card) == nil
    end

    test "a page pinned to a card on another board stays put", %{
      board: board,
      card: card,
      user: user
    } do
      other = board_fixture(%{"name" => "Other"}, owner: user)
      {:ok, page} = Wiki.create_page(other, %{"title" => "Elsewhere"}, user: user)

      {:ok, _} = Wiki.pin(page, {:card, card})

      assert Repo.get!(Page, page.id).folder_id == nil
      assert folders(board) == []
    end

    test "being told where wins", %{board: board, card: card, user: user} do
      {:ok, folder} = Wiki.create_folder(board, %{"name" => "Specs"})
      page = write_up(card, user, folder: folder.id)

      assert page.folder_id == folder.id
      assert CardFolders.find(card) == nil
    end

    test "a child of a page stays with its parent", %{board: board, card: card, user: user} do
      {:ok, parent} = Wiki.create_page(board, %{"title" => "Parent"}, user: user)
      page = write_up(card, user, parent: parent.id)

      assert page.parent_id == parent.id
      assert page.folder_id == nil
    end

    test "a template used for a card files there too", %{board: board, card: card, user: user} do
      {:ok, template} =
        Wiki.create_page(board, %{"title" => "Spec", "body" => "x", "template" => true},
          user: user
        )

      {:ok, page} =
        Wiki.create_from_template(board, template, %{}, card: card, user: user)

      assert Repo.get!(Folder, page.folder_id).card_id == card.id
    end

    test "a template used for another board's card stays where it's made",
         %{board: board, card: card, user: user} do
      other = board_fixture(%{"name" => "Templates"}, owner: user)

      {:ok, template} =
        Wiki.create_page(other, %{"title" => "Spec", "body" => "x", "template" => true},
          user: user
        )

      {:ok, page} =
        Wiki.create_from_template(other, template, %{}, card: card, user: user)

      assert page.folder_id == nil
      assert page.board_id == other.id
      assert folders(board) == []
    end
  end
end
