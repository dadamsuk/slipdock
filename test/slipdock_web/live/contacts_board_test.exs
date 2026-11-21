defmodule SlipdockWeb.ContactsBoardTest do
  @moduledoc """
  The epic's acceptance test (#3606, spec W-2951 §Done when): a contacts
  board built from a blank board, every column added from the table
  header, using the four new kinds (several choices, checkbox, URL,
  person); its values shown in the table, a field filter kept by a saved
  view, and the fields chosen for them on the card fronts.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Access, Boards, Fields, Filters, Swimlanes}
  alias Slipdock.Boards.FieldDefinition
  alias Slipdock.Swimlanes.Config

  setup %{user: user} do
    board = board_fixture(%{"name" => "Contacts"}, owner: user)
    [_backlog, todo | _] = board.columns
    mate = user_fixture("mate@example.com")
    {:ok, _} = Access.grant(board, mate, "write", user)
    ada = card_fixture(todo, %{"title" => "Ada"})
    grace = card_fixture(todo, %{"title" => "Grace"})
    %{board: board, mate: mate, ada: ada, grace: grace}
  end

  defp add(view, attrs), do: view |> form("#add-field-form", attrs) |> render_submit()
  defp card(card), do: Boards.Cards.get_card!(card.id)

  test "every column comes from the table header, one of each new kind", ctx do
    %{conn: conn, board: board, user: user, mate: mate} = ctx
    assert Fields.list_fields(board.id) == []

    {:ok, view, _} = live(conn, ~p"/boards/#{board}/table")

    add(view, %{
      "name" => "Groups",
      "kind" => "select",
      "options" => "Friend, Work",
      "several" => "true"
    })

    add(view, %{"name" => "Subscribed", "kind" => "checkbox", "options" => ""})
    add(view, %{"name" => "Website", "kind" => "url", "options" => ""})
    add(view, %{"name" => "Owner", "kind" => "person", "options" => ""})
    # Each add patches the address with its column; the last has all four.
    path = Enum.reduce(1..4, nil, fn _, _ -> assert_patch(view) end)

    fields = Map.new(Fields.list_fields(board.id), &{&1.name, &1})

    assert Map.new(fields, fn {name, f} -> {name, f.kind} end) == %{
             "Groups" => "select",
             "Subscribed" => "checkbox",
             "Website" => "url",
             "Owner" => "person"
           }

    assert FieldDefinition.several?(fields["Groups"])

    for name <- Map.keys(fields), do: assert(has_element?(view, "#card-table thead th", name))

    {:ok, _} = Fields.set_value(card(ctx.ada), fields["Groups"], "Friend, Work")
    {:ok, _} = Fields.set_value(card(ctx.ada), fields["Subscribed"], "true")
    {:ok, _} = Fields.set_value(card(ctx.ada), fields["Website"], "https://www.example.com/ada")
    {:ok, _} = Fields.set_value(card(ctx.ada), fields["Owner"], "#{user.email}, #{mate.email}")
    {:ok, _} = Fields.set_value(card(ctx.grace), fields["Groups"], "Work")

    # Each value shows in its column, the link as its host.
    {:ok, view, _} = live(conn, path)
    row = "#row-all-#{ctx.ada.id}"
    assert has_element?(view, ~s|#{row} a[data-role="field-link"]|, "example.com")
    html = view |> element(row) |> render()
    assert html =~ "Friend" and html =~ "Work"

    # A saved view keeps a field filter: Friend keeps Ada, not Grace.
    filters = Filters.put_field(Filters.empty(), fields["Groups"], %{"option" => "friend"})
    saved = %{Config.defaults("table") | field_filters: Filters.saved_fields(filters)}

    reopened =
      saved
      |> Config.to_query()
      |> Plug.Conn.Query.encode()
      |> Plug.Conn.Query.decode()
      |> Config.from_query(Config.defaults("table"))

    cards = Fields.decorate([card(ctx.ada), card(ctx.grace)], Map.values(fields))

    assert cards |> Enum.filter(&Swimlanes.matches?(&1, reopened)) |> Enum.map(& &1.title) == [
             "Ada"
           ]

    # The card front shows the fields chosen for it, and only those.
    {:ok, _} = Fields.update_field(fields["Website"], %{"show_on_cards" => true})
    {:ok, _} = Fields.update_field(fields["Subscribed"], %{"show_on_cards" => true})
    {:ok, board_view, _} = live(conn, ~p"/boards/#{board}")

    front =
      board_view
      |> render()
      |> Floki.parse_document!()
      |> Floki.find(~s|#card-#{ctx.ada.id} [data-role="card-fields"] [data-field]|)
      |> Enum.map(&hd(Floki.attribute(&1, "data-field")))

    assert Enum.sort(front) == Enum.sort([fields["Website"].key, fields["Subscribed"].key])
  end
end
