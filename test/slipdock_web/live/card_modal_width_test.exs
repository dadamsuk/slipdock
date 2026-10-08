defmodule SlipdockWeb.CardModalWidthTest do
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures
  alias Phoenix.LiveView.JS
  alias SlipdockWeb.SlipdockComponents

  # The class list on the modal's panel: the element the width is set on.
  defp panel_classes(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(".kanban-modal-in")
    |> LazyHTML.attribute("class")
    |> hd()
    |> String.split()
  end

  defp modal_html(size) do
    render_component(&SlipdockComponents.modal/1,
      id: "m",
      on_close: JS.hide(),
      size: size,
      inner_block: [%{inner_block: fn _, _ -> "body" end}]
    )
  end

  test "a card opened full screen takes 90% of the width on a desktop", %{conn: conn} do
    board = board_fixture(%{"name" => "Wide"})
    card = card_fixture(hd(board.columns), %{"title" => "Roomy"})

    {:ok, view, _} = live(conn, ~p"/boards/#{board}/cards/#{card}")
    classes = view |> element("#card-modal") |> render() |> panel_classes()

    assert "sm:max-w-[90%]" in classes
    refute "max-w-4xl" in classes
    # Nothing narrows it on a phone, where it is already the whole screen.
    refute Enum.any?(classes, &String.starts_with?(&1, "max-w-"))
    assert "w-full" in classes
  end

  test "the other modal sizes keep their widths" do
    assert "max-w-md" in panel_classes(modal_html("sm"))
    assert "max-w-xl" in panel_classes(modal_html("md"))
    assert "max-w-4xl" in panel_classes(modal_html("lg"))
    assert "max-w-6xl" in panel_classes(modal_html("xl"))
    refute Enum.any?(panel_classes(modal_html("lg")), &(&1 == "sm:max-w-[90%]"))
  end
end
