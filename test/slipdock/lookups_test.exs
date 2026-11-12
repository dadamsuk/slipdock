defmodule Slipdock.LookupsTest do
  # The context functions the web layer reads through instead of calling
  # `Slipdock.Repo` itself (#2791). `Slipdock.BoundariesTest` keeps the web
  # layer off the repo; these hold each lookup to what it promises.
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Boards, Repo, Runners, Snooze, Tools, Wiki}
  alias Slipdock.Boards.{Activity, Board, Card, ChecklistItem, Comment, Tag}

  setup do
    owner = user_fixture()
    board = board_fixture(%{"name" => "Lookups"}, owner: owner)
    [backlog, todo | _] = board.columns
    %{owner: owner, board: board, backlog: backlog, todo: todo}
  end

  defp simple do
    {:ok, template} = Boards.find_template(nil, "Simple")
    template
  end

  defp loaded?(struct, field), do: Ecto.assoc_loaded?(Map.fetch!(struct, field))

  describe "boards" do
    test "get_board_record/1 and get_board_record!/1 load the row and nothing else", %{
      board: board
    } do
      record = Boards.get_board_record(board.id)
      assert %Board{id: id} = record
      assert id == board.id
      refute loaded?(record, :columns)
      refute loaded?(record, :owner)

      assert Boards.get_board_record(-1) == nil
      assert Boards.get_board_record!(board.id).id == board.id
      assert_raise Ecto.NoResultsError, fn -> Boards.get_board_record!(-1) end
    end

    test "root_board/1 is the board itself at the top, else the top of its tree", %{
      board: board,
      backlog: backlog
    } do
      assert Boards.root_board(board) == board

      epic = card_fixture(backlog, %{"title" => "Epic"})
      {:ok, sub} = sub_board(epic, simple())
      sub = Boards.get_board_record!(sub.id)

      assert sub.root_id == board.id
      assert %Board{id: root_id} = Boards.root_board(sub)
      assert root_id == board.id
    end

    test "reload_board!/1 and reload_card!/1 read the row again", %{
      board: board,
      backlog: backlog
    } do
      card = card_fixture(backlog)
      {:ok, _} = Boards.update_board(board, %{"name" => "Renamed"})
      {:ok, _} = Boards.update_card(card, %{"title" => "Retitled"})

      assert Boards.reload_board!(board).name == "Renamed"
      assert Boards.Cards.reload_card!(card).title == "Retitled"
    end

    test "with_owner/1 and with_saved_views/1 load just that", %{board: board, owner: owner} do
      record = Boards.get_board_record!(board.id)

      assert Boards.with_owner(record).owner.id == owner.id
      assert Boards.with_saved_views(record).saved_views == []
    end

    test "owned_root_boards/1 lists only the person's own top-level boards, by name", %{
      owner: owner,
      board: board,
      backlog: backlog
    } do
      other = board_fixture(%{"name" => "A first"}, owner: owner)
      {:ok, _} = Boards.archive_board(other)

      _theirs =
        board_fixture(%{"name" => "Not mine"}, owner: user_fixture("lookups-other@example.com"))

      {:ok, _sub} = sub_board(card_fixture(backlog), simple())

      assert [
               %{id: first_id, name: "A first", archived: true},
               %{id: board_id, name: "Lookups", archived: false, code: code}
             ] = Boards.owned_root_boards(owner)

      assert first_id == other.id
      assert board_id == board.id
      assert code == board.code
    end

    test "get_column/1 and list_board_columns/1", %{board: board, backlog: backlog} do
      assert Boards.Columns.get_column(backlog.id).id == backlog.id
      assert Boards.Columns.get_column(-1) == nil

      columns = Boards.Columns.list_board_columns(board)
      assert Enum.map(columns, & &1.id) == Enum.map(board.columns, & &1.id)
      assert Enum.map(columns, & &1.position) == Enum.sort(Enum.map(columns, & &1.position))
    end

    test "get_card_record/1 loads the row with none of get_card/1's preloads", %{
      backlog: backlog
    } do
      card = card_fixture(backlog)
      record = Boards.Cards.get_card_record(card.id)

      assert %Card{} = record
      assert record.id == card.id
      refute loaded?(record, :column)
      assert Boards.Cards.get_card_record(-1) == nil
    end

    test "with_board/1 and with_attachments/1", %{board: board, backlog: backlog} do
      card = Boards.Cards.get_card_record(card_fixture(backlog).id)

      assert Boards.Cards.with_board(card).board.id == board.id
      assert [%Card{board: %Board{}}] = Boards.Cards.with_board([card])
      assert Boards.Cards.with_attachments(card).attachments == []
    end

    test "list_board_cards/2 keeps to the board, leaves archived cards out, by id", %{
      backlog: backlog,
      board: board
    } do
      a = card_fixture(backlog)
      b = card_fixture(backlog)
      archived = card_fixture(backlog)
      {:ok, _} = Boards.archive_card(archived)
      elsewhere = card_fixture(hd(board_fixture().columns))

      ids = [b.id, elsewhere.id, archived.id, a.id]

      assert Enum.map(Boards.Cards.list_board_cards(board.id, ids), & &1.id) == [a.id, b.id]
      assert Boards.Cards.list_board_cards(board.id, []) == []
    end

    test "cards_by_id/1 and card_briefs/1 key the cards by id", %{
      backlog: backlog,
      board: board
    } do
      a = card_fixture(backlog, %{"title" => "Alpha"})

      assert %{} = by_id = Boards.Cards.cards_by_id([a.id, a.id, -1])
      assert Map.keys(by_id) == [a.id]
      assert by_id[a.id].column.id == backlog.id

      assert Boards.Cards.card_briefs([a.id]) == %{
               a.id => %{id: a.id, title: "Alpha", board_id: board.id}
             }

      assert Boards.Cards.card_briefs([]) == %{}
    end

    test "pick_open_cards/3 by number, by title, in a tree or across roots", %{
      board: board,
      backlog: backlog
    } do
      epic = card_fixture(backlog, %{"title" => "Epic of retries"})
      {:ok, sub} = sub_board(epic, simple())
      sub = Boards.get_board!(sub.id)
      inner = card_fixture(hd(sub.columns), %{"title" => "Inner retry"})
      done = card_fixture(backlog, %{"title" => "Done retry"})
      {:ok, _} = Boards.update_card(done, %{"completed" => true})
      odd = card_fixture(backlog, %{"title" => "100%_sure"})
      other = card_fixture(hd(board_fixture().columns), %{"title" => "Other retry"})

      ids = fn cards -> cards |> Enum.map(& &1.id) |> Enum.sort() end

      # A board takes its sub-boards with it; done cards stay out.
      assert ids.(Boards.Cards.pick_open_cards({:board, board.id}, "retr", 10)) ==
               Enum.sort([epic.id, inner.id])

      assert ids.(Boards.Cards.pick_open_cards({:roots, [board.id]}, "retr", 10)) ==
               Enum.sort([epic.id, inner.id])

      assert ids.(Boards.Cards.pick_open_cards({:roots, [board.id, other.board_id]}, "retr", 10)) ==
               Enum.sort([epic.id, inner.id, other.id])

      # Digits match the start of a card number.
      assert inner.id in ids.(
               Boards.Cards.pick_open_cards({:board, board.id}, Integer.to_string(inner.id), 10)
             )

      # Empty matches everything open, newest first, up to the limit, boards loaded.
      assert [%Card{board: %Board{}} | _] =
               all = Boards.Cards.pick_open_cards({:board, board.id}, "", 10)

      assert length(all) == 3
      assert length(Boards.Cards.pick_open_cards({:board, board.id}, "", 2)) == 2

      # % and _ in what was typed are literal, not wildcards.
      assert ids.(Boards.Cards.pick_open_cards({:board, board.id}, "0%_", 10)) == [odd.id]
      assert Boards.Cards.pick_open_cards({:board, board.id}, "0_%", 10) == []
    end

    test "tree_cards/1 takes the tree's live cards with board, list and assignees", %{
      board: board,
      backlog: backlog
    } do
      a = card_fixture(backlog)
      archived = card_fixture(backlog)
      {:ok, _} = Boards.archive_card(archived)
      _other = card_fixture(hd(board_fixture().columns))

      assert [%Card{id: id, board: %Board{}, column: %{}, assignees: []}] =
               Boards.Cards.tree_cards([board.id])

      assert id == a.id
    end

    test "activity_since/3 is the tree's activity since a moment, newest first, limited", %{
      board: board,
      backlog: backlog
    } do
      start = DateTime.add(DateTime.utc_now(:second), -60)
      card = card_fixture(backlog)

      Repo.delete_all(from(a in Activity, where: a.board_id == ^board.id))

      for {n, ago} <- [{1, 30}, {2, 20}, {3, 120}] do
        Repo.insert!(%Activity{
          board_id: board.id,
          card_id: card.id,
          kind: "test",
          message: "test #{n}",
          inserted_at: DateTime.add(DateTime.utc_now(:second), -ago)
        })
      end

      assert [%Activity{message: "test 2", board: %Board{}}, %Activity{message: "test 1"}] =
               Boards.ActivityLog.activity_since([board.id], start, 10)

      assert [%Activity{message: "test 2"}] =
               Boards.ActivityLog.activity_since([board.id], start, 1)

      assert Boards.ActivityLog.activity_since([-1], start, 10) == []
    end

    test "get_checklist_item!/1 and get_owned_row/2", %{backlog: backlog} do
      card = card_fixture(backlog)
      {:ok, item} = Boards.add_checklist_item(card, "Step one")
      {:ok, comment} = Boards.add_comment(card, "Hello")

      assert Boards.Checklists.get_checklist_item!(item.id).text == "Step one"
      assert_raise Ecto.NoResultsError, fn -> Boards.Checklists.get_checklist_item!(-1) end

      assert %ChecklistItem{} = Boards.Shared.get_owned_row(ChecklistItem, item.id)
      assert %Comment{body: "Hello"} = Boards.Shared.get_owned_row(Comment, comment.id)
      assert Boards.Shared.get_owned_row(Comment, -1) == nil

      # Only the rows that hang off a card or a page.
      assert_raise FunctionClauseError, fn -> Boards.Shared.get_owned_row(Tag, item.id) end
    end

    test "get_card_url/1 and get_attachment/2", %{backlog: backlog} do
      Slipdock.TestConfig.own_uploads_dir()
      card = card_fixture(backlog)
      {:ok, url} = Boards.add_card_url(card, %{"url" => "https://example.com/a"})

      src = Path.join(System.tmp_dir!(), "lookups-#{System.unique_integer([:positive])}.txt")
      File.write!(src, "hello")
      on_exit(fn -> File.rm(src) end)

      {:ok, attachment} =
        Boards.add_attachment(card, %{filename: "a.txt", content_type: "text/plain"}, src)

      assert Boards.CardUrls.get_card_url(url.id).url == "https://example.com/a"
      assert Boards.CardUrls.get_card_url(-1) == nil

      bare = Boards.Attachments.get_attachment(attachment.id)
      refute loaded?(bare, :card)

      loaded = Boards.Attachments.get_attachment(attachment.id, [:card, :page])
      assert loaded.card.id == card.id
      assert loaded.page == nil
      assert Boards.Attachments.get_attachment(-1, [:card]) == nil

      assert loaded?(Boards.Attachments.with_document_text(bare), :document_text)
    end

    test "transact/1 commits on {:ok, _} and rolls back anything else", %{backlog: backlog} do
      card = card_fixture(backlog, %{"title" => "Before"})

      assert {:ok, :done} =
               Boards.Cards.transact(fn ->
                 {:ok, _} = Boards.update_card(card, %{"title" => "Committed"})
                 {:ok, :done}
               end)

      assert Boards.Cards.reload_card!(card).title == "Committed"

      assert {:error, {:error, "nope"}} =
               Boards.Cards.transact(fn ->
                 {:ok, _} = Boards.update_card(card, %{"title" => "Rolled back"})
                 {:error, "nope"}
               end)

      assert Boards.Cards.reload_card!(card).title == "Committed"

      assert {:error, :refused} = Boards.Cards.transact(fn -> :refused end)
    end
  end

  describe "wiki" do
    test "with_board/1, with_board_preloads/3 and with_votes/1", %{board: board} do
      page = Wiki.get_page!(page_fixture(board).id)

      assert Wiki.with_board(page).board.id == board.id
      assert [%{board: %Board{}}] = Wiki.with_board([page])

      loaded = Wiki.with_board_preloads(page, [:tags])
      assert loaded.tags == []
      for assoc <- Wiki.board_preloads(), is_atom(assoc), do: assert(loaded?(loaded, assoc))

      assert Wiki.with_votes(page).votes == []
    end

    test "page_codes/1, page_stubs/1 and page_briefs/1 key the pages by id", %{board: board} do
      page = page_fixture(board, %{"title" => "Spec"})

      assert Wiki.page_codes([]) == %{}
      assert Wiki.page_codes([page.id, -1]) == %{page.id => page.code}

      assert %{} = stubs = Wiki.page_stubs([page.id, page.id])

      assert Map.take(stubs[page.id], [:id, :title, :slug, :board_id, :code]) ==
               %{id: page.id, title: "Spec", slug: page.slug, board_id: board.id, code: page.code}

      assert Wiki.page_briefs([page.id]) == %{
               page.id => %{id: page.id, title: "Spec", code: page.code, board_id: board.id}
             }
    end

    test "pinned_card_ids/1 and pinned_pages_on/1 follow the pins", %{
      board: board,
      backlog: backlog
    } do
      page = page_fixture(board, %{"title" => "Pinned"})
      unpinned = page_fixture(board, %{"title" => "Loose"})
      [c1, c2] = [card_fixture(backlog), card_fixture(backlog)]
      {:ok, _} = Wiki.pin(page, {:card, c2})
      {:ok, _} = Wiki.pin(page, {:card, c1})
      {:ok, _} = Wiki.pin(page, {:board, board})

      assert Wiki.pinned_card_ids([]) == %{}
      assert Wiki.pinned_card_ids([page.id, unpinned.id]) == %{page.id => [c1.id, c2.id]}

      assert Wiki.pinned_pages_on([]) == []
      assert [{%{id: page_id}, %Board{id: board_id}}] = Wiki.pinned_pages_on([board.id])
      assert {page_id, board_id} == {page.id, board.id}

      {:ok, _} = Wiki.archive_page(page)
      assert Wiki.pinned_pages_on([board.id]) == []
    end
  end

  describe "the other contexts" do
    test "Accounts.get_group/1 loads the row, or nil", %{owner: owner} do
      {:ok, group} = Accounts.create_group(owner, %{"name" => "Team"})

      assert %{name: "Team"} = found = Accounts.get_group(group.id)
      refute loaded?(found, :members)
      assert Accounts.get_group(-1) == nil
    end

    test "Runners.active_job_counts/1 counts the open jobs on a tree by status", %{
      board: board,
      backlog: backlog
    } do
      card = card_fixture(backlog)
      for status <- ~w(queued queued running done), do: working_job_fixture(card, status: status)
      _elsewhere = working_job_fixture(card_fixture(hd(board_fixture().columns)))

      assert Runners.active_job_counts(board.id) == %{"queued" => 2, "running" => 1}
      assert Runners.active_job_counts(-1) == %{}
    end

    test "Snooze.waking_before/3: the person's snoozed cards waking before then", %{
      owner: owner,
      board: board,
      backlog: backlog
    } do
      soon = DateTime.add(DateTime.utc_now(:second), 3600)
      later = DateTime.add(DateTime.utc_now(:second), 5 * 86_400)
      cutoff = DateTime.add(DateTime.utc_now(:second), 86_400)

      [mine, late, theirs, awake] = for _ <- 1..4, do: card_fixture(backlog)

      for c <- [mine, late, awake],
          do: {:ok, _} = Boards.update_card(c, %{"assignee_ids" => [owner.id]})

      {:ok, _} = Snooze.snooze(mine, owner, soon)
      {:ok, _} = Snooze.snooze(late, owner, later)
      {:ok, _} = Snooze.snooze(theirs, owner, soon)

      assert [%Card{id: id, board: %Board{}, column: %{}}] =
               Snooze.waking_before(owner, [board.id], cutoff)

      assert id == mine.id
      assert Snooze.waking_before(owner, [-1], cutoff) == []
    end

    test "Tools.get_tool!/1 and get_version!/1 raise on a missing id" do
      assert_raise Ecto.NoResultsError, fn -> Tools.get_tool!(-1) end
      assert_raise Ecto.NoResultsError, fn -> Tools.get_version!(-1) end
    end
  end
end
