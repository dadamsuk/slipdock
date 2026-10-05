defmodule Slipdock.PortableImportTest do
  @moduledoc """
  The only test that matters for an import is the round trip: export a board,
  import the file, and the second board is the first one. Everything else here
  is about the decisions — that it never merges, that a taken code is reported
  rather than hidden, that the card limit is answered before anything is built,
  and that a document from a server where somebody has no account still lands.
  """
  use Slipdock.DataCase, async: false

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.{Boards, Fields, Portable, Quota, Repo, Settings, Wiki}

  defp populated(owner) do
    board = board_fixture(%{"name" => "Delivery", "code" => "del"}, owner: owner)
    [_backlog, todo, doing | _] = board.columns

    tag = tag_fixture(board, "urgent", "rose")
    {:ok, field} = Fields.create_field(board, %{"name" => "Points", "kind" => "number"})

    epic = card_fixture(todo, %{"title" => "Ship it", "priority" => "high"})
    other = card_fixture(doing, %{"title" => "Groundwork"})

    {:ok, _} = Boards.set_card_tags(epic, [tag])
    {:ok, _} = Boards.add_checklist_item(epic, "Write it down")
    {:ok, _} = Boards.add_comment(epic, "Started on this")

    {:ok, _} =
      Boards.add_status_update(epic, owner, %{"health" => "on_track", "body" => "On track"})

    {:ok, _} = Boards.add_card_url(epic, %{"url" => "https://example.com", "title" => "Spec"})
    {:ok, _} = Fields.set_value(epic, field, "8")
    {:ok, _} = Boards.add_dependency(epic, other)
    {:ok, _} = Boards.add_link(epic, other, "relates")

    template = Boards.list_templates() |> Enum.find(&(&1.name == "Simple"))
    {:ok, sub} = Boards.create_sub_board(epic, template)
    [sub_todo | _] = Boards.get_board!(sub.id).columns
    _subcard = card_fixture(sub_todo, %{"title" => "One sitting of it"})

    {:ok, _page} =
      Wiki.create_page(board, %{"title" => "How it works", "body" => "The shape of it."},
        user: owner
      )

    Boards.get_board!(board.id)
  end

  # Export, then import as somebody else, then look at what they got.
  defp round_trip(from, to, opts \\ []) do
    document = from |> Portable.export(opts) |> Jason.encode!()
    {:ok, report} = Portable.import(to, document)
    {report, Boards.get_board!(hd(report.boards).id)}
  end

  # The smallest document with one tree in it: a root "r" with one list, the
  # sub-boards and cards given.
  defp tree_document(boards, cards, extra \\ []) do
    tree =
      Map.merge(
        %{
          root: %{ref: "r", name: "Imported", code: "imp", lists: [%{ref: "l1", name: "To Do"}]},
          boards: boards,
          cards: Enum.map(cards, &Map.put_new(&1, :list, "l1"))
        },
        Map.new(extra)
      )

    Jason.encode!(%{slipdock_portable: 1, boards: [tree]})
  end

  defp card(board, title) do
    board |> Boards.list_cards(%{}) |> Enum.find(&(&1.title == title))
  end

  defp owned(user) do
    Repo.all(
      from(b in Slipdock.Boards.Board,
        where: b.owner_id == ^user.id and is_nil(b.parent_card_id)
      )
    )
  end

  defp values(owner) do
    Repo.all(from(v in Slipdock.Boards.FieldValue, where: v.card_id == ^owner.id))
  end

  describe "the round trip" do
    setup do
      owner = user_fixture("owner@example.com")
      _board = populated(owner)
      %{owner: owner, receiver: user_fixture("receiver@example.com")}
    end

    test "the board arrives, owned by whoever imported it", %{owner: owner, receiver: receiver} do
      {report, board} = round_trip(owner, receiver)

      assert board.name == "Delivery"
      assert board.owner_id == receiver.id
      assert report.cards == 3
      assert report.pages == 1
    end

    test "its lists come back in order, with their categories", %{
      owner: owner,
      receiver: receiver
    } do
      {_report, board} = round_trip(owner, receiver)

      assert Enum.map(board.columns, & &1.name) == ["Backlog", "To Do", "In Progress", "Done"]
      assert Enum.map(board.columns, & &1.category) == ["todo", "todo", "doing", "done"]
    end

    test "each list keeps the order and groups it draws its cards in", %{
      owner: owner,
      receiver: receiver
    } do
      [board] = owned(owner)
      todo = Enum.find(Boards.get_board!(board.id).columns, &(&1.name == "To Do"))

      {:ok, _} =
        Boards.update_column(todo, %{
          "sort_by" => "due_date",
          "sort_dir" => "desc",
          "group_by" => "flag"
        })

      {_report, board} = round_trip(owner, receiver)

      assert [
               {"Backlog", nil, "asc", nil},
               {"To Do", "due_date", "desc", "flag"} | _
             ] = Enum.map(board.columns, &{&1.name, &1.sort_by, &1.sort_dir, &1.group_by})
    end

    test "an order this server does not know is dropped, not the list with its cards" do
      document =
        Jason.encode!(%{
          slipdock_portable: 1,
          boards: [
            %{
              root: %{
                ref: "r",
                name: "Imported",
                code: "imp2",
                lists: [
                  %{
                    ref: "l1",
                    name: "To Do",
                    sort_by: "vibes",
                    sort_dir: "sideways",
                    group_by: "mood"
                  }
                ]
              },
              boards: [],
              cards: [%{ref: "k0", board: "r", list: "l1", title: "Still here"}]
            }
          ]
        })

      assert {:ok, %{cards: 1} = report} = Portable.import(user_fixture(), document)
      [list] = Boards.get_board!(hd(report.boards).id).columns
      assert {list.name, list.sort_by, list.sort_dir, list.group_by} == {"To Do", nil, "asc", nil}
    end

    test "cards land in the list they were in", %{owner: owner, receiver: receiver} do
      {_report, board} = round_trip(owner, receiver)

      epic = card(board, "Ship it")
      todo = Enum.find(board.columns, &(&1.name == "To Do"))

      assert epic.column_id == todo.id
      assert epic.priority == "high"
    end

    test "a card's tags come with it", %{owner: owner, receiver: receiver} do
      {_report, board} = round_trip(owner, receiver)

      epic = board |> card("Ship it") |> Slipdock.Repo.preload(:tags)
      assert Enum.map(epic.tags, & &1.name) == ["urgent"]
      assert [%{name: "urgent", color: "rose"}] = Boards.list_tags(board.id)
    end

    test "the checklist, the comment, the status update and the web link", %{
      owner: owner,
      receiver: receiver
    } do
      {_report, board} = round_trip(owner, receiver)
      epic = Boards.get_card!(card(board, "Ship it").id)

      assert [%{text: "Write it down"}] = epic.checklist_items
      assert [%{body: "Started on this"}] = epic.comments
      # Signed by whoever imported it, with the original author in the text:
      # a document cannot speak in somebody else's name.
      assert [%{health: "on_track", body: "*owner@example.com*\n\nOn track", user_id: by}] =
               epic.status_updates

      assert by == receiver.id
      assert [%{url: "https://example.com", title: "Spec"}] = epic.urls
    end

    test "the custom field, and the value the card held in it", %{
      owner: owner,
      receiver: receiver
    } do
      {_report, board} = round_trip(owner, receiver)

      assert [%{name: "Points", kind: "number"} = field] = Fields.list_fields(board.id)
      assert [%{number: 8.0, field_id: field_id}] = board |> card("Ship it") |> values()
      assert field_id == field.id
    end

    test "what the card waited on, and what it was linked to", %{
      owner: owner,
      receiver: receiver
    } do
      {_report, board} = round_trip(owner, receiver)

      epic = Boards.get_card!(card(board, "Ship it").id)
      assert Enum.map(epic.blocked_by, & &1.title) == ["Groundwork"]
      assert [%{kind: "relates"}] = epic.links_out
    end

    test "the subcards, on a sub-board of their own", %{owner: owner, receiver: receiver} do
      {_report, board} = round_trip(owner, receiver)

      epic = Boards.get_card!(card(board, "Ship it").id)
      assert epic.sub_board
      sub = Boards.get_board!(epic.sub_board.id)

      assert sub.root_id == board.id
      assert sub.parent_card_id == epic.id
      assert [%{title: "One sitting of it"}] = Boards.list_cards(sub, %{})
    end

    test "the wiki page, with its body", %{owner: owner, receiver: receiver} do
      {_report, board} = round_trip(owner, receiver)

      assert [%{title: "How it works", body: "The shape of it."}] = Wiki.list_pages(board)
    end

    test "the importer's own cards come through as theirs", %{owner: owner} do
      board = Boards.get_board!(owned(owner) |> hd() |> Map.fetch!(:id))
      epic = card(board, "Ship it")
      {:ok, _} = Boards.update_card(epic, %{"assignee_id" => owner.id})

      {_report, imported} = round_trip(owner, owner)
      assert card(imported, "Ship it").assignee_id == owner.id
    end

    test "somebody else's come in unassigned, though they have an account here", %{
      owner: owner,
      receiver: receiver
    } do
      board = Boards.get_board!(owned(owner) |> hd() |> Map.fetch!(:id))
      epic = card(board, "Ship it")
      {:ok, _} = Boards.update_card(epic, %{"assignee_id" => owner.id})

      # The imported board is the receiver's alone, and nobody is put on a
      # card they cannot open.
      {report, imported} = round_trip(owner, receiver)
      assert card(imported, "Ship it").assignee_id == nil

      assert "owner@example.com can't see this board yet, so what was theirs came in unassigned." in report.skipped
    end
  end

  describe "the wiki survives the trip" do
    test "a page's code is reissued, because codes are unique across the server" do
      owner = user_fixture("owner@example.com")
      board = populated(owner)
      [page] = Wiki.list_pages(board)

      {:ok, report} = Portable.import(owner, owner |> Portable.export() |> Jason.encode!())
      [imported] = Wiki.list_pages(Boards.get_board!(hd(report.boards).id))

      refute imported.code == page.code
      assert imported.title == page.title
    end

    test "[[W-31]] inside a body is rewritten to the code the page now has" do
      owner = user_fixture("owner@example.com")
      board = board_fixture(%{"name" => "Notes"}, owner: owner)

      {:ok, target} =
        Wiki.create_page(board, %{"title" => "Retry policy", "body" => "Three times."},
          user: owner
        )

      {:ok, _referrer} =
        Wiki.create_page(
          board,
          %{"title" => "Overview", "body" => "See [[#{target.code}]] for the detail."},
          user: owner
        )

      {:ok, report} = Portable.import(owner, owner |> Portable.export() |> Jason.encode!())
      pages = Wiki.list_pages(Boards.get_board!(hd(report.boards).id))

      new_target = Enum.find(pages, &(&1.title == "Retry policy"))
      overview = Enum.find(pages, &(&1.title == "Overview"))

      refute new_target.code == target.code
      assert overview.body == "See [[#{new_target.code}]] for the detail."
      # And the old code is gone from it, rather than both being present.
      refute overview.body =~ target.code
    end

    test "prose that merely contains the letters is left alone" do
      owner = user_fixture("owner@example.com")
      board = board_fixture(%{"name" => "Notes"}, owner: owner)

      {:ok, target} = Wiki.create_page(board, %{"title" => "One"}, user: owner)

      {:ok, _} =
        Wiki.create_page(
          board,
          %{"title" => "Two", "body" => "Nothing about #{target.code}X here."},
          user: owner
        )

      {:ok, report} = Portable.import(owner, owner |> Portable.export() |> Jason.encode!())
      pages = Wiki.list_pages(Boards.get_board!(hd(report.boards).id))

      assert Enum.find(pages, &(&1.title == "Two")).body == "Nothing about #{target.code}X here."
    end
  end

  describe "what it refuses to do" do
    setup do
      owner = user_fixture("owner@example.com")
      _board = populated(owner)
      %{owner: owner}
    end

    test "it never merges — importing your own export gives you a second board", %{owner: owner} do
      before = length(owned(owner))
      {_report, _board} = round_trip(owner, owner)

      assert length(owned(owner)) == before + 1
    end

    test "a code that is taken is changed, and the report says so", %{owner: owner} do
      {report, board} = round_trip(owner, owner)

      refute board.code == "del"
      assert Enum.any?(report.skipped, &(&1 =~ "was taken"))
    end

    test "importing twice over does not collide on the code either", %{owner: owner} do
      {_r1, first} = round_trip(owner, owner)
      {_r2, second} = round_trip(owner, owner)

      assert first.code != second.code
    end
  end

  describe "the item limit" do
    setup do
      owner = user_fixture("owner@example.com")
      _board = populated(owner)
      %{owner: owner, receiver: user_fixture("receiver@example.com")}
    end

    test "a document that will not fit is refused before anything is built", %{
      owner: owner,
      receiver: receiver
    } do
      {:ok, _} = Settings.complete_setup(%{"admin_email" => "a@example.com"})
      {:ok, _} = Settings.update(%{"free_card_limit" => 2})

      document = owner |> Portable.export() |> Jason.encode!()

      # Four items, not three cards: the export carries a wiki page too, and a
      # page counts like a card does (see `Slipdock.Quota`).
      assert {:error, {:card_limit_reached, 4, 2}} = Portable.import(receiver, document)
      assert owned(receiver) == []
    end

    test "it fits when there is room", %{owner: owner, receiver: receiver} do
      {:ok, _} = Settings.complete_setup(%{"admin_email" => "a@example.com"})
      {:ok, _} = Settings.update(%{"free_card_limit" => 10})

      document = owner |> Portable.export() |> Jason.encode!()
      assert {:ok, %{cards: 3}} = Portable.import(receiver, document)
      assert Quota.used(receiver, :cards) == 3
      assert Quota.used(receiver) == 4
    end
  end

  describe "a document it cannot trust" do
    test "something that is not JSON" do
      assert {:error, :not_json} = Portable.import(user_fixture(), "{ not json")
    end

    test "JSON that is not one of ours" do
      assert {:error, :not_a_slipdock_export} =
               Portable.import(user_fixture(), ~s({"boards": []}))
    end

    test "a version this build does not read" do
      document = ~s({"slipdock_portable": 99, "boards": []})
      assert {:error, {:unsupported_version, 99}} = Portable.import(user_fixture(), document)
    end

    test "a sub-board claimed by two cards is refused before anything is built" do
      # Chained, a shared ref builds 2^depth copies; looped, it never stops.
      user = user_fixture()

      document =
        tree_document(
          [%{ref: "b1", name: "Sub", lists: []}],
          [
            %{ref: "k0", board: "r", title: "One", subcards: "b1"},
            %{ref: "k1", board: "b1", title: "Two", subcards: "b1"}
          ]
        )

      assert {:error, {:bad_sub_board, "b1"}} = Portable.import(user, document)

      assert Repo.aggregate(
               from(b in Slipdock.Boards.Board, where: b.owner_id == ^user.id),
               :count
             ) == 0
    end

    test "a card claiming the root as its sub-board is refused" do
      document = tree_document([], [%{ref: "k0", board: "r", title: "Loop", subcards: "r"}])
      assert {:error, {:bad_sub_board, "r"}} = Portable.import(user_fixture(), document)
    end

    test "a sub-board that only claims itself is never reached, so the import ends" do
      document =
        tree_document(
          [%{ref: "b1", name: "Sub", lists: []}],
          [%{ref: "k1", board: "b1", title: "Self", subcards: "b1"}]
        )

      assert {:ok, %{cards: 0}} = Portable.import(user_fixture(), document)
    end

    test "more of one kind of row than a document may carry is refused" do
      checklist = List.duplicate(%{text: "x"}, Portable.max_rows() + 1)

      document =
        tree_document([], [%{ref: "k0", board: "r", title: "Heavy", checklist: checklist}])

      assert {:error, {:too_many, :checklist, _, _}} = Portable.import(user_fixture(), document)
    end

    test "nested folders written children-first are all built, each under its parent" do
      # The order the old fixpoint was quadratic on: every pass placed one.
      depth = 2_000

      folders =
        for n <- depth..1//-1 do
          %{ref: "f#{n}", board: "r", name: "F#{n}", slug: "f#{n}", parent: n > 1 && "f#{n - 1}"}
        end

      folders = folders ++ [%{ref: "orphan", board: "r", name: "O", slug: "o", parent: "gone"}]
      document = tree_document([], [], folders: folders)

      {micros, {:ok, %{boards: [%{id: board_id}]}}} =
        :timer.tc(fn -> Portable.import(user_fixture(), document) end)

      assert micros < 30_000_000

      built =
        Repo.all(
          from f in Slipdock.Wiki.Folder,
            where: f.board_id == ^board_id,
            select: {f.name, f.parent_id}
        )

      assert length(built) == depth

      by_name =
        Map.new(
          Repo.all(
            from f in Slipdock.Wiki.Folder, where: f.board_id == ^board_id, select: {f.name, f.id}
          )
        )

      assert {"F2", by_name["F1"]} in built
      assert {"F1", nil} in built
    end

    test "a boards value that is not a list is not an export" do
      assert {:error, :not_a_slipdock_export} =
               Portable.import(user_fixture(), ~s({"slipdock_portable": 1, "boards": "x"}))
    end

    test "a row that is not a map is not an export" do
      document = tree_document([], [%{ref: "c1", board: "r", title: "Fine"}], tags: ["nope"])
      assert {:error, :not_a_slipdock_export} = Portable.import(user_fixture(), document)
    end

    test "rows go through the changesets: bad ones are left out and reported" do
      document =
        tree_document(
          [],
          [
            %{
              ref: "c1",
              board: "r",
              title: "Good",
              urls: [%{url: "javascript:alert(1)"}, %{url: "https://ok.example"}]
            },
            %{ref: "c2", board: "r", title: "Shouty", priority: "urgent!!"},
            %{ref: "c3", board: "r", title: "Flagged", flags: ["pwned"]},
            %{ref: "c4", board: "r", title: "Nowhere", list: "missing"}
          ],
          tags: [%{ref: "t1", name: "dup"}, %{ref: "t2", name: "dup"}]
        )

      {:ok, report} = Portable.import(user_fixture(), document)
      board = Boards.get_board!(hd(report.boards).id)

      good = card(board, "Good") |> Repo.preload(:urls)
      assert Enum.map(good.urls, & &1.url) == ["https://ok.example"]
      assert card(board, "Shouty") == nil
      assert card(board, "Flagged") == nil
      assert card(board, "Nowhere") == nil
      assert report.cards == 1

      skipped = Enum.join(report.skipped, "\n")
      assert skipped =~ "A link on “Good” was left out"
      assert skipped =~ "The card “Shouty” was left out: priority"
      assert skipped =~ "The tag “dup” was left out"
    end

    test "a root board that fails its changeset aborts the import with a reason" do
      document =
        Jason.encode!(%{
          slipdock_portable: 1,
          boards: [%{root: %{ref: "r", name: "Imported", color: "not-a-colour", lists: []}}]
        })

      assert {:error, {:invalid, message}} = Portable.import(user_fixture(), document)
      assert message =~ "The board “Imported” was left out: color"
    end

    test "dependencies get the self, same-board and circle checks" do
      document =
        tree_document(
          [],
          [
            %{ref: "a", board: "r", title: "A", blocked_by: ["a", "b"]},
            %{ref: "b", board: "r", title: "B", blocked_by: ["a"]}
          ]
        )

      {:ok, report} = Portable.import(user_fixture(), document)

      assert Repo.aggregate(
               from(d in "card_dependencies",
                 where:
                   d.blocked_id in subquery(
                     from(c in Slipdock.Boards.Card,
                       where: c.board_id == ^hd(report.boards).id,
                       select: c.id
                     )
                   )
               ),
               :count
             ) == 1

      skipped = Enum.join(report.skipped, "\n")
      assert skipped =~ "cannot depend on itself"
      assert skipped =~ "would make a circle"
    end

    test "a blank page code does not rewrite every word boundary" do
      document =
        tree_document([], [],
          pages: [%{ref: "p1", board: "r", title: "One", code: "", body: "Some words here."}]
        )

      {:ok, report} = Portable.import(user_fixture(), document)
      [page] = Repo.all(from(p in Slipdock.Wiki.Page, where: p.board_id == ^hd(report.boards).id))
      assert page.body == "Some words here."
    end

    test "keys it has never heard of do not become atoms" do
      # A hostile document must not be able to fill the atom table.
      document =
        ~s({"slipdock_portable": 1, "boards": [], "surprise_#{System.unique_integer([:positive])}": 1})

      assert {:ok, %{cards: 0}} = Portable.import(user_fixture(), document)
    end

    test "an assignee with no account here lands unassigned, and is reported" do
      owner = user_fixture("owner@example.com")
      board = populated(owner)
      epic = card(board, "Ship it")

      stranger = user_fixture("stranger@example.com")
      share_fixture(board, stranger)
      {:ok, _} = Boards.update_card(epic, %{"assignee_id" => stranger.id})

      exported = owner |> Portable.export() |> Jason.encode!()
      document = String.replace(exported, "stranger@example.com", "gone@example.com")

      {:ok, report} = Portable.import(owner, document)
      imported = Boards.get_board!(hd(report.boards).id)

      assert card(imported, "Ship it").assignee_id == nil
      assert Enum.any?(report.skipped, &(&1 =~ "gone@example.com can't see this board yet"))

      # An address that does have an account reads exactly the same, so the
      # report is no way of finding out who is on the server.
      {:ok, report} = Portable.import(owner, exported)
      imported = Boards.get_board!(hd(report.boards).id)

      assert card(imported, "Ship it").assignee_id == nil

      assert "stranger@example.com can't see this board yet, so what was theirs came in unassigned." in report.skipped
    end
  end
end
