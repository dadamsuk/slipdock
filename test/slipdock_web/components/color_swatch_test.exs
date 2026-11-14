defmodule SlipdockWeb.ColorSwatchTest do
  @moduledoc """
  `<.color_swatch>` (#2888): the one swatch every colour picker draws, the
  tags panel's included, and its "none" variant.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Slipdock.Palette
  alias SlipdockWeb.SlipdockComponents

  defp swatch(assigns) do
    html = render_component(&SlipdockComponents.color_swatch/1, assigns)
    [button] = html |> LazyHTML.from_fragment() |> LazyHTML.query("button") |> Enum.to_list()
    button
  end

  defp attr(node, name), do: node |> LazyHTML.attribute(name) |> List.first()

  defp classes(node), do: node |> attr("class") |> String.split()

  describe "a colour" do
    test "is named by title and aria-label, and filled with its dot" do
      node = swatch(%{color: "rose"})

      assert attr(node, "type") == "button"
      assert attr(node, "title") == Palette.label("rose")
      assert attr(node, "aria-label") == Palette.label("rose")
      assert attr(node, "data-swatch") == "rose"
      assert "size-6" in classes(node)
      for class <- String.split(Palette.dot("rose")), do: assert(class in classes(node))
      assert LazyHTML.query(node, ".hero-no-symbol") |> Enum.empty?()
    end

    test "every palette colour has a non-empty accessible name" do
      for name <- Palette.names() do
        label = attr(swatch(%{color: name}), "aria-label")
        assert is_binary(label) and label != ""
      end
    end

    test "says whether it is the chosen one" do
      off = swatch(%{color: "sky"})
      on = swatch(%{color: "sky", selected: true})

      assert attr(off, "aria-pressed") == "false"
      refute "ring-2" in classes(off)
      assert attr(on, "aria-pressed") == "true"
      assert "ring-2" in classes(on)
    end

    test "a label given replaces the colour's name" do
      node = swatch(%{color: "sky", label: "Sky cover"})

      assert attr(node, "title") == "Sky cover"
      assert attr(node, "aria-label") == "Sky cover"
    end

    test "passes its size, id, event and popover attributes through" do
      node =
        swatch(%{
          :color => "sky",
          :class => "size-5",
          :id => "pal-sky",
          :popovertarget => "pal",
          :popovertargetaction => "hide",
          :"phx-click" => "set_tag_color",
          :"phx-value-color" => "sky",
          :"phx-value-id" => 7
        })

      assert "size-5" in classes(node)
      refute "size-6" in classes(node)
      assert attr(node, "id") == "pal-sky"
      assert attr(node, "popovertarget") == "pal"
      assert attr(node, "popovertargetaction") == "hide"
      assert attr(node, "phx-click") == "set_tag_color"
      assert attr(node, "phx-value-color") == "sky"
      assert attr(node, "phx-value-id") == "7"
    end
  end

  describe "none (color nil)" do
    test "is a struck-through circle called None, with no colour of its own" do
      node = swatch(%{color: nil})

      assert attr(node, "title") == "None"
      assert attr(node, "aria-label") == "None"
      assert attr(node, "data-swatch") == "none"
      assert attr(node, "aria-pressed") == "false"
      assert LazyHTML.query(node, ".hero-no-symbol") |> Enum.count() == 1
      assert "ring-1" in classes(node)
      refute "ring-2" in classes(node)
      refute Enum.any?(classes(node), &String.starts_with?(&1, "bg-"))
    end

    test "takes the picker's own words, and the ring when nothing is chosen" do
      node =
        swatch(%{
          :color => nil,
          :label => "No cover",
          :selected => true,
          :"phx-click" => "set_cover"
        })

      assert attr(node, "title") == "No cover"
      assert attr(node, "aria-label") == "No cover"
      assert attr(node, "aria-pressed") == "true"
      assert "ring-2" in classes(node)
      assert attr(node, "phx-click") == "set_cover"
    end

    test "takes the size its picker gives, as the borders' None does" do
      default = swatch(%{color: nil})
      node = swatch(%{color: nil, class: "size-5"})

      assert "size-6" in classes(default)
      assert "size-5" in classes(node)
      refute "size-6" in classes(node)
    end
  end

  describe "where it is used" do
    # The pickers that had their own copy of the button: each must now call
    # the component, so a hand-built swatch can't come back unnoticed.
    for file <- ~w(
          lib/slipdock_web/live/board_live/tags_component.ex
          lib/slipdock_web/live/board_live/column_component.ex
          lib/slipdock_web/live/board_live/card_panel.ex
          lib/slipdock_web/live/board_live/card_panel/properties.ex
        ) do
      test "#{file} draws its swatches with the component" do
        source = File.read!(unquote(file))

        assert source =~ "<.color_swatch"
        refute source =~ ~s(hover:scale-110), "a hand-built colour swatch"
        refute source =~ ~s(hero-no-symbol" class="size-3), "a hand-built None swatch"
      end
    end
  end
end
