defmodule SlipdockWeb.WikiReadingColumnLiveTest do
  @moduledoc """
  The wiki page reads in one column with one row of actions (#1743).

  What a browser makes of the measure (every block's right edge in the same
  place, about 68ch) is checked by `tools/e2e/wiki-measure.sh`; this holds the
  markup and the rule it relies on.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.Access

  @css File.read!(Path.expand("../../../assets/css/app.css", __DIR__))

  setup %{user: user} do
    board = board_fixture(%{"name" => "Reading RC"}, owner: user)
    page = page_fixture(board, %{"title" => "Measured", "body" => "## A heading\n\nText."})
    %{board: board, page: page}
  end

  # Every button or link drawn as a button in the row, by its classes.
  defp row_buttons(view) do
    view
    |> element("#page-actions")
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#page-actions > .btn, #page-actions > .dropdown > .btn")
    |> Enum.map(fn node ->
      {LazyHTML.attribute(node, "class") |> List.first() |> String.split(),
       LazyHTML.text(node) |> String.trim()}
    end)
  end

  defp emphasised(view) do
    for {classes, text} <- row_buttons(view), "btn-ghost" not in classes, do: {classes, text}
  end

  describe "one measure" do
    test "the reading column has the reading measure, and its rule is in app.css",
         %{conn: conn, board: board, page: page} do
      {:ok, view, _} = live(conn, ~p"/boards/#{board}/wiki/#{page.slug}")
      assert has_element?(view, "#wiki-column.wiki-reading[data-measure=reading]")
      refute has_element?(view, "#wiki-column.max-w-4xl")

      # The measure is set on the column, so the text, its headings' rules
      # and the footer inside it all end at the same edge.
      assert has_element?(view, "#wiki-column #wiki-body h2")
      assert has_element?(view, "#wiki-column #page-cards")
      assert @css =~ ~r/#wiki-column\.wiki-reading \{ max-width: calc\(68ch \+ 4rem\); \}/
      # A cell is never narrower than a short word; many columns scroll.
      assert @css =~ ".wiki-prose :is(th, td) { min-width: 6rem; }"
      # The full-width option still overrides it.
      assert @css =~ ~s(html[data-wiki-width="full"] #wiki-column { max-width: none; })
    end

    test "history and a folder read on the same measure; writing takes the width",
         %{conn: conn, board: board, page: page} do
      {:ok, history, _} = live(conn, ~p"/boards/#{board}/wiki/#{page.slug}/history")
      assert has_element?(history, "#wiki-column.wiki-reading")

      {:ok, index, _} = live(conn, ~p"/boards/#{board}/wiki")
      assert has_element?(index, "#wiki-column.wiki-reading")

      {:ok, editor, _} = live(conn, ~p"/boards/#{board}/wiki/#{page.slug}/edit")
      assert has_element?(editor, "#wiki-column.max-w-none[data-measure=wide]")
      refute has_element?(editor, "#wiki-column.wiki-reading")
    end
  end

  describe "the action row" do
    test "every action is a ghost button but Edit, the one secondary",
         %{conn: conn, board: board, page: page} do
      {:ok, view, _} = live(conn, ~p"/boards/#{board}/wiki/#{page.slug}")

      buttons = row_buttons(view)
      assert length(buttons) >= 5
      assert [{classes, "Edit"}] = emphasised(view)
      assert "btn-secondary" in classes
      refute has_element?(view, "#page-actions .chip")
      refute has_element?(view, "#page-actions .btn-primary, #page-actions .btn-soft")
    end

    test "the page code is a ghost button whose tooltip shows it and click copies it",
         %{conn: conn, board: board, page: page} do
      {:ok, view, _} = live(conn, ~p"/boards/#{board}/wiki/#{page.slug}")

      button = "#page-actions #page-code-copy.btn-ghost.tooltip"

      assert has_element?(
               view,
               "#{button}[phx-hook=CopyText][data-target='page-code-#{page.id}']"
             )

      assert has_element?(view, "#{button}[data-tip='#{page.code} · click to copy']")
      assert has_element?(view, "#{button}[aria-label='Copy the page code, #{page.code}']")
      # The hook copies the text of the span it names, inside the button.
      assert has_element?(view, "#{button} span#page-code-#{page.id}.sr-only", page.code)
    end

    test "the AI tools button stays a ghost button when pressed",
         %{conn: conn, board: board, page: page} do
      {:ok, view, _} = live(conn, ~p"/boards/#{board}/wiki/#{page.slug}")

      assert has_element?(view, "#page-tools-toggle.btn-ghost[aria-pressed=false]")
      view |> element("#page-tools-toggle") |> render_click()
      assert has_element?(view, "#page-tools-toggle.btn-ghost.btn-active[aria-pressed=true]")
      assert [{_, "Edit"}] = emphasised(view)
    end

    test "on a drawing, editing the drawing is the emphasised action", %{
      conn: conn,
      board: board,
      user: user
    } do
      drawing =
        page_fixture(
          board,
          %{
            "title" => "Plan",
            "file_name" => "Plan.excalidraw",
            "front_matter" => "---\nexcalidraw-plugin: parsed\n---\n",
            "body" => "a drawing"
          },
          user: user
        )

      {:ok, view, _} = live(conn, ~p"/boards/#{board}/wiki/#{drawing.slug}")
      assert [{classes, "Edit drawing"}] = emphasised(view)
      assert "btn-secondary" in classes
      assert has_element?(view, "#edit-page.btn-ghost", "Edit Markdown")
    end

    test "a reader, who cannot edit, gets the row all in ghost buttons",
         %{board: board, page: page, user: user} do
      reader = user_fixture("rc.reader@example.com")
      {:ok, _} = Access.grant(board, reader, "read", user)

      {:ok, view, _} = live(conn_as(reader), ~p"/boards/#{board}/wiki/#{page.slug}")
      refute has_element?(view, "#edit-page")
      assert has_element?(view, "#page-code-copy")
      assert emphasised(view) == []
    end
  end

  test "Attach a card… is a field, not a rounded box",
       %{conn: conn, board: board, page: page} do
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/wiki/#{page.slug}")
    assert has_element?(view, "#page-card-search input.field[placeholder='Attach a card…']")
    refute has_element?(view, "#page-card-search input.rounded-full")
  end
end
