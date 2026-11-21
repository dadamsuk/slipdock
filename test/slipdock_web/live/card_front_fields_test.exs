defmodule SlipdockWeb.CardFrontFieldsTest do
  @moduledoc """
  Custom fields on the card front (#3609): a field switched to Show on cards
  in board settings shows its value as a chip, in field order, empty ones
  left out, at most two on a compact card; a card view hides them all as one
  element, Fields (`custom_fields`).
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{CardViews, Fields}

  setup %{conn: conn, user: user} do
    board = board_fixture(%{"name" => "Contacts"}, owner: user)
    [_backlog, todo | _] = board.columns

    {:ok, company} = Fields.create_field(board, %{"name" => "Company", "kind" => "text"})

    {:ok, stage} =
      Fields.create_field(board, %{
        "name" => "Stage",
        "kind" => "select",
        "options" => ["Lead", "Won"]
      })

    {:ok, met} = Fields.create_field(board, %{"name" => "Met", "kind" => "date"})
    {:ok, size} = Fields.create_field(board, %{"name" => "Size", "kind" => "number"})

    card = card_fixture(todo, %{"title" => "Ada"})
    {:ok, _} = Fields.set_value(card, company, "Analytical Engines")
    {:ok, _} = Fields.set_value(card, stage, "won")
    {:ok, _} = Fields.set_value(card, met, "2027-02-01")

    %{conn: conn, board: board, card: card, company: company, stage: stage, met: met, size: size}
  end

  defp show_on_cards(fields),
    do: for(f <- fields, do: {:ok, _} = Fields.update_field(f, %{"show_on_cards" => true}))

  defp chips(view, card) do
    view
    |> render()
    |> Floki.parse_document!()
    |> Floki.find(~s|#card-#{card.id} [data-role="card-fields"] [data-field]|)
    |> Enum.map(&{hd(Floki.attribute(&1, "data-field")), String.trim(Floki.text(&1))})
  end

  test "a field is off the card front until it is switched on", %{conn: conn} = ctx do
    {:ok, view, _} = live(conn, ~p"/boards/#{ctx.board}")
    assert chips(view, ctx.card) == []

    show_on_cards([ctx.company])
    {:ok, view, _} = live(conn, ~p"/boards/#{ctx.board}")
    assert chips(view, ctx.card) == [{"company", "Analytical Engines"}]
  end

  test "the fields show in field order, and one without a value is left out",
       %{conn: conn} = ctx do
    show_on_cards([ctx.size, ctx.met, ctx.stage, ctx.company])
    {:ok, view, _} = live(conn, ~p"/boards/#{ctx.board}")

    assert chips(view, ctx.card) == [
             {"company", "Analytical Engines"},
             {"stage", "Won"},
             {"met", "1 Feb 2027"}
           ]
  end

  test "a compact card shows the first two", %{conn: conn} = ctx do
    show_on_cards([ctx.company, ctx.stage, ctx.met])
    {:ok, view, _} = live(conn, ~p"/boards/#{ctx.board}?density=compact")
    assert chips(view, ctx.card) == [{"company", "Analytical Engines"}, {"stage", "Won"}]
  end

  test "a card view hides them all as one element", %{conn: conn, user: user} = ctx do
    show_on_cards([ctx.company, ctx.stage])
    {:ok, _} = CardViews.update_level(user, :global, %{"hide" => "custom_fields"})

    {:ok, view, _} = live(conn, ~p"/boards/#{ctx.board}")
    assert chips(view, ctx.card) == []
    assert has_element?(view, "#card-#{ctx.card.id}", "Ada")

    assert {"custom_fields", "Fields"} in Slipdock.CardViews.Elements.front()
  end

  test "board settings switch a field on and off", %{conn: conn} = ctx do
    {:ok, view, _} = live(conn, ~p"/boards/#{ctx.board}/settings")
    toggle = ~s|#field-#{ctx.company.id} input[phx-click="toggle_field_on_cards"]|
    refute view |> element(toggle) |> render() =~ "checked"

    view |> element(toggle) |> render_click()
    assert Fields.get_board_field(ctx.board.id, ctx.company.id).show_on_cards

    view |> element(toggle) |> render_click()
    refute Fields.get_board_field(ctx.board.id, ctx.company.id).show_on_cards
  end

  test "a reader sees the chips too", %{board: board} = ctx do
    show_on_cards([ctx.company])
    reader = user_fixture("reader@example.com")
    {:ok, _} = Slipdock.Access.grant(board, reader, "read", ctx.user)
    conn = log_in_user(build_conn(), reader)

    {:ok, view, _} = live(conn, ~p"/boards/#{board}")
    assert chips(view, ctx.card) == [{"company", "Analytical Engines"}]
  end
end
