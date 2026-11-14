defmodule SlipdockWeb.Components.SwitchFieldTest do
  @moduledoc """
  `<.switch_field>` (#2894): the settings switch board settings and the
  overseer draw. It posts its unchecked value when clear and its value when
  ticked, is ticked from the field's value unless told otherwise, and has
  one hint colour.
  """
  use ExUnit.Case, async: true

  import Phoenix.Component, only: [to_form: 2]
  import Phoenix.LiveViewTest

  alias SlipdockWeb.SlipdockComponents

  defp field(value), do: to_form(%{"on" => value}, as: :board)[:on]

  defp render_switch(attrs) do
    hint = Map.get(attrs, :hint)
    attrs = Map.delete(attrs, :hint)
    slot = if hint, do: [%{__slot__: :inner_block, inner_block: fn _, _ -> hint end}], else: []

    render_component(
      &SlipdockComponents.switch_field/1,
      Map.merge(%{id: "sw", label: "Simple board", inner_block: slot}, attrs)
    )
  end

  defp doc(html), do: LazyHTML.from_fragment(html)

  defp one(html, selector), do: html |> doc() |> LazyHTML.query(selector)

  defp attr(html, selector, name) do
    case html |> one(selector) |> LazyHTML.attribute(name) do
      [v | _] -> v
      [] -> nil
    end
  end

  test "a true value ticks the box; a false or empty one does not" do
    for v <- [true, "true"] do
      assert Enum.count(one(render_switch(%{field: field(v)}), "#sw[checked]")) == 1
    end

    for v <- [false, "false", nil, ""] do
      assert Enum.empty?(one(render_switch(%{field: field(v)}), "#sw[checked]"))
    end
  end

  test "the hidden input posts false under the field's name, the box posts true" do
    html = render_switch(%{field: field(false)})

    assert attr(html, "input[type=hidden]", "name") == "board[on]"
    assert attr(html, "input[type=hidden]", "value") == "false"
    assert attr(html, "#sw", "name") == "board[on]"
    assert attr(html, "#sw", "value") == "true"
    assert attr(html, "#sw", "type") == "checkbox"
  end

  test "value, unchecked and checked are what a non-boolean field needs" do
    html =
      render_switch(%{
        field: field("sprints"),
        value: "sprints",
        unchecked: "",
        checked: true
      })

    assert attr(html, "input[type=hidden]", "value") == ""
    assert attr(html, "#sw", "value") == "sprints"
    assert Enum.count(one(html, "#sw[checked]")) == 1

    # `checked` wins over the field's own value, both ways.
    refute render_switch(%{field: field(true), checked: false}) =~ "checked"
  end

  test "the label is the title, and the hint is under it in the muted colour" do
    html = render_switch(%{field: field(false), hint: "For a plain to-do list."})

    assert one(html, "label[data-role=switch-field] #sw") |> Enum.count() == 1
    assert one(html, "span.font-medium") |> LazyHTML.text() == "Simple board"

    hint = one(html, "span.text-xs")
    assert LazyHTML.text(hint) =~ "For a plain to-do list."
    assert attr(html, "span.text-xs", "class") =~ "text-base-content/60"
  end

  test "with no hint, only the title shows" do
    html = render_switch(%{field: field(false)})

    assert one(html, "span.font-medium") |> LazyHTML.text() == "Simple board"
    assert Enum.empty?(one(html, "span.text-xs"))
  end
end
