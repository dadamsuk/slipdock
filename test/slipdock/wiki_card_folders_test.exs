defmodule Slipdock.WikiCardFoldersTest do
  @moduledoc "A card's own folder (W-2201 rules 3 and 4)."
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Boards, Repo, Vaults, Wiki}
  alias Slipdock.Vaults.Layout
  alias Slipdock.Wiki.{Archive, CardFolders, Folder, Page}

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
    setup %{board: board, user: user} do
      {:ok, vault} = Vaults.create_vault(user, %{"name" => "Disk"})
      {:ok, _} = Vaults.add_mapping(vault, user, %{path: "/", board: board})
      %{vault: vault}
    end

    test "it's the short name, not the title", %{board: board, user: user, vault: vault} do
      card = card_fixture(hd(board.columns), %{"title" => @long, "short_name" => "Parked jobs"})
      page = write_up(card, user, title: "Log")

      assert Layout.build(vault).pages[page.id].path == "Cards/Parked jobs/Log.md"
    end

    test "changing the short name renames it", %{board: board, user: user, vault: vault} do
      card = card_fixture(hd(board.columns), %{"title" => @long})
      page = write_up(card, user, title: "Log")
      {:ok, _} = Boards.update_card(Repo.get!(Boards.Card, card.id), %{"short_name" => "New"})

      assert Layout.build(vault).pages[page.id].path == "Cards/New/Log.md"
    end

    test "a card with nothing usable in its name is Card <id>",
         %{card: card, user: user, vault: vault} do
      {:ok, card} = Boards.update_card(card, %{"title" => "###"})
      page = write_up(card, user, title: "Log")

      assert Layout.build(vault).pages[page.id].path == "Cards/Card #{card.id}/Log.md"
    end

    test "two cards of one name are numbered, oldest first",
         %{board: board, user: user, vault: vault} do
      a = card_fixture(hd(board.columns), %{"title" => "Same"})
      b = card_fixture(hd(board.columns), %{"title" => "same"})
      first = write_up(a, user, title: "Log")
      second = write_up(b, user, title: "Log")
      layout = Layout.build(vault)

      assert layout.pages[first.id].path == "Cards/Same/Log.md"
      assert layout.pages[second.id].path == "Cards/same (2)/Log.md"
    end

    test "an export agrees with the layout", %{board: board, user: user, vault: vault} do
      card = card_fixture(hd(board.columns), %{"title" => @long, "short_name" => "Parked jobs"})
      page = write_up(card, user, title: "Log")

      paths = Archive.files(board) |> Enum.map(&elem(&1, 0))

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
