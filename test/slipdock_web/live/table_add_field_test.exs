defmodule SlipdockWeb.TableAddFieldTest do
  @moduledoc """
  Adding a field from the table's header (#3610): a writer of the tree's
  root board (who may change its fields in board settings) has a "+" that
  opens the field editor board settings uses (#3647), makes the field,
  shows it as a column and focuses its first cell. Anyone else sees no "+"
  and no editor; `Slipdock.Policy` refuses the write itself
  (`policy_cards_test.exs`).
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Access, Boards, Fields}
  alias Slipdock.Boards.FieldDefinition

  @editor "#table-field-editor-form"

  setup %{user: user} do
    board = board_fixture(%{"name" => "Contacts"}, owner: user)
    [_backlog, todo | _] = board.columns
    first = card_fixture(todo, %{"title" => "Ada"})
    card_fixture(todo, %{"title" => "Grace"})
    %{board: board, first: first}
  end

  defp choose(view, kind), do: view |> form(@editor, %{"kind" => kind}) |> render_change()
  defp add(view, attrs), do: view |> form(@editor, attrs) |> render_submit()

  defp add_choice_row(view),
    do: view |> element("#{@editor} [data-role=add-choice]") |> render_click()

  test "a writer adds a field, which shows as a column with its first cell focused",
       %{conn: conn, board: board, first: first} do
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/table")
    assert has_element?(view, "#card-table thead [data-role=add-field]")
    refute has_element?(view, "#{@editor} option[value=formula]")
    # Text is the type a new field starts as, and needs nothing but a name.
    assert has_element?(view, "#{@editor} select[name=kind] option[value=text][selected]")

    add(view, %{"name" => "Notes"})

    [field] = Fields.list_fields(board.id)
    assert {field.name, field.kind, field.config} == {"Notes", "text", %{}}

    path = assert_patch(view)
    assert path =~ "f%3A#{field.id}" or path =~ "f:#{field.id}"
    assert has_element?(view, "#card-table thead th", "Notes")
    # The popover is told to close.
    assert_push_event(view, "popover:hide", %{id: "add-field-menu"})

    # The first row's new cell is the one focused when it is drawn.
    focused = "#row-all-#{first.id} [phx-mounted] [data-field-cell=notes] input[name=value]"
    assert has_element?(view, focused)

    # And it is a cell to type in: the value is the card's.
    view
    |> form("#row-all-#{first.id} [data-field-cell=notes] form", %{"value" => "Met at the fair"})
    |> render_change()

    assert Fields.value(Boards.Cards.get_card!(first.id), field) == "Met at the fair"
  end

  # Inside the table's scrollbox an ordinary dropdown was clipped and ran off
  # the right of the screen (#3646): the editor opens in the browser's top
  # layer, placed beside the "+" by AnchoredPopover.
  test "the editor is a popover anchored to the +", %{conn: conn, board: board} do
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/table")

    assert has_element?(view, "#card-table thead button#add-field[popovertarget=add-field-menu]")

    assert has_element?(
             view,
             "#add-field-menu[popover][phx-hook=AnchoredPopover][data-anchor=add-field] #{@editor}"
           )
  end

  test "a choice's options are rows added in the editor, and can allow several",
       %{conn: conn, board: board} do
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/table")
    choose(view, "select")
    add_choice_row(view)

    add(view, %{
      "name" => "Tags",
      "kind" => "select",
      "options" => %{"0" => %{"label" => "Friend"}, "1" => %{"label" => "Work"}},
      "several" => "true"
    })

    [field] = Fields.list_fields(board.id)
    assert Enum.map(field.options, & &1["label"]) == ["Friend", "Work"]
    assert FieldDefinition.several?(field)
  end

  test "a number takes its least, most, step and unit", %{conn: conn, board: board} do
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/table")
    choose(view, "number")

    add(view, %{
      "name" => "Deal",
      "kind" => "number",
      "config" => %{"min" => "0", "max" => "1000", "step" => "", "unit" => "£"}
    })

    [field] = Fields.list_fields(board.id)
    assert field.config == %{"min" => 0.0, "max" => 1000.0, "unit" => "£"}
  end

  test "a choice without options, or a blank name, is refused and says why in the editor",
       %{conn: conn, board: board} do
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/table")

    choose(view, "select")
    add(view, %{"name" => "Stage", "kind" => "select"})

    assert has_element?(
             view,
             "#{@editor} [data-role=field-editor-error]",
             "Couldn't add the field"
           )

    # The popover stays open to say so.
    refute_push_event(view, "popover:hide", %{})

    add(view, %{"name" => "", "kind" => "text"})
    assert Fields.list_fields(board.id) == []
  end

  test "a reader sees no + and no editor", %{board: board, user: user} do
    reader = user_fixture("reader@example.com")
    {:ok, _} = Access.grant(board, reader, "read", user)
    conn = log_in_user(build_conn(), reader)

    {:ok, view, _} = live(conn, ~p"/boards/#{board}/table")
    refute has_element?(view, "[data-role=add-field]")
    refute has_element?(view, @editor)
  end

  test "a writer of a sub-board only, not its root, sees no + and no editor",
       %{board: board, user: user, first: first} do
    {:ok, t} = Boards.Templates.find_template(nil, "Simple")
    {:ok, sub} = sub_board(first, t)
    writer = user_fixture("sub-writer@example.com")
    {:ok, _} = Access.grant(first, writer, "write", user)
    conn = log_in_user(build_conn(), writer)

    {:ok, view, _} = live(conn, ~p"/boards/#{sub}/table")
    # They write here (the add row is a writer's), but the fields are the root's.
    assert has_element?(view, "form#table-add")
    refute has_element?(view, "[data-role=add-field]")
    refute has_element?(view, @editor)
  end
end
