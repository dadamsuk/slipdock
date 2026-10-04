defmodule SlipdockWeb.SubBoardsLiveTest do
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures
  alias Slipdock.Boards

  setup do
    board = board_fixture(%{"name" => "Root board"})
    [backlog | _] = board.columns
    card = card_fixture(backlog, %{"title" => "Epic card"})
    %{board: reload(board), card: card}
  end

  test "adding subcards from the card modal, then navigating into the sub-board", %{
    conn: conn,
    board: board,
    card: card
  } do
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/cards/#{card.id}")
    view |> element("button", "Add subcards") |> render_click()
    {:ok, t} = Boards.find_template("Simple")

    view
    |> element("button[phx-click=create_sub_board][phx-value-template='#{t.id}']")
    |> render_click()

    card = Boards.get_card!(card.id)
    assert card.sub_board.name == "Epic card"
    html = render(view)
    assert html =~ "Open board" and html =~ "To Do" and html =~ "Doing"

    # Quick-add a subcard from the modal and tick it off.
    [todo | _] = Boards.get_board!(card.sub_board.id).columns
    view |> form("#add-subcard-#{todo.id}-0", %{"title" => "Sub one"}) |> render_submit()
    [sub] = Boards.get_board!(card.sub_board.id).columns |> hd() |> Map.get(:cards)
    assert sub.title == "Sub one"
    view |> element("#subcard-#{sub.id} button[phx-click=toggle_subcard]") |> render_click()
    assert Boards.get_card!(sub.id).completed
    assert render(view) =~ "1/1 done"
    assert has_element?(view, "#card-#{card.id} button[title^='1 of 1 subcards done']", "1/1")

    # The sub-board page shows a breadcrumb back to the root and shares tags.
    {:ok, sub_view, html} = live(conn, ~p"/boards/#{card.sub_board.id}")
    assert html =~ "Sub one"
    assert has_element?(sub_view, "nav a[href='/boards/#{board.id}']", "Root board")

    # The card is not a crumb of its own: the sub-board after it carries its name.
    refute has_element?(sub_view, "nav span a[href='/boards/#{board.id}/cards/#{card.id}']")

    # The board header itself links to the card that owns the sub-board.
    assert has_element?(
             sub_view,
             "a[href='/boards/#{board.id}/cards/#{card.id}'][title^='Open the parent card']",
             "Parent card"
           )

    refute has_element?(view, "a[title^='Open the parent card']")

    # Opening a subcard shows a link back to the parent card; the root card
    # has none. Following it lands on the parent card's modal.
    {:ok, sub_view, _} = live(conn, ~p"/boards/#{card.sub_board.id}/cards/#{sub.id}")
    parent_link = "#card-modal a[href='/boards/#{board.id}/cards/#{card.id}']"
    assert has_element?(sub_view, parent_link, "Epic card")
    assert has_element?(sub_view, parent_link, "on Root board")
    refute has_element?(view, "#card-modal a", "Parent card")

    {:ok, parent_view, html} =
      sub_view |> element(parent_link) |> render_click() |> follow_redirect(conn)

    assert html =~ "Epic card"
    assert has_element?(parent_view, "#card-modal #card-title", "Epic card")

    # Removing the subcards deletes the sub-board.
    view |> element("button[phx-click=delete_sub_board]") |> render_click()
    assert is_nil(Boards.get_card!(card.id).sub_board)
  end

  test "a card with subcards opens as a board in one click, from the modal or the tile", %{
    conn: conn,
    board: board,
    card: card
  } do
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/cards/#{card.id}")
    refute has_element?(view, "#card-open-board")
    refute has_element?(view, "#card-#{card.id} button[title*='open them as a board']")

    {:ok, t} = Boards.find_template("Simple")
    {:ok, sub} = Boards.create_sub_board(card, t)
    [todo | _] = Boards.get_board!(sub.id).columns
    card_fixture(todo, %{"title" => "Sub one"})

    {:ok, view, _} = live(conn, ~p"/boards/#{board}/cards/#{card.id}")
    assert has_element?(view, "#card-open-board", "0 of 1 done")

    {:ok, _, html} =
      view
      |> element("#card-open-board a", "Open board")
      |> render_click()
      |> follow_redirect(conn, ~p"/boards/#{sub.id}")

    assert html =~ "Sub one"

    # On the board, the tile's subcards chip goes straight to the sub-board
    # rather than opening the card.
    {:ok, view, _} = live(conn, ~p"/boards/#{board}")

    assert {:error, {:live_redirect, %{to: to}}} =
             view
             |> element("#card-#{card.id} button[title*='open them as a board']")
             |> render_click()

    assert to == "/boards/#{sub.id}"
  end

  test "templates page creates and edits a template", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/templates")
    assert render(view) =~ "Bug triage"

    view |> element("button", "New template") |> render_click()
    view |> element("button[phx-click=add_column]") |> render_click()
    assert has_element?(view, "#tcol-3")

    view
    |> form("#template-form", %{
      "name" => "Sprint",
      "description" => "Two weeks",
      "columns" => %{
        "0" => %{"name" => "Todo"},
        "1" => %{"name" => "Doing", "wip_limit" => "2", "color" => "amber"},
        "2" => %{"name" => "Done", "color" => "emerald"},
        "3" => %{"name" => ""}
      }
    })
    |> render_submit()

    {:ok, t} = Boards.find_template("Sprint")
    assert Enum.map(t.columns, & &1["name"]) == ["Todo", "Doing", "Done"]
    assert Enum.at(t.columns, 1)["wip_limit"] == 2
    assert render(view) =~ "Saved template"

    view |> element("#template-#{t.id} button", "Edit") |> render_click()
    view |> element("#tcol-0 button[phx-value-dir=down]") |> render_click()
    view |> form("#template-form") |> render_submit()
    assert Enum.map(Boards.get_template!(t.id).columns, & &1["name"]) == ["Doing", "Todo", "Done"]
  end

  test "the board index can create a board from a template", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/")
    view |> element("button", "New board") |> render_click()
    {:ok, t} = Boards.find_template("Checklist")

    assert {:error, {:live_redirect, %{to: to}}} =
             view
             |> form("#new-board", %{
               "board" => %{"name" => "Tick"},
               "template" => to_string(t.id)
             })
             |> render_submit()

    id = to |> String.split("/") |> List.last() |> String.to_integer()
    assert Enum.map(Boards.get_board!(id).columns, & &1.name) == ["Open", "Done"]
  end

  test "a card with a title longer than a board name can still have subcards", %{card: card} do
    long = String.duplicate("word ", 30) |> String.trim()
    {:ok, card} = Boards.update_card(card, %{"title" => long})
    {:ok, t} = Boards.find_template("Simple")

    assert {:ok, sub} = Boards.create_sub_board(card, t)
    assert String.length(sub.name) == 80 and String.ends_with?(sub.name, "…")

    # A rename keeps the sub-board's name inside the limit too.
    {:ok, _} = Boards.update_card(Boards.get_card!(card.id), %{"title" => long <> " again"})
    assert String.length(Boards.get_board!(sub.id).name) <= 80
  end
end
