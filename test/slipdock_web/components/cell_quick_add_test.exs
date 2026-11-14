defmodule SlipdockWeb.CellQuickAddTest do
  @moduledoc """
  `cell_quick_add/1` (#2891): the quick-add form opened in a swimlane cell or
  a calendar day, which the two views used to paste four times over. These
  hold what each copy drew, and the one look they now share: **Add card**, a
  `size-3.5` X and `space-y-2`.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias SlipdockWeb.SwimlaneComponents

  defp render_form(assigns) do
    assigns = Map.merge(%{id: "cal-add-2030-01-16-3", event: "cal_quick_add"}, assigns)

    render_component(&SwimlaneComponents.cell_quick_add/1, assigns)
    |> LazyHTML.from_fragment()
  end

  defp attr(node, name), do: node |> LazyHTML.attribute(name) |> List.first()
  defp one(doc, selector), do: [_] = doc |> LazyHTML.query(selector) |> Enum.to_list()
  defp classes(node), do: node |> attr("class") |> String.split()

  test "the form submits its event with the cell in the hidden field" do
    doc = render_form(%{name: "date", value: "2030-01-16"})

    [form] = one(doc, "form")
    assert attr(form, "id") == "cal-add-2030-01-16-3"
    assert attr(form, "phx-submit") == "cal_quick_add"
    assert ["kanban-pop", "space-y-2"] == classes(form)

    [hidden] = one(doc, "input[type=hidden]")
    assert attr(hidden, "name") == "date"
    assert attr(hidden, "value") == "2030-01-16"
  end

  test "the title input takes focus, is required, and Escape cancels" do
    doc =
      render_form(%{name: "cell", value: "1:2", id: "swim-add-1-2-0", event: "swim_quick_add"})

    [form] = one(doc, "form")
    assert attr(form, "id") == "swim-add-1-2-0"
    assert attr(form, "phx-submit") == "swim_quick_add"

    [input] = one(doc, "input[type=text]")
    assert attr(input, "id") == "swim-add-1-2-0-input"
    assert attr(input, "name") == "title"
    assert attr(input, "placeholder") == "Card title, then Enter"
    assert attr(input, "phx-hook") == "Focus"
    assert attr(input, "phx-window-keydown") == "swim_cancel_add"
    assert attr(input, "phx-key") == "Escape"
    assert attr(input, "autocomplete") == "off"
    assert attr(input, "required") != nil
  end

  test "it reads Add card, and its X cancels with a name and the one icon size" do
    doc = render_form(%{name: "cell", value: "0:0"})

    [submit] = one(doc, "button[type=submit]")
    assert LazyHTML.text(submit) |> String.trim() == "Add card"

    [cancel] = one(doc, "button[type=button]")
    assert attr(cancel, "phx-click") == "swim_cancel_add"
    assert attr(cancel, "aria-label") == "Cancel"
    [icon] = one(cancel, "span")
    assert "hero-x-mark" in classes(icon)
    assert "size-3.5" in classes(icon)
  end

  test "a class adds its margin beside the shared look, and none adds nothing" do
    [form] = render_form(%{name: "date", value: "2030-01-16", class: "mt-1.5"}) |> one("form")
    assert classes(form) == ["kanban-pop", "space-y-2", "mt-1.5"]
  end
end
