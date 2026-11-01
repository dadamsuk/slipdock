defmodule Slipdock.Vaults.NamesTest do
  @moduledoc """
  What the sync listing and the change feed say of every kind of entry (W-2201
  §Names), and a rename reaching a follower as a move (#1594).
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Boards, Repo, Vaults, Wiki}
  alias Slipdock.Boards.ShortNames
  alias Slipdock.Vaults.Sync
  alias Slipdock.Wiki.{Changes, Files, Placements}

  @long "Agent supervision 5/9: Parked jobs must be released on timeout"

  setup do
    user = user_fixture("names-#{System.unique_integer([:positive])}@example.com")
    board = board_fixture(%{"name" => "Keystone", "code" => "nms1"}, owner: user)
    vault = Vaults.root(user)
    card = card_fixture(hd(board.columns), %{"title" => "Fix the thing"})
    {:ok, page} = Wiki.create_page_from_card(card, user: user, title: "Write up")
    %{user: user, board: board, vault: vault, card: card, page: page}
  end

  defp source(bytes) do
    path = Path.join(System.tmp_dir!(), "names-#{System.unique_integer([:positive])}")
    File.write!(path, bytes)
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp cursor(ctx), do: Changes.since(ctx.vault, nil, ctx.user).cursor
  defp feed(ctx, since), do: Changes.since(ctx.vault, since, ctx.user).changes
  defp listing(ctx), do: Sync.listing(ctx.vault, ctx.user)

  defp entry(listing, id), do: Enum.find(listing.entries, &(&1.id == id))

  defp change(changes, subject, id),
    do: Enum.find(changes, &(&1.subject == subject and &1.id == id))

  defp folder_of(ctx), do: Repo.get!(Wiki.Page, ctx.page.id).folder_id

  defp file_in_card_folder(ctx) do
    {:ok, file} =
      Files.create(ctx.board, %{name: "plan.pdf", folder_id: folder_of(ctx)}, source("x"))

    file
  end

  defp epic(ctx, title \\ "Launch") do
    card = card_fixture(hd(ctx.board.columns), %{"title" => title})
    {:ok, template} = Boards.find_template(nil, "Simple")
    {:ok, sub} = sub_board(card, template)
    {card, Boards.get_board!(sub.id)}
  end

  describe "the listing's fields" do
    test "a card folder: title, short name, disk path, card id", ctx do
      {:ok, card} = Boards.update_card(ctx.card, %{"title" => @long})
      details = listing(ctx).folder_details["Keystone/Cards/#{card.short_name}"]

      assert %{title: @long, card_id: id, archived: false, id: folder} = details
      assert id == card.id
      assert folder == folder_of(ctx)
      assert details.short_name == card.short_name
      assert card.short_name != @long
    end

    test "a wiki folder has its name for a title, and no card", ctx do
      {:ok, _} = Wiki.create_folder(ctx.board, %{"name" => "Specs: old?"})

      assert %{title: "Specs: old?", short_name: nil, card_id: nil, archived: false} =
               listing(ctx).folder_details["Keystone/Specs- old-"]
    end

    test "a page and a file", ctx do
      file = file_in_card_folder(ctx)
      listed = listing(ctx)

      assert %{
               kind: "page",
               title: "Write up",
               short_name: nil,
               archived: false,
               path: "Keystone/Cards/Fix the thing/Write up.md"
             } = entry(listed, ctx.page.id)

      assert %{
               kind: "file",
               title: "plan.pdf",
               name: "plan.pdf",
               short_name: nil,
               archived: false,
               path: "Keystone/Cards/Fix the thing/plan.pdf"
             } = entry(listed, file.id)
    end

    test "a board", ctx do
      id = ctx.board.id

      assert [%{id: ^id, title: "Keystone", name: "Keystone", short_name: nil, archived: false}] =
               Enum.filter(listing(ctx).boards, &(&1.id == id))
    end

    test "boards carry the home page's hand-made order as position", ctx do
      older = board_fixture(%{"name" => "Archive desk", "code" => "nms2"}, owner: ctx.user)
      newer = board_fixture(%{"name" => "Zebra", "code" => "nms3"}, owner: ctx.user)
      :ok = Boards.reorder_boards(ctx.user, [newer.id])

      positions = Map.new(listing(ctx).boards, &{&1.id, &1.position})

      # Placed first; the rest after it, oldest first, whatever their names.
      assert positions[newer.id] == 0
      assert positions[ctx.board.id] == 1
      assert positions[older.id] == 2
    end

    test "a title too long for a path is whole in the listing and bounded on disk", ctx do
      title = String.duplicate("very long words ", 12) |> String.trim()
      {:ok, _} = Boards.update_card(ctx.card, %{"title" => title, "short_name" => "Short"})

      assert %{title: ^title, short_name: "Short"} =
               listing(ctx).folder_details["Keystone/Cards/Short"]
    end

    test "a card with no short name has nil, and its folder goes by its title", ctx do
      assert %{short_name: nil, title: "Fix the thing"} =
               listing(ctx).folder_details["Keystone/Cards/Fix the thing"]
    end
  end

  describe "folders" do
    test "takes in boards and the directories only a sub-board needs", ctx do
      {card, _sub} = epic(ctx)
      {:ok, _} = Boards.update_card(card, %{"short_name" => "Go"})
      listed = listing(ctx)

      assert "Keystone" in listed.folders
      assert "Keystone/Cards" in listed.folders
      assert "Keystone/Cards/Go" in listed.folders

      card_id = card.id

      assert [%{title: "Launch", short_name: "Go", card_id: ^card_id, archived: false}] =
               Enum.filter(listed.virtual_folders, &(&1.path == "Keystone/Cards/Go"))
    end

    test "a virtual directory has no details entry, which promises an id", ctx do
      {_card, _sub} = epic(ctx)
      refute Map.has_key?(listing(ctx).folder_details, "Keystone/Cards/Launch")
    end

    test "a token limited to one board sees none of another's directories", ctx do
      {_card, _sub} = epic(ctx)
      other = board_fixture(%{"name" => "Other", "code" => "nms2"}, owner: ctx.user)

      listed =
        Sync.listing(ctx.vault, ctx.user, token: %{scope: "write", scope_boards: [other.id]})

      assert listed.folders == ["Other"]
      assert listed.virtual_folders == []
    end
  end

  describe "archived" do
    test "an archived card marks its folder and what is in it, and moves nothing", ctx do
      file = file_in_card_folder(ctx)
      before = listing(ctx)
      {:ok, card} = Boards.archive_card(ctx.card)
      listed = listing(ctx)

      assert listed.folder_details["Keystone/Cards/Fix the thing"].archived
      assert entry(listed, ctx.page.id).archived
      assert entry(listed, file.id).archived
      assert Enum.map(listed.entries, & &1.path) == Enum.map(before.entries, & &1.path)
      assert entry(listed, ctx.page.id).hash == entry(before, ctx.page.id).hash
      refute listed.folder_details["Keystone/Cards"].archived

      {:ok, _} = Boards.unarchive_card(card)
      refute entry(listing(ctx), ctx.page.id).archived
    end

    test "an archived board marks everything on it", ctx do
      {:ok, _} = Boards.archive_board(ctx.board)
      listed = listing(ctx)

      assert entry(listed, ctx.page.id).archived
      assert listed.folder_details["Keystone/Cards"].archived
      assert hd(listed.boards).archived
    end

    test "an archived epic marks the sub-board and the virtual directory", ctx do
      {card, sub} = epic(ctx)
      {:ok, page} = Wiki.create_page(sub, %{"title" => "Inside"})
      {:ok, _} = Boards.archive_card(card)
      listed = listing(ctx)

      assert entry(listed, page.id).archived
      assert [%{archived: true}] = Enum.filter(listed.virtual_folders, &(&1.card_id == card.id))
    end

    test "the feed says so, on a row of its own that moves nothing", ctx do
      start = cursor(ctx)
      {:ok, _} = Boards.archive_card(ctx.card)

      assert [%{subject: "folder", action: "archived", archived: true, card_id: id}] =
               feed(ctx, start)

      assert id == ctx.card.id
    end

    test "archiving and restoring a board is a board row", ctx do
      start = cursor(ctx)
      {:ok, board} = Boards.archive_board(ctx.board)

      assert [%{subject: "board", action: "archived", archived: true, path: "Keystone"}] =
               feed(ctx, start)

      again = cursor(ctx)
      {:ok, _} = Boards.unarchive_board(board)

      assert [%{subject: "board", action: "restored", archived: false}] = feed(ctx, again)
    end

    test "a page in an archived card's folder is flagged, and keeps its path, in the feed", ctx do
      {:ok, _} = Boards.archive_card(ctx.card)
      start = cursor(ctx)
      {:ok, _} = Wiki.update_page(Repo.get!(Wiki.Page, ctx.page.id), %{"body" => "more"})

      assert [%{archived: true, path: "Keystone/Cards/Fix the thing/Write up.md"}] =
               feed(ctx, start)
    end

    test "a page archived itself is flagged too, and has no path", ctx do
      start = cursor(ctx)
      {:ok, _} = Wiki.archive_page(Repo.get!(Wiki.Page, ctx.page.id))

      assert [%{subject: "page", action: "archived", archived: true, path: nil}] =
               feed(ctx, start)
    end
  end

  describe "a rename is a move" do
    test "a card's title moves its folder and everything in it, hashes as they were", ctx do
      file = file_in_card_folder(ctx)
      before = listing(ctx)
      start = cursor(ctx)

      {:ok, _} = Boards.update_card(ctx.card, %{"title" => "Fix the other thing"})
      changes = feed(ctx, start)

      assert %{
               action: "moved",
               from_path: "Keystone/Cards/Fix the thing",
               path: "Keystone/Cards/Fix the other thing",
               title: "Fix the other thing"
             } = change(changes, "folder", folder_of(ctx))

      assert %{
               action: "moved",
               from_path: "Keystone/Cards/Fix the thing/Write up.md",
               path: "Keystone/Cards/Fix the other thing/Write up.md"
             } = change(changes, "page", ctx.page.id)

      assert %{
               action: "moved",
               from_path: "Keystone/Cards/Fix the thing/plan.pdf",
               path: "Keystone/Cards/Fix the other thing/plan.pdf"
             } = change(changes, "file", file.id)

      refute Enum.any?(changes, &(&1.action in ["deleted", "archived"]))

      listed = listing(ctx)
      assert entry(listed, ctx.page.id).hash == entry(before, ctx.page.id).hash
      assert entry(listed, file.id).hash == entry(before, file.id).hash
    end

    test "only what moved is in the feed", ctx do
      other = card_fixture(hd(ctx.board.columns), %{"title" => "Other card"})
      {:ok, stays} = Wiki.create_page_from_card(other, user: ctx.user, title: "Stays")
      {:ok, loose} = Wiki.create_page(ctx.board, %{"title" => "Loose"})
      start = cursor(ctx)

      {:ok, _} = Boards.update_card(ctx.card, %{"title" => "Renamed"})
      ids = for %{subject: "page", id: id} <- feed(ctx, start), do: id

      assert ids == [ctx.page.id]
      refute stays.id in ids
      refute loose.id in ids
    end

    test "a short name typed by a person moves it", ctx do
      start = cursor(ctx)
      {:ok, _} = Boards.update_card(ctx.card, %{"short_name" => "Fixing"})

      assert %{from_path: "Keystone/Cards/Fix the thing", path: "Keystone/Cards/Fixing"} =
               change(feed(ctx, start), "folder", folder_of(ctx))
    end

    test "a short name a model made moves it too", ctx do
      {:ok, card} = Boards.update_card(ctx.card, %{"title" => @long})
      start = cursor(ctx)
      was = "Keystone/Cards/#{card.short_name}"

      assert %{by_model: 0} = ShortNames.backfill(ids: [card.id], model: false)
      assert feed(ctx, start) == []

      Slipdock.Repo.update_all(from(c in Slipdock.Boards.Card, where: c.id == ^card.id),
        set: [short_name: nil]
      )

      assert %{named: 1} = ShortNames.backfill(ids: [card.id], model: false)
      assert %{path: ^was} = change(feed(ctx, start), "folder", folder_of(ctx))
    end

    test "a name that leaves the path alone is a change, not a move", ctx do
      {:ok, card} = Boards.update_card(ctx.card, %{"short_name" => "Fixing"})
      start = cursor(ctx)
      {:ok, _} = Boards.update_card(card, %{"title" => "A whole new title"})

      changes = feed(ctx, start)
      assert [%{subject: "folder", action: "changed", title: "A whole new title"} = row] = changes
      refute Map.has_key?(row, :from_path)
    end

    test "a board's name moves everything on it, itself included", ctx do
      file = file_in_card_folder(ctx)
      {:ok, loose} = Wiki.create_page(ctx.board, %{"title" => "Loose"})
      before = listing(ctx)
      start = cursor(ctx)

      {:ok, _} = Boards.update_board(ctx.board, %{"name" => "Capstone"})
      changes = feed(ctx, start)

      assert %{action: "moved", from_path: "Keystone", path: "Capstone", title: "Capstone"} =
               change(changes, "board", ctx.board.id)

      assert %{from_path: "Keystone/Loose.md", path: "Capstone/Loose.md"} =
               change(changes, "page", loose.id)

      assert %{path: "Capstone/Cards/Fix the thing/plan.pdf"} = change(changes, "file", file.id)
      assert %{path: "Capstone/Cards"} = Enum.find(changes, &(&1[:title] == "Cards"))

      assert entry(listing(ctx), ctx.page.id).hash == entry(before, ctx.page.id).hash
    end

    test "other changes to a board or a card write nothing", ctx do
      start = cursor(ctx)
      {:ok, _} = Boards.update_board(ctx.board, %{"description" => "New words"})
      {:ok, _} = Boards.update_card(ctx.card, %{"description" => "New words"})

      assert feed(ctx, start) == []
    end

    test "a card with no folder has nothing to move", ctx do
      card = card_fixture(hd(ctx.board.columns), %{"title" => "Foldered not"})
      start = cursor(ctx)
      {:ok, _} = Boards.update_card(card, %{"title" => "Still not"})

      assert feed(ctx, start) == []
    end

    test "an epic's rename moves the sub-board's directory and its pages", ctx do
      {card, sub} = epic(ctx)
      {:ok, page} = Wiki.create_page(sub, %{"title" => "Inside"})
      start = cursor(ctx)

      {:ok, _} = Boards.update_card(card, %{"title" => "Liftoff"})
      changes = feed(ctx, start)

      assert %{from_path: "Keystone/Cards/Launch", path: "Keystone/Cards/Liftoff"} =
               change(changes, "board", sub.id)

      assert %{
               from_path: "Keystone/Cards/Launch/Inside.md",
               path: "Keystone/Cards/Liftoff/Inside.md"
             } = change(changes, "page", page.id)
    end

    test "a sibling a clash renumbered moves as well", ctx do
      twin = card_fixture(hd(ctx.board.columns), %{"title" => "Fix the thing"})
      {:ok, page} = Wiki.create_page_from_card(twin, user: ctx.user, title: "Twin's")
      start = cursor(ctx)

      {:ok, _} = Boards.update_card(ctx.card, %{"title" => "Elsewhere"})

      assert %{
               from_path: "Keystone/Cards/Fix the thing (2)/Twin's.md",
               path: "Keystone/Cards/Fix the thing/Twin's.md"
             } = change(feed(ctx, start), "page", page.id)
    end

    test "moved twice, it names where the client last saw it", ctx do
      start = cursor(ctx)
      {:ok, card} = Boards.update_card(ctx.card, %{"title" => "Second"})
      {:ok, _} = Boards.update_card(card, %{"title" => "Third"})

      assert %{
               action: "moved",
               from_path: "Keystone/Cards/Fix the thing/Write up.md",
               path: "Keystone/Cards/Third/Write up.md"
             } = change(feed(ctx, start), "page", ctx.page.id)
    end

    test "a later save doesn't hide the move", ctx do
      start = cursor(ctx)
      {:ok, _} = Boards.update_card(ctx.card, %{"title" => "Second"})
      {:ok, _} = Wiki.update_page(Repo.get!(Wiki.Page, ctx.page.id), %{"body" => "edited"})

      assert %{action: "moved", from_path: "Keystone/Cards/Fix the thing/Write up.md"} =
               change(feed(ctx, start), "page", ctx.page.id)
    end

    test "moved and moved back is no move", ctx do
      start = cursor(ctx)
      {:ok, card} = Boards.update_card(ctx.card, %{"title" => "Second"})
      {:ok, _} = Boards.update_card(card, %{"title" => "Fix the thing"})

      row = change(feed(ctx, start), "page", ctx.page.id)
      assert row.action == "changed"
      refute Map.has_key?(row, :from_path)
    end

    test "a follower past the move sees only what came after", ctx do
      {:ok, _} = Boards.update_card(ctx.card, %{"title" => "Second"})
      start = cursor(ctx)
      {:ok, _} = Wiki.update_page(Repo.get!(Wiki.Page, ctx.page.id), %{"body" => "edited"})

      assert [%{action: "changed"} = row] = feed(ctx, start)
      refute Map.has_key?(row, :from_path)
    end

    test "a page filed there as well changes its bytes, and the feed says", ctx do
      {:ok, pinned} = Wiki.create_page(ctx.board, %{"title" => "Elsewhere"})
      folder = Wiki.get_folder(folder_of(ctx))
      {:ok, _} = Placements.add(pinned, folder, ctx.user)
      before = entry(listing(ctx), pinned.id)
      start = cursor(ctx)

      {:ok, _} = Boards.update_card(ctx.card, %{"title" => "Renamed"})

      after_move = entry(listing(ctx), pinned.id)
      assert after_move.path == before.path
      refute after_move.hash == before.hash

      assert %{action: "changed", path: "Keystone/Elsewhere.md"} =
               change(feed(ctx, start), "page", pinned.id)
    end

    test "a follower is told once", ctx do
      file_in_card_folder(ctx)
      Changes.subscribe(ctx.vault.id)
      {:ok, _} = Boards.update_board(ctx.board, %{"description" => "still the same"})
      refute_received {:vault_change, _, _}

      {:ok, _} = Boards.update_board(ctx.board, %{"name" => "Capstone"})

      assert_received {:vault_change, _, _}
      assert_received {:vault_change, _, _}
      refute_received {:vault_change, _, _}
    end
  end

  describe "the feed's fields" do
    test "a card folder, a file and a page carry the listing's names", ctx do
      {:ok, card} = Boards.update_card(ctx.card, %{"title" => @long})
      start = cursor(ctx)
      {:ok, _} = Wiki.update_folder(Wiki.get_folder(folder_of(ctx)), %{"icon" => "star"})
      file = file_in_card_folder(ctx)
      {:ok, _} = Wiki.update_page(Repo.get!(Wiki.Page, ctx.page.id), %{"body" => "new"})
      changes = feed(ctx, start)
      dir = "Keystone/Cards/#{card.short_name}"
      card_id = card.id

      assert %{title: @long, card_id: ^card_id, archived: false, path: ^dir} =
               row = change(changes, "folder", folder_of(ctx))

      assert row.short_name == card.short_name

      assert %{title: "plan.pdf", short_name: nil, archived: false, path: file_path} =
               change(changes, "file", file.id)

      assert file_path == dir <> "/plan.pdf"

      assert %{title: "Write up", short_name: nil, archived: false, path: page_path} =
               change(changes, "page", ctx.page.id)

      assert page_path == dir <> "/Write up.md"
    end

    test "a path in the feed is the listing's path", ctx do
      start = cursor(ctx)
      {:ok, _} = Wiki.update_page(Repo.get!(Wiki.Page, ctx.page.id), %{"body" => "new"})

      assert [%{path: path}] = feed(ctx, start)
      assert path == entry(listing(ctx), ctx.page.id).path
    end

    test "a board nobody here can read isn't described", ctx do
      stranger = user_fixture("stranger-#{System.unique_integer([:positive])}@example.com")
      start = cursor(ctx)
      {:ok, _} = Boards.update_board(ctx.board, %{"name" => "Capstone"})

      refute Enum.any?(
               Changes.since(ctx.vault, start, stranger).changes,
               &(&1.subject == "board")
             )
    end
  end
end
