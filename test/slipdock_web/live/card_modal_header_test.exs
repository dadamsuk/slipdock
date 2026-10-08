defmodule SlipdockWeb.CardModalHeaderTest do
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures
  alias Phoenix.LiveView.JS
  alias SlipdockWeb.SlipdockComponents

  # The buttons in the modal's top corner, in order, as {aria-label, class}.
  defp corner_buttons(html) do
    buttons = html |> LazyHTML.from_fragment() |> LazyHTML.query(".modal-actions button")

    Enum.zip(
      LazyHTML.attribute(buttons, "aria-label"),
      LazyHTML.attribute(buttons, "class")
    )
  end

  defp modal_html(actions) do
    render_component(&SlipdockComponents.modal/1,
      id: "m",
      on_close: JS.hide(),
      actions: actions,
      inner_block: [%{inner_block: fn _, _ -> "body" end}]
    )
  end

  test "a modal with no actions has just the close button in its corner" do
    assert [{"Close", class}] = corner_buttons(modal_html([]))
    # The row is placed, not the button, so nothing else can drift from it.
    refute class =~ "absolute"
  end

  test "actions sit in the same row as the close button, before it" do
    action = %{
      inner_block: fn _, _ ->
        Phoenix.HTML.raw(~s(<button class="btn" aria-label="Pin">p</button>))
      end
    }

    html = modal_html([action])

    assert [{"Pin", _}, {"Close", _}] = corner_buttons(html)
  end

  test "the card's favourite heart shares the close button's row and size", %{conn: conn} do
    board = board_fixture(%{"name" => "Hearts"})
    card = card_fixture(hd(board.columns), %{"title" => "Lined up"})

    {:ok, view, _} = live(conn, ~p"/boards/#{board}/cards/#{card}")
    html = view |> element("#card-modal") |> render()

    assert [{"Add to favourites: Lined up", heart}, {"Close", close}] = corner_buttons(html)
    assert heart =~ "btn-sm btn-circle"
    assert close =~ "btn-sm btn-circle"
    refute heart =~ "absolute"
    refute heart =~ "right-12"

    # The same size of icon, with the heart nudged down to line up by eye.
    [heart_icon, close_icon] =
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(".modal-actions button span")
      |> LazyHTML.attribute("class")

    assert heart_icon =~ "size-5"
    assert heart_icon =~ "translate-y-px"
    assert close_icon =~ "size-5"
    refute close_icon =~ "translate-y"
  end

  test "a favourited card keeps its heart in the row", %{conn: conn} do
    board = board_fixture(%{"name" => "Hearts"})
    card = card_fixture(hd(board.columns), %{"title" => "Loved"})

    {:ok, view, _} = live(conn, ~p"/boards/#{board}/cards/#{card}")
    view |> element(~s(.modal-actions button[phx-click="toggle_favourite"])) |> render_click()

    html = view |> element("#card-modal") |> render()
    assert [{"Remove from favourites: Loved", _}, {"Close", _}] = corner_buttons(html)
    assert html =~ "hero-heart-solid"
  end
end
