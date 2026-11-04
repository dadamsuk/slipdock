defmodule SlipdockWeb.SearchIconTest do
  @moduledoc """
  Every toolbar search box draws its magnifying glass (#1695). daisyUI's
  `.input` is positioned, so a glass placed before it with no z-index was
  painted over: `search_input/1` stacks it above the field. The boxes also
  take the `field` look rather than `rounded-full`. Whether the glass is
  really on top is a browser's question, and `tools/e2e/search-icon.sh`
  asks it; these tests pin down the markup that makes it so.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Phoenix.Component, only: [sigil_H: 2]
  import Slipdock.Fixtures

  alias SlipdockWeb.CoreComponents

  setup %{user: user} do
    board = board_fixture(%{"name" => "Glassy", "code" => "glassy1695"}, owner: user)
    card_fixture(hd(board.columns), %{"title" => "Find me"})
    %{board: board}
  end

  # The box's glass and input, in `container`: the glass comes first, is
  # stacked above the input, and the input has the field look.
  defp assert_glass(view, container) do
    assert has_element?(view, "#{container} .search-input-icon.hero-magnifying-glass.z-10")
    assert has_element?(view, "#{container} input.input.field.field-icon")
    refute has_element?(view, "#{container} input.rounded-full")
    refute has_element?(view, "#{container} input.input-sm")

    html = view |> element(container) |> render()
    {glass, _} = :binary.match(html, "search-input-icon")
    {input, _} = :binary.match(html, "<input")
    assert glass < input, "the glass is drawn before the input"
  end

  describe "search_input/1" do
    test "draws the glass above a field, with the given attributes on the input" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.search_input
          value="refunds"
          placeholder="Find…"
          phx-debounce="200"
          class="w-40"
        />
        """)

      assert html =~ ~r/class="[^"]*\bsearch-input-icon\b[^"]*\bz-10\b/
      # Hit-testable, so `elementFromPoint` finds it, and inside the label
      # with the input, so a click on it focuses the box.
      refute html =~ "pointer-events-none"

      assert html =~
               ~r/<label[^>]*class="contents"[^>]*>\s*<span[^>]*search-input-icon.*<input.*<\/label>/s

      assert html =~ ~s(type="search")
      assert html =~ ~s(name="q")
      assert html =~ ~s(value="refunds")
      assert html =~ ~s(placeholder="Find…")
      assert html =~ ~s(phx-debounce="200")
      assert html =~ ~s(class="input field field-icon w-40")
      refute html =~ "rounded-full"
      refute html =~ "field-trail"
    end

    test "leaves room on the right for one or two buttons" do
      assigns = %{}

      one = rendered_to_string(~H|<CoreComponents.search_input trail={1} />|)
      two = rendered_to_string(~H|<CoreComponents.search_input trail={2} />|)

      assert one =~ ~s(class="input field field-icon field-trail")
      assert two =~ ~s(class="input field field-icon field-trail-2")
    end

    test "takes another type and name, and no value" do
      assigns = %{}

      html =
        rendered_to_string(~H|<CoreComponents.search_input type="text" name="query" />|)

      assert html =~ ~s(type="text")
      assert html =~ ~s(name="query")
      refute html =~ "value="
    end

    test "the stylesheet gives the trail classes their room" do
      css = File.read!("assets/css/app.css")
      assert css =~ "input.field-icon { padding-left: 2rem; }"
      assert css =~ "input.field-trail { padding-right: 2rem; }"
      assert css =~ "input.field-trail-2 { padding-right: 3.75rem; }"
    end
  end

  describe "the boxes" do
    test "the board's Search cards…", %{conn: conn, board: board} do
      {:ok, view, _} = live(conn, ~p"/boards/#{board}")
      assert_glass(view, "#board-search")
      assert has_element?(view, "#board-search input.field-trail[placeholder='Search cards…']")
    end

    test "the views toolbar, on swimlanes and table", %{conn: conn, board: board} do
      for mode <- ["swimlanes", "table"] do
        {:ok, view, _} = live(conn, "/boards/#{board.id}/#{mode}")
        assert_glass(view, "#swim-search")
        assert has_element?(view, "#swim-search input.field-trail")
      end
    end

    test "the wiki tree's search", %{conn: conn, board: board} do
      {:ok, view, _} = live(conn, ~p"/boards/#{board}/wiki")
      assert_glass(view, "#wiki-search")
    end

    test "the wiki page's Attach a card…", %{conn: conn, board: board} do
      page = page_fixture(board, %{"title" => "Glass spec", "body" => "Text."})
      {:ok, view, _} = live(conn, ~p"/boards/#{board}/wiki/#{page.slug}")
      assert_glass(view, "#page-card-search")
      assert has_element?(view, "#page-card-search input[placeholder='Attach a card…']")
    end

    test "the Search and Ask box, with room for its star and X", %{conn: conn} do
      for path <- [~p"/search", ~p"/ask"] do
        {:ok, view, _} = live(conn, path)
        assert_glass(view, "#deep-search")
        assert has_element?(view, "#deep-search input.field-trail-2[type=text][name=q]")
        refute has_element?(view, "#deep-search input.rounded-2xl")
      end
    end

    test "a query keeps a phone's box open, glass and all", %{conn: conn, board: board} do
      {:ok, view, _} = live(conn, ~p"/boards/#{board}")
      view |> form("#board-search", %{"q" => "Find"}) |> render_change()

      assert has_element?(view, "#board-search-box.search-open #board-search .search-input-icon")
      refute has_element?(view, "#board-search-box-toggle")
    end
  end
end
