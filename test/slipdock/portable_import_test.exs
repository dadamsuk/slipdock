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
      assert [%{health: "on_track", body: "On track"}] = epic.status_updates
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

    test "an assignee who has an account here comes through as that person", %{
      owner: owner,
      receiver: receiver
    } do
      board = Boards.get_board!(owned(owner) |> hd() |> Map.fetch!(:id))
      epic = card(board, "Ship it")
      {:ok, _} = Boards.update_card(epic, %{"assignee_id" => owner.id})

      # The receiver's server knows the owner's address, so it resolves.
      {_report, imported} = round_trip(owner, receiver)
      assert card(imported, "Ship it").assignee_id == owner.id
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

  describe "the card limit" do
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

      assert {:error, {:card_limit_reached, 3, 2}} = Portable.import(receiver, document)
      assert owned(receiver) == []
    end

    test "it fits when there is room", %{owner: owner, receiver: receiver} do
      {:ok, _} = Settings.complete_setup(%{"admin_email" => "a@example.com"})
      {:ok, _} = Settings.update(%{"free_card_limit" => 10})

      document = owner |> Portable.export() |> Jason.encode!()
      assert {:ok, %{cards: 3}} = Portable.import(receiver, document)
      assert Quota.used(receiver) == 3
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
      {:ok, _} = Boards.update_card(epic, %{"assignee_id" => stranger.id})

      document = owner |> Portable.export() |> Jason.encode!()
      document = String.replace(document, "stranger@example.com", "gone@example.com")

      {:ok, report} = Portable.import(owner, document)
      imported = Boards.get_board!(hd(report.boards).id)

      assert card(imported, "Ship it").assignee_id == nil
      assert Enum.any?(report.skipped, &(&1 =~ "gone@example.com has no account here"))
    end
  end
end
