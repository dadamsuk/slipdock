defmodule SlipdockWeb.HeaderQuickAddLiveTest do
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Repo}

  setup do
    board = board_fixture(%{"name" => "Plan"})
    %{board: reload(board)}
  end

  defp cards(board),
    do: board |> reload() |> Map.get(:columns) |> Enum.flat_map(& &1.cards)

  test "the header opens a one-line box and the model's reading becomes a card", %{
    conn: conn,
    board: board,
    user: user
  } do
    Slipdock.AIStub.reply_with(%{
      "title" => "Call the printers",
      "column" => "To Do",
      "priority" => "critical",
      "due_date" => Date.to_iso8601(Date.add(Date.utc_today(), 4))
    })

    {:ok, view, html} = live(conn, ~p"/")
    assert html =~ "Quick add"
    refute has_element?(view, "#quick-add-panel")

    view |> element("#quick-add-open") |> render_click()
    assert has_element?(view, "#quick-add-input-0")
    assert render(view) =~ "Goes to"
    assert render(view) =~ "Plan"

    view
    |> form("#quick-add-form-0", %{"text" => "call the printers friday, urgent, into to do"})
    |> render_submit()

    html = render_async(view)
    assert html =~ "Call the printers"
    assert html =~ "added to Plan › To Do"
    assert html =~ "critical"

    assert [card] = cards(board)
    assert card.title == "Call the printers"
    assert card.priority == "critical"
    assert card.assignee_id == nil
    assert Repo.reload!(user).quick_add_ai

    # The box is ready for the next line: a fresh, empty, focused input.
    assert has_element?(view, "#quick-add-form-1 input[name=text]")
    assert has_element?(view, "#quick-add-input-1")
    refute has_element?(view, "#quick-add-input-0")

    input = view |> element("#quick-add-input-1") |> render()
    refute input =~ "call the printers"
    assert input =~ ~s(value="")
  end

  test "a line that goes nowhere says so and keeps what was typed", %{conn: conn} do
    Slipdock.AIStub.fail_with(500, "upstream exploded")
    {:ok, view, _} = live(conn, ~p"/work")

    view |> element("#quick-add-open") |> render_click()

    view
    |> form("#quick-add-form-0", %{"text" => "  "})
    |> render_submit()

    refute render(view) =~ "added to"
  end

  test "the account page sets where quick adds land", %{conn: conn, user: user} do
    other = board_fixture(%{"name" => "Errands"})
    doing = Enum.find(other.columns, &(&1.name == "In Progress"))

    {:ok, view, _} = live(conn, ~p"/account/settings")
    assert has_element?(view, "#quick-add-form-settings")

    view
    |> form("#quick-add-form-settings", %{
      "user" => %{"quick_add_board_id" => other.id}
    })
    |> render_change()

    view
    |> form("#quick-add-form-settings", %{
      "user" => %{
        "quick_add_board_id" => other.id,
        "quick_add_column_id" => doing.id,
        "quick_add_ai" => "false"
      }
    })
    |> render_submit()

    # The flash is the page's, sent up by the tab, so it lands a render later.
    assert render(view) =~ "Quick add settings saved."

    user = Repo.reload!(user)
    assert user.quick_add_board_id == other.id
    assert user.quick_add_column_id == doing.id
    refute user.quick_add_ai

    # …and the header box follows the setting, with no model in the way.
    view |> element("#quick-add-open") |> render_click()
    assert render(view) =~ "Errands"

    view
    |> form("#quick-add-form-0", %{"text" => "Pick up the parcel due: tomorrow"})
    |> render_submit()

    html = render_async(view)
    assert html =~ "added to Errands › In Progress"
    refute_receive {:ai_request, _}

    assert [card] = other |> reload() |> Map.get(:columns) |> Enum.flat_map(& &1.cards)
    assert card.title == "Pick up the parcel"
    assert card.due_date == Date.add(Date.utc_today(), 1)
  end

  test "switching board in the settings drops a list from the old one", %{
    conn: conn,
    board: board,
    user: user
  } do
    backlog = Enum.find(board.columns, &(&1.name == "Backlog"))
    {:ok, user} = Accounts.update_quick_add(user, %{"quick_add_column_id" => backlog.id})
    other = board_fixture(%{"name" => "Errands"})

    {:ok, view, _} = live(conn, ~p"/account/settings")

    html =
      view
      |> form("#quick-add-form-settings", %{"user" => %{"quick_add_board_id" => other.id}})
      |> render_change()

    # The list select now offers the new board's lists only.
    assert user.quick_add_column_id == backlog.id
    assert html =~ "Errands"

    lists =
      view
      |> element("#quick-add-form-settings select[name='user[quick_add_column_id]']")
      |> render()

    refute lists =~ ~s(value="#{backlog.id}")
    assert lists =~ ~s(value="#{Enum.find(other.columns, &(&1.name == "Backlog")).id}")
  end

  # #3107: a list that has gone since the form was drawn. The select can't
  # offer it, so the submit goes past the form, as a stale page's would.
  test "saving a deleted list is refused: nothing is stored and the form comes back", %{
    conn: conn,
    board: board,
    user: user
  } do
    gone = Enum.find(board.columns, &(&1.name == "Backlog"))
    {:ok, _} = Slipdock.Boards.Columns.delete_column(gone)

    {:ok, view, _} = live(conn, ~p"/account/settings")

    view
    |> element("#quick-add-form-settings")
    |> render_submit(%{
      "user" => %{"quick_add_board_id" => board.id, "quick_add_column_id" => gone.id}
    })

    html = render(view)
    refute html =~ "Quick add settings saved."
    assert has_element?(view, "#quick-add-form-settings")

    lists =
      view
      |> element("#quick-add-form-settings select[name='user[quick_add_column_id]']")
      |> render()

    refute lists =~ ~s(value="#{gone.id}")

    stored = Repo.reload!(user)
    assert stored.quick_add_board_id == user.quick_add_board_id
    assert stored.quick_add_column_id == user.quick_add_column_id
  end

  # #3107: board A with a list from board B, as a hand-made submit could send.
  # What happens today: the setting is stored as sent (the changeset checks
  # only that both exist), and the header box ignores the foreign list, so the
  # card lands on board A's first list, never on board B.
  test "a board saved with another board's list keeps cards on the chosen board", %{
    conn: conn,
    board: board,
    user: user
  } do
    other = board_fixture(%{"name" => "Errands"})
    foreign = Enum.find(other.columns, &(&1.name == "In Progress"))
    first = Enum.min_by(board.columns, & &1.position)

    {:ok, view, _} = live(conn, ~p"/account/settings")

    view
    |> element("#quick-add-form-settings")
    |> render_submit(%{
      "user" => %{
        "quick_add_board_id" => board.id,
        "quick_add_column_id" => foreign.id,
        "quick_add_ai" => "false"
      }
    })

    assert render(view) =~ "Quick add settings saved."

    stored = Repo.reload!(user)
    assert stored.quick_add_board_id == board.id
    assert stored.quick_add_column_id == foreign.id

    view |> element("#quick-add-open") |> render_click()

    view
    |> form("#quick-add-form-0", %{"text" => "Water the plants"})
    |> render_submit()

    html = render_async(view)
    assert html =~ "added to Plan › #{first.name}"

    assert [card] = cards(board)
    assert card.title == "Water the plants"
    assert card.column_id == first.id
    assert [] == other |> reload() |> Map.get(:columns) |> Enum.flat_map(& &1.cards)
  end
end
