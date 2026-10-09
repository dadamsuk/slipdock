defmodule SlipdockWeb.QuickAddLiveTest do
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures
  alias Slipdock.Boards

  setup do
    board = board_fixture(%{"name" => "Plan"})
    tag_fixture(board, "docs")
    %{board: reload(board)}
  end

  defp cards(board) do
    board |> reload() |> Map.get(:columns) |> Enum.flat_map(& &1.cards)
  end

  test "the table view adds a card from one line, keeping the input ready", %{
    conn: conn,
    board: board
  } do
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/table")
    assert has_element?(view, "#table-add input[name=title][phx-hook=QuickAdd]")

    # Typing previews the commands.
    html =
      view
      |> form("#table-add", %{"title" => "Write it due: tomorrow #high #todo #docs #bogus"})
      |> render_change()

    assert html =~ "Due "
    assert html =~ ">high<" or html =~ " high\n"
    assert html =~ "To Do"
    assert html =~ "docs"
    assert html =~ "#bogus"

    view
    |> form("#table-add", %{"title" => "Write it due: tomorrow #high #todo #docs #bogus"})
    |> render_submit()

    assert_push_event(view, "quick_added", %{form: "table-add"})

    [card] = cards(board)
    assert card.title == "Write it #bogus"
    assert card.priority == "high"
    assert card.due_date == Date.add(Date.utc_today(), 1)
    assert Enum.find(board.columns, &(&1.id == card.column_id)).name == "To Do"
    assert Enum.map(card.tags, & &1.name) == ["docs"]
    refute render(view) =~ "chip-tint text-warning"
  end

  test "a list's add-a-card box puts what follows a semicolon in the comments", %{
    conn: conn,
    board: board
  } do
    [backlog | _] = board.columns
    {:ok, view, _} = live(conn, ~p"/boards/#{board}")
    render_click(view, "start_add_card", %{"id" => to_string(backlog.id)})
    assert render(view) =~ "Card title; a comment, then Enter"

    view
    |> form("#quick-add-#{backlog.id}-0", %{
      "title" => "Fix the login #high; seen on Safari only; #docs"
    })
    |> render_submit()

    [card] = cards(board)
    assert card.title == "Fix the login"
    assert card.priority == "high"
    assert card.column_id == backlog.id
    assert card.tags == []
    assert [%{body: "seen on Safari only; #docs"}] = Boards.get_card!(card.id).comments

    # Nothing after the semicolon: just the card.
    render_click(view, "start_add_card", %{"id" => to_string(backlog.id)})

    render_hook(view, "quick_add_card", %{
      "column_id" => to_string(backlog.id),
      "title" => "Bare;  "
    })

    bare = Enum.find(cards(board), &(&1.title == "Bare"))
    assert Boards.get_card!(bare.id).comments == []
  end

  test "the comment shows as a chip while typing", %{conn: conn, board: board} do
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/table")

    html =
      view
      |> form("#table-add", %{"title" => "Write it; with a note"})
      |> render_change()

    assert html =~ "hero-chat-bubble-left"
  end

  test "a grouped table adds into the group", %{conn: conn, board: board} do
    card_fixture(hd(board.columns), %{"title" => "Existing", "priority" => "critical"})
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/table?rows=priority")
    assert has_element?(view, "#table-add-critical")
    refute has_element?(view, "#table-add")

    view |> form("#table-add-critical", %{"title" => "Hotfix"}) |> render_submit()
    assert %{priority: "critical"} = Enum.find(cards(board), &(&1.title == "Hotfix"))
  end

  test "the outline adds top-level cards and subcards", %{conn: conn, board: board} do
    [backlog | _] = board.columns
    epic = card_fixture(backlog, %{"title" => "Epic"})
    {:ok, t} = Boards.find_template("Simple")
    {:ok, _sub} = sub_board(epic, t)

    {:ok, view, _} = live(conn, ~p"/boards/#{board}/outline")
    assert has_element?(view, "#outline-add")
    assert has_element?(view, "#outline-add-#{epic.id}")

    view |> form("#outline-add", %{"title" => "Sibling start: today"}) |> render_submit()
    assert Enum.any?(cards(board), &(&1.title == "Sibling" and &1.start_date == Date.utc_today()))

    view |> form("#outline-add-#{epic.id}", %{"title" => "Child task #medium"}) |> render_submit()
    sub = Boards.get_board!(Boards.get_card!(epic.id).sub_board.id)
    assert [%{title: "Child task", priority: "medium"}] = Enum.flat_map(sub.columns, & &1.cards)
    assert render(view) =~ "Child task"
  end

  test "read-only viewers get no add rows", %{conn: conn, board: board} do
    stranger = user_fixture("stranger@example.com")
    {:ok, _} = Slipdock.Access.grant(board, stranger, "read", user_fixture())
    {:ok, view, _} = live(log_in_user(conn, stranger), ~p"/boards/#{board}/table")
    refute has_element?(view, "#table-add")
  end
end
