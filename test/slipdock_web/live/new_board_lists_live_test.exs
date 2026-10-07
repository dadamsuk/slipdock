defmodule SlipdockWeb.NewBoardListsLiveTest do
  @moduledoc """
  "Custom lists…" on the new board form: the lists typed one per line, and
  the option of keeping them as a template.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  alias Slipdock.Boards

  defp open_form(conn) do
    {:ok, view, _} = live(conn, ~p"/")
    render_click(view, "start_create", %{})
    view
  end

  defp lists(board_id), do: Boards.get_board!(board_id).columns |> Enum.map(& &1.name)

  defp only_board(user) do
    [board] = Slipdock.Access.list_boards(user)
    board
  end

  test "the lists box only shows once Custom lists is picked, filled with the defaults",
       %{conn: conn} do
    view = open_form(conn)
    refute has_element?(view, "#new-board-lists")
    assert has_element?(view, ~s(#new-board select option[value="custom"]), "Custom lists")

    view |> form("#new-board", board: %{"name" => "X"}, template: "custom") |> render_change()

    assert view |> element("#new-board-lists-text") |> render() =~
             "Backlog\nTo Do\nIn Progress\nDone"

    refute has_element?(view, "#new-board-template-name")
  end

  test "creates the board with the lists typed, and no template", %{conn: conn, user: user} do
    view = open_form(conn)

    view
    |> form("#new-board", board: %{"name" => "Garden"}, template: "custom")
    |> render_change()

    view
    |> form("#new-board",
      board: %{"name" => "Garden"},
      template: "custom",
      lists: "Seeds\r\nGrowing\n\nHarvested"
    )
    |> render_submit()

    board = only_board(user)
    assert lists(board.id) == ["Seeds", "Growing", "Harvested"]
    assert board.template_id == nil
  end

  test "Save as a template keeps the lists under the name given", %{conn: conn, user: user} do
    name = "Garden #{System.unique_integer([:positive])}"
    view = open_form(conn)

    view
    |> form("#new-board", board: %{"name" => "Garden"}, template: "custom")
    |> render_change()

    view
    |> form("#new-board",
      board: %{"name" => "Garden"},
      template: "custom",
      lists: "Seeds\nDone",
      save_template: "true"
    )
    |> render_change()

    assert has_element?(view, "#new-board-template-name")

    view
    |> form("#new-board",
      board: %{"name" => "Garden"},
      template: "custom",
      lists: "Seeds\nDone",
      save_template: "true",
      template_name: name
    )
    |> render_submit()

    assert {:ok, t} = Boards.find_template(name)
    assert Enum.map(t.columns, & &1["name"]) == ["Seeds", "Done"]
    assert only_board(user).template_id == t.id
  end

  test "a blank template name uses the board's", %{conn: conn} do
    name = "Orchard #{System.unique_integer([:positive])}"
    view = open_form(conn)
    view |> form("#new-board", board: %{"name" => name}, template: "custom") |> render_change()

    view
    |> form("#new-board", board: %{"name" => name}, template: "custom", save_template: "true")
    |> render_change()

    view
    |> form("#new-board",
      board: %{"name" => name},
      template: "custom",
      lists: "A",
      save_template: "true",
      template_name: "  "
    )
    |> render_submit()

    assert {:ok, _} = Boards.find_template(name)
  end

  test "a taken template name is said on the form, which keeps what was typed",
       %{conn: conn, user: user} do
    name = "Taken #{System.unique_integer([:positive])}"
    {:ok, _} = Boards.create_template(%{"name" => name, "columns" => ["X"]})
    view = open_form(conn)
    view |> form("#new-board", board: %{"name" => "Clash"}, template: "custom") |> render_change()

    view
    |> form("#new-board", board: %{"name" => "Clash"}, template: "custom", save_template: "true")
    |> render_change()

    html =
      view
      |> form("#new-board",
        board: %{"name" => "Clash"},
        template: "custom",
        lists: "Mine\nOurs",
        save_template: "true",
        template_name: name
      )
      |> render_submit()

    assert html =~ "a template called “#{name}” already exists"
    assert view |> element("#new-board-lists-text") |> render() =~ "Mine\nOurs"
    assert Slipdock.Access.list_boards(user) == []
  end

  test "no lists at all is said on the form", %{conn: conn, user: user} do
    view = open_form(conn)
    view |> form("#new-board", board: %{"name" => "Bare"}, template: "custom") |> render_change()

    html =
      view
      |> form("#new-board", board: %{"name" => "Bare"}, template: "custom", lists: "\n \n")
      |> render_submit()

    assert html =~ "add at least one list"
    assert Slipdock.Access.list_boards(user) == []
  end

  test "picking a template still ignores the lists box", %{conn: conn, user: user} do
    {:ok, t} = Boards.find_template("Checklist")
    view = open_form(conn)

    view
    |> form("#new-board", board: %{"name" => "Plain"}, template: to_string(t.id))
    |> render_submit()

    assert lists(only_board(user).id) == Enum.map(t.columns, & &1["name"])
  end
end
