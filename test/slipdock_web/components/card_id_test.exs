defmodule SlipdockWeb.Components.CardIdTest do
  @moduledoc """
  The Display menu's *ID* facet (#1856): off until ticked, then the card's
  `#id` in the top-right corner of its front, in a lighter font than the
  title. It sits at the end of the tags row when tags are shown, else at the
  end of the title row; a compact card puts it after the title. A wiki page
  on the board has no card number, so it never gets one.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.Boards
  alias Slipdock.Swimlanes.Config

  setup %{user: user} do
    board = board_fixture(%{"name" => "Numbers", "code" => "cid1856"}, owner: user)
    [todo | _] = board.columns
    plain = card_fixture(todo, %{"title" => "Plain card"})
    tagged = card_fixture(todo, %{"title" => "Tagged card"})
    {:ok, _} = Boards.Cards.set_card_tags(tagged, [tag_fixture(board, "Design")])
    %{board: board, todo: todo, plain: plain, tagged: tagged, user: user}
  end

  defp id_mark(card), do: "#card-#{card.id} [data-role=card-id]"

  defp card_node(html, card) do
    html |> LazyHTML.from_document() |> LazyHTML.query("#card-#{card.id}")
  end

  defp classes(node, selector) do
    node
    |> LazyHTML.query(selector)
    |> LazyHTML.attribute("class")
    |> Enum.flat_map(&String.split/1)
  end

  # The data-roles of the parent of the card-id mark's siblings, in order.
  defp row_of_id(node) do
    node
    |> LazyHTML.query(":has(> [data-role=card-id]) > *")
    |> Enum.map(fn child ->
      case LazyHTML.attribute(child, "data-role") do
        [role] -> role
        [] -> LazyHTML.tag(child) |> hd()
      end
    end)
  end

  test "is a card view element, off by default", ctx do
    assert {"id", "ID"} in Config.facets()
    refute "id" in %Config{}.show
    refute "id" in %Config{}.show_compact

    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}")
    assert {"id", "ID"} in Slipdock.CardViews.Elements.front()
    refute has_element?(view, "[data-role=card-id]")

    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}?#{[density: "compact"]}")
    refute has_element?(view, "[data-role=card-id]")
  end

  test "ticked, every card shows its number, quieter than the title", ctx do
    {:ok, view, html} =
      Slipdock.CardViewHelpers.live_showing(
        ctx.conn,
        ctx.user,
        ctx.board,
        ~p"/boards/#{ctx.board}",
        ~w(tags id)
      )

    assert has_element?(view, id_mark(ctx.plain), "##{ctx.plain.id}")
    assert has_element?(view, id_mark(ctx.tagged), "##{ctx.tagged.id}")

    mark = classes(card_node(html, ctx.plain), "[data-role=card-id]")
    assert "text-base-content/40" in mark
    assert "text-xs" in mark
    assert "font-normal" in mark
    refute "font-medium" in mark
  end

  test "sits at the right of the top row: the tags when shown, else the title", ctx do
    {:ok, _view, html} =
      Slipdock.CardViewHelpers.live_showing(
        ctx.conn,
        ctx.user,
        ctx.board,
        ~p"/boards/#{ctx.board}",
        ~w(tags status id)
      )

    # With tags: the tags' row, after the tags, above the title.
    tagged = card_node(html, ctx.tagged)
    assert row_of_id(tagged) == ["div", "card-id"]
    assert "flex-1" in classes(tagged, ":has(> [data-role=card-id]) > div")

    # Without tags: the title row, straight after the title and before the
    # complete toggle (and the board's move menu) at its end.
    plain = card_node(html, ctx.plain)
    assert Enum.take(row_of_id(plain), 3) == ["card-title", "card-id", "complete-toggle"]

    # Tags turned off: the tagged card's number moves to its title row too.
    {:ok, _view, html} =
      Slipdock.CardViewHelpers.live_showing(
        ctx.conn,
        ctx.user,
        ctx.board,
        ~p"/boards/#{ctx.board}",
        ~w(id)
      )

    assert Enum.take(row_of_id(card_node(html, ctx.tagged)), 2) == ["card-title", "card-id"]
  end

  test "a compact card shows it after the title", ctx do
    {:ok, view, html} =
      Slipdock.CardViewHelpers.live_showing(
        ctx.conn,
        ctx.user,
        ctx.board,
        ~p"/boards/#{ctx.board}?#{[density: "compact"]}",
        ~w(id)
      )

    assert has_element?(view, id_mark(ctx.plain), "##{ctx.plain.id}")
    assert row_of_id(card_node(html, ctx.plain)) |> Enum.take(2) == ["card-title", "card-id"]

    # One card view for both sizes (#2031): hidden, it is off on compact cards too.
    Slipdock.CardViewHelpers.show_on_cards(ctx.user, ctx.board, ~w(tags))
    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}?#{[density: "compact"]}")
    refute has_element?(view, "[data-role=card-id]")
  end

  test "a wiki page placed on the board gets no number", ctx do
    page = page_fixture(ctx.board, %{"title" => "Runbook"}, user: ctx.user)
    {:ok, _} = Slipdock.Wiki.place(page, ctx.todo)

    {:ok, view, _} =
      Slipdock.CardViewHelpers.live_showing(
        ctx.conn,
        ctx.user,
        ctx.board,
        ~p"/boards/#{ctx.board}",
        ~w(id)
      )

    assert has_element?(view, "#page-#{page.id}")
    refute has_element?(view, "#page-#{page.id} [data-role=card-id]")
    assert has_element?(view, id_mark(ctx.plain))
  end
end
