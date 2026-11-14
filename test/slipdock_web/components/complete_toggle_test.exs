defmodule SlipdockWeb.CompleteToggleTest do
  @moduledoc """
  `complete_toggle/1` (#2886): the one round check every view draws to mark
  a card complete or open again. These hold what each copy used to get
  differently: the label, the icon, the muted colour and `disabled`.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias SlipdockWeb.SlipdockComponents

  defp toggle(assigns) do
    html = render_component(&SlipdockComponents.complete_toggle/1, assigns)
    [button] = html |> LazyHTML.from_fragment() |> LazyHTML.query("button") |> Enum.to_list()
    button
  end

  defp attr(node, name), do: node |> LazyHTML.attribute(name) |> List.first()
  defp classes(node), do: node |> attr("class") |> String.split()

  defp icon_classes(node),
    do: node |> LazyHTML.query("span") |> LazyHTML.attribute("class") |> hd() |> String.split()

  test "an open card's toggle says Mark complete, in its title and its aria-label" do
    button = toggle(card: %{id: 7, completed: false})

    assert attr(button, "type") == "button"
    assert attr(button, "data-role") == "complete-toggle"
    assert attr(button, "title") == "Mark complete"
    assert attr(button, "aria-label") == "Mark complete"
    assert attr(button, "phx-click") == "toggle_complete"
    assert attr(button, "phx-value-id") == "7"
    assert "hero-check-circle" in icon_classes(button)
    assert "text-base-content/30" in classes(button)
    refute "text-success" in classes(button)
  end

  test "a done card's toggle says Mark incomplete, with the solid check in success" do
    button = toggle(card: %{id: 7, completed: true})

    assert attr(button, "title") == "Mark incomplete"
    assert attr(button, "aria-label") == "Mark incomplete"
    assert "hero-check-circle-solid" in icon_classes(button)
    assert "text-success" in classes(button)
    refute "text-base-content/30" in classes(button)
  end

  test "it is enabled unless told otherwise, and disabled for a reader who can't write" do
    assert attr(toggle(card: %{id: 1, completed: false}), "disabled") == nil
    assert attr(toggle(card: %{id: 1, completed: false}, disabled: true), "disabled") != nil
  end

  test "the icon takes the size, the button the class and the passed-through attributes" do
    button =
      toggle(card: %{id: 1, completed: false}, size: "size-6", class: "mt-1.5", id: "t-1")

    assert "size-6" in icon_classes(button)
    assert "mt-1.5" in classes(button)
    assert attr(button, "id") == "t-1"
  end

  test "reveal hides an open card's toggle until hover or focus, never a done card's" do
    open = classes(toggle(card: %{id: 1, completed: false}, reveal: true))
    assert "opacity-0" in open
    assert "focus-visible:opacity-100" in open
    assert "no-hover:opacity-100" in open

    refute "opacity-0" in classes(toggle(card: %{id: 1, completed: true}, reveal: true))
    refute "opacity-0" in classes(toggle(card: %{id: 1, completed: false}))
  end
end
