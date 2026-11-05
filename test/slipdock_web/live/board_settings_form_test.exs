defmodule SlipdockWeb.BoardSettingsFormTest do
  @moduledoc """
  The board settings form sized to what it holds (#1741): one column at
  most 40rem wide, short values in boxes their own size and in pairs, and
  every label stacked over its box in the same way. The widths and label
  positions themselves are measured in Chromium by
  `tools/e2e/board-settings.sh`; here the markup that makes them is checked,
  and that the form still saves through it.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.Boards
  alias SlipdockWeb.BoardLive.SettingsComponent

  setup %{user: user} do
    board = board_fixture(%{"name" => "Sized form"}, owner: user)
    %{board: board}
  end

  defp open(conn, board) do
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/settings")
    view
  end

  # The class list of the one element `selector` finds.
  defp classes(view, selector) do
    view
    |> render()
    |> LazyHTML.from_document()
    |> LazyHTML.query(selector)
    |> LazyHTML.attribute("class")
    |> case do
      [class] -> String.split(class)
      other -> flunk("expected one #{selector}, found #{length(other)}")
    end
  end

  test "every panel is the 40rem column", %{conn: conn, board: board} do
    view = open(conn, board)

    for {key, _, _} <- SettingsComponent.tabs() do
      assert "settings-column" in classes(view, "#settings-panel-#{key}"), key
    end

    # The rule itself, in the view's stylesheet.
    css = File.read!("assets/css/views/board-settings.css")
    assert css =~ ~r/\.settings-column \{ max-width: 40rem; \}/
    assert File.read!("assets/css/app.css") =~ ~s(@import "./views/board-settings.css";)
  end

  test "short values have boxes their own size, not the column's", %{conn: conn, board: board} do
    view = open(conn, board)

    sized = %{
      "#board_code" => "w-36",
      "#board_shortcut" => "w-16",
      "#board-hotkey" => "w-44",
      "#board-default-view" => "w-36",
      "#board_vote_budget" => "w-24",
      "#board_vote_max" => "w-24"
    }

    for {selector, width} <- sized do
      cls = classes(view, selector)
      assert width in cls, "#{selector}: #{inspect(cls)}"
      refute "w-full" in cls, selector
      assert "field" in cls, selector
    end

    # Code values are in the mono token, at the field's size.
    for selector <- ~w(#board_code #board_shortcut) do
      assert "field-mono" in classes(view, selector)
    end

    # The name and description still take the column.
    assert "w-full" in classes(view, "#board_name")
  end

  test "short fields sit in pairs", %{conn: conn, board: board} do
    view = open(conn, board)

    for pair <- [
          ~w(board_code board_shortcut),
          ~w(board-hotkey board-default-view),
          ~w(board_vote_budget board_vote_max)
        ] do
      [a, b] = pair

      assert has_element?(view, ".settings-pair:has(##{a}):has(##{b})"),
             "#{a} and #{b} should share a row"
    end
  end

  test "every label in General and Features is stacked over its box", %{conn: conn, board: board} do
    html = conn |> open(board) |> render() |> LazyHTML.from_document()

    boxes =
      LazyHTML.query(
        html,
        "#board-form :is(input.field, select.field, textarea.field):not([type=hidden])"
      )

    assert Enum.count(boxes) >= 8

    for box <- boxes do
      [id] = LazyHTML.attribute(box, "id")
      # `<.input>`'s label: the words in a `field-label` span before the box,
      # inside the one <label>, never a label of another shape beside it.
      label = LazyHTML.query(html, ~s|label[for="#{id}"]|)

      if Enum.count(label) == 1 do
        assert Enum.count(LazyHTML.query(label, "span.field-label")) == 1, id
      end
    end
  end

  test "a sub-board's pair has the code alone", %{conn: conn, board: board} do
    card = card_fixture(hd(board.columns), %{"title" => "Epic"})
    {:ok, t} = Boards.find_template(nil, "Simple")
    {:ok, sub} = sub_board(card, t)
    view = open(conn, sub)

    assert has_element?(view, ".settings-pair #board_code")
    refute has_element?(view, "#board_shortcut")
    refute has_element?(view, "#board-hotkey")
    refute has_element?(view, "#board_vote_budget")
  end

  test "the form saves through the pairs", %{conn: conn, board: board} do
    view = open(conn, board)

    view
    |> form("#board-form", %{
      "board" => %{
        "name" => "Sized form",
        "code" => "szf1741",
        "vote_budget" => "7",
        "vote_max" => "3"
      }
    })
    |> render_submit()

    board = Boards.get_board!(board.id)
    assert {board.code, board.vote_budget, board.vote_max} == {"szf1741", 7, 3}
  end

  test "a bad value in a small box is still refused, under the box", ctx do
    %{conn: conn, board: board} = ctx
    board_fixture(%{"name" => "Other", "code" => "szo1741"}, owner: ctx.user)
    view = open(conn, board)
    before = Boards.get_board!(board.id).code

    view
    |> form("#board-form", %{"board" => %{"code" => "szo1741"}})
    |> render_submit()

    assert has_element?(view, ".settings-pair", "is already used by another board")
    assert Boards.get_board!(board.id).code == before
  end
end
