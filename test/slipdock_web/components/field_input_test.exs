defmodule SlipdockWeb.FieldInputTest do
  @moduledoc """
  `SlipdockWeb.ItemComponents.field_input/1`: the one custom-field editor the
  card and page panels and the Prioritise table share (#2878).
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Slipdock.Boards.{FieldDefinition, FieldValue}
  alias SlipdockWeb.ItemComponents

  defp field(kind, attrs \\ %{}),
    do: struct(%FieldDefinition{id: 7, key: "f", name: "F", kind: kind, config: %{}}, attrs)

  defp item(value) do
    stored =
      case value do
        nil -> []
        %Date{} = d -> [%FieldValue{field_id: 7, date: d}]
        n when is_number(n) -> [%FieldValue{field_id: 7, number: n}]
        t -> [%FieldValue{field_id: 7, text: t, option: t}]
      end

    %{field_values: stored}
  end

  defp render_input(field, value, attrs \\ []) do
    attrs =
      Keyword.merge(
        [field: field, item: item(value), can_write: true, id: "fi"],
        attrs
      )

    {:ok, doc} = Floki.parse_fragment(render_component(&ItemComponents.field_input/1, attrs))
    doc
  end

  defp bare, do: [look: :bare, event: "prio_field", params: [{"card_id", "page-3"}]]
  defp attr(doc, sel, name), do: doc |> Floki.find(sel) |> Floki.attribute(name)

  describe "a rating" do
    test "lights the stars up to the value, says n of max and offers Clear" do
      for look <- [:boxed, :bare] do
        doc = render_input(field("rating", %{config: %{"max" => 4}}), 3.0, look: look)
        stars = Floki.find(doc, "#fi button[value]:not([value=''])")

        assert length(stars) == 4
        assert attr(doc, "#fi button[value='2']", "title") == ["2 of 4"]
        assert Floki.find(doc, "#fi button[value='3'].text-amber-500") != []
        assert Floki.find(doc, "#fi button[value='4'].text-amber-500") == []
        assert attr(doc, "#fi button[value='']", "title") == ["Clear"]
      end
    end

    test "with no value, no star lights and there is nothing to clear" do
      doc = render_input(field("rating"), nil)
      assert Floki.find(doc, "#fi .text-amber-500") == []
      assert Floki.find(doc, "#fi button[value='']") == []
    end

    test "sends set_field by default, and the table's event with its card_id" do
      doc = render_input(field("rating"), 2.0)
      assert attr(doc, "#fi button[value='1']", "phx-click") == ["set_field"]
      assert attr(doc, "#fi button[value='1']", "phx-value-field_id") == ["7"]

      doc = render_input(field("rating"), 2.0, bare())
      assert attr(doc, "#fi button[value='1']", "phx-click") == ["prio_field"]
      assert attr(doc, "#fi button[value='1']", "phx-value-card_id") == ["page-3"]
      assert attr(doc, "#fi button[value='']", "phx-value-card_id") == ["page-3"]
    end
  end

  describe "a form field" do
    test "carries field_id and each param, and sends the event on change and submit" do
      doc = render_input(field("text"), "hi", bare())
      assert attr(doc, "form#fi", "phx-change") == ["prio_field"]
      assert attr(doc, "form#fi", "phx-submit") == ["prio_field"]
      assert attr(doc, "#fi input[name=field_id]", "value") == ["7"]
      assert attr(doc, "#fi input[name=card_id]", "value") == ["page-3"]

      doc = render_input(field("text"), "hi")
      assert attr(doc, "form#fi", "phx-change") == ["set_field"]
      assert Floki.find(doc, "#fi input[name=card_id]") == []
    end

    test "a select lists the options, the value chosen and — to clear it" do
      f =
        field("select", %{
          options: [%{"key" => "s", "label" => "Small"}, %{"key" => "l", "label" => "Large"}]
        })

      for look <- [:boxed, :bare] do
        doc = render_input(f, "l", look: look)

        assert doc
               |> Floki.find("#fi select option")
               |> Enum.map(&(&1 |> Floki.text() |> String.trim())) == [
                 "—",
                 "Small",
                 "Large"
               ]

        assert attr(doc, "#fi option[selected]", "value") == ["l"]
      end

      doc = render_input(f, nil)
      assert attr(doc, "#fi option[selected]", "value") == [""]
      assert Floki.find(render_input(f, nil, look: :bare), "#fi select.field-bare") != []
    end

    test "a number honours the field's step, min and max in both looks" do
      f = field("number", %{config: %{"step" => "0.5", "min" => 0, "max" => 10}})

      for look <- [:boxed, :bare] do
        doc = render_input(f, 2.5, look: look)
        assert attr(doc, "#fi input[type=number]", "step") == ["0.5"]
        assert attr(doc, "#fi input[type=number]", "min") == ["0"]
        assert attr(doc, "#fi input[type=number]", "max") == ["10"]
        assert attr(doc, "#fi input[type=number]", "value") == ["2.5"]
      end

      assert attr(render_input(field("number"), nil), "#fi input", "step") == ["any"]
    end

    test "a whole number shows without its .0 in both looks" do
      for look <- [:boxed, :bare] do
        doc = render_input(field("number"), 4000.0, look: look)
        assert attr(doc, "#fi input[type=number]", "value") == ["4000"]
      end
    end

    test "boxed, a number's unit is its placeholder and it saves as you type" do
      doc = render_input(field("number", %{config: %{"unit" => "people"}}), nil)
      assert attr(doc, "#fi input[type=number].field", "placeholder") == ["people"]
      assert attr(doc, "#fi input[type=number]", "phx-debounce") == ["600"]
      assert Floki.find(doc, "#fi [data-unit]") == []
    end

    test "bare, a number's unit is a suffix, tight for a sign, and it saves on blur" do
      doc = render_input(field("number", %{config: %{"unit" => "people"}}), 12.0, bare())

      assert doc |> Floki.find("#fi label.prio-number span[data-unit]") |> Floki.text() =~
               "people"

      assert Floki.find(doc, "#fi .prio-unit-tight") == []
      assert attr(doc, "#fi input[type=number]", "phx-debounce") == ["blur"]
      assert attr(doc, "#fi input[type=number]", "style") == ["--prio-chars: 2"]

      doc = render_input(field("number", %{config: %{"unit" => "%"}}), 80.0, bare())
      assert doc |> Floki.find("#fi span.prio-unit-tight") |> Floki.text() =~ "%"

      doc = render_input(field("number", %{config: %{"unit" => " "}}), 1.0, bare())
      assert Floki.find(doc, "#fi [data-unit]") == []
    end

    test "a date is the app's date field in both looks, never a bare date box" do
      for {look, wrapper} <- [boxed: ".date-field.field", bare: ".date-field.field-bare"] do
        doc = render_input(field("date"), ~D[2030-01-15], look: look)
        assert Floki.find(doc, "#fi-date#{wrapper}[phx-hook=DateField]") != []
        assert attr(doc, "#fi-date input[type=date]", "name") == ["value"]
        assert attr(doc, "#fi-date input[type=date]", "value") == ["2030-01-15"]
      end

      doc = render_input(field("date"), nil, look: :bare)
      assert doc |> Floki.find("#fi-date [data-role=date-text]") |> Floki.text() =~ "—"
    end

    test "text saves after 600ms boxed and on blur bare" do
      assert attr(render_input(field("text"), "x"), "#fi input[type=text]", "phx-debounce") ==
               ["600"]

      doc = render_input(field("text"), "x", bare())
      assert attr(doc, "#fi input[type=text].field-bare", "phx-debounce") == ["blur"]
      assert attr(doc, "#fi input[type=text]", "value") == ["x"]
    end
  end

  describe "read only" do
    test "without write access the value is shown as text, in either look" do
      f = field("number", %{config: %{"unit" => "%"}})

      doc = render_input(f, 80.0, can_write: false)
      assert doc |> Floki.find("p.text-xs") |> Floki.text() == "80%"
      assert Floki.find(doc, "input, button, form") == []

      doc = render_input(f, nil, can_write: false, look: :bare)
      assert doc |> Floki.find("span") |> Floki.text() == "—"
    end

    test "a formula is computed, so it is shown and never edited" do
      f = field("formula")
      doc = render_input(f, nil, item: %{computed: %{7 => 12.0}})
      assert Floki.find(doc, "input, button, form") == []
      assert Floki.text(doc) =~ "12"
    end
  end

  describe "fields_section/1" do
    defp render_section(fields, item, can_write) do
      html =
        render_component(&ItemComponents.fields_section/1,
          board: %{fields: fields},
          item: item,
          can_write: can_write
        )

      {:ok, doc} = Floki.parse_fragment(html)
      doc
    end

    test "a formula shows its value once, in the header, with no editor under it" do
      formula = field("formula", %{id: 7, name: "Score"})
      number = field("number", %{id: 8, key: "n", name: "Reach"})
      item = %{computed: %{7 => 12.0}, field_values: [%FieldValue{field_id: 8, number: 3.0}]}

      for can_write <- [true, false] do
        doc = render_section([formula, number], item, can_write)
        block = Floki.find(doc, "#card-field-7")

        assert block |> Floki.find("span[title=Computed]") |> Floki.text() |> String.trim() ==
                 "12"

        # Nothing but the header row: the value is not written a second time.
        assert Floki.find(block, "p, form, input, button") == []
        assert block |> Floki.text() |> String.split("12") |> length() == 2
      end

      # The guard is the formula's alone: a settable field keeps its editor.
      doc = render_section([formula, number], item, true)
      assert Floki.find(doc, "#card-field-8 span[title=Computed]") == []
      assert attr(doc, "#card-field-8 form#field-form-8", "phx-change") == ["set_field"]
      assert attr(doc, "#card-field-8 input[name=value]", "value") == ["3"]
    end

    test "a formula with no result shows a dash, once" do
      doc = render_section([field("formula")], %{computed: %{}, field_values: []}, true)
      block = Floki.find(doc, "#card-field-7")

      assert block |> Floki.find("span[title=Computed]") |> Floki.text() |> String.trim() == "—"
      assert Floki.find(block, "p, form, input, button") == []
      assert block |> Floki.text() |> String.split("—") |> length() == 2
    end
  end
end
