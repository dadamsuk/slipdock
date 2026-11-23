defmodule SlipdockWeb.TableAddFieldTest do
  @moduledoc """
  Adding a field from the table's header (#3610): a writer of the tree's
  root board (who may change its fields in board settings) has a "+" that
  takes a name and a type, makes the field, shows it as a column and
  focuses its first cell. Anyone else sees no "+", and the event sent by
  hand is refused.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Access, Boards, Fields}
  alias Slipdock.Boards.FieldDefinition

  setup %{user: user} do
    board = board_fixture(%{"name" => "Contacts"}, owner: user)
    [_backlog, todo | _] = board.columns
    first = card_fixture(todo, %{"title" => "Ada"})
    card_fixture(todo, %{"title" => "Grace"})
    %{board: board, first: first}
  end

  defp add(view, attrs), do: view |> form("#add-field-form", attrs) |> render_submit()

  test "a writer adds a field, which shows as a column with its first cell focused",
       %{conn: conn, board: board, first: first} do
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/table")
    assert has_element?(view, "#card-table thead [data-role=add-field]")
    refute has_element?(view, "#add-field-form option[value=formula]")

    add(view, %{"name" => "Email", "kind" => "text", "options" => ""})

    [field] = Fields.list_fields(board.id)
    assert {field.name, field.kind} == {"Email", "text"}

    path = assert_patch(view)
    assert path =~ "f%3A#{field.id}" or path =~ "f:#{field.id}"
    assert has_element?(view, "#card-table thead th", "Email")

    # The first row's new cell is the one focused when it is drawn.
    focused = "#row-all-#{first.id} [phx-mounted] [data-field-cell=email] input[name=value]"
    assert has_element?(view, focused)

    # And it is a cell to type in: the value is the card's.
    view
    |> form("#row-all-#{first.id} [data-field-cell=email] form", %{"value" => "ada@example.com"})
    |> render_change()

    assert Fields.value(Boards.Cards.get_card!(first.id), field) == "ada@example.com"
  end

  # Inside the table's scrollbox an ordinary dropdown was clipped and ran off
  # the right of the screen: the form opens in the browser's top layer,
  # placed beside the "+" by AnchoredPopover.
  test "the add-field form is a popover anchored to the +", %{conn: conn, board: board} do
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/table")

    assert has_element?(view, "#card-table thead button#add-field[popovertarget=add-field-menu]")

    assert has_element?(
             view,
             "#add-field-menu[popover][phx-hook=AnchoredPopover][data-anchor=add-field] #add-field-form"
           )
  end

  test "a choice takes its options from the same form", %{conn: conn, board: board} do
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/table")
    add(view, %{"name" => "Stage", "kind" => "select", "options" => "Lead, Won"})

    [field] = Fields.list_fields(board.id)
    assert Enum.map(field.options, & &1["label"]) == ["Lead", "Won"]
  end

  test "a choice can allow several from the same form; another kind ignores it",
       %{conn: conn, board: board} do
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/table")
    assert has_element?(view, ~s|#add-field-form input[type=checkbox][name=several]|)

    add(view, %{
      "name" => "Tags",
      "kind" => "select",
      "options" => "Friend, Work",
      "several" => "true"
    })

    add(view, %{"name" => "Stage", "kind" => "select", "options" => "Lead, Won"})
    add(view, %{"name" => "Notes", "kind" => "text", "options" => "", "several" => "true"})

    by_name = Map.new(Fields.list_fields(board.id), &{&1.name, &1})
    assert FieldDefinition.several?(by_name["Tags"])
    refute FieldDefinition.several?(by_name["Stage"])
    assert by_name["Notes"].config == %{}
  end

  test "a choice without options, or a blank name, is refused and says why",
       %{conn: conn, board: board} do
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/table")

    add(view, %{"name" => "Stage", "kind" => "select", "options" => ""})
    assert render(view) =~ "Couldn&#39;t add the field"

    add(view, %{"name" => "", "kind" => "text", "options" => ""})
    assert Fields.list_fields(board.id) == []
  end

  test "a formula is set up in board settings, not here", %{conn: conn, board: board} do
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/table")
    render_submit(view, "table_add_field", %{"name" => "Score", "kind" => "formula"})
    assert render(view) =~ "Set a formula up in board settings."
    assert Fields.list_fields(board.id) == []
  end

  test "a reader sees no + and is refused when sending the event by hand",
       %{board: board, user: user} do
    reader = user_fixture("reader@example.com")
    {:ok, _} = Access.grant(board, reader, "read", user)
    conn = log_in_user(build_conn(), reader)

    {:ok, view, _} = live(conn, ~p"/boards/#{board}/table")
    refute has_element?(view, "[data-role=add-field]")

    render_submit(view, "table_add_field", %{"name" => "Sneaky", "kind" => "text"})
    assert Fields.list_fields(board.id) == []
  end

  test "a writer of a sub-board only, not its root, sees no + and is refused",
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

    render_submit(view, "table_add_field", %{"name" => "Sneaky", "kind" => "text"})
    assert Fields.list_fields(board.id) == []
  end
end
