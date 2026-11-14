defmodule SlipdockWeb.TableControlsTest do
  @moduledoc """
  `sort_header/1` and `priority_select/1` (#2892): the column heading that
  sorts and the priority select that saves, which the table and Prioritise
  both draw. The last test reads the two views' source, so neither is pasted
  into one again.
  """
  use ExUnit.Case, async: true

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest

  alias Slipdock.Swimlanes.Config
  alias SlipdockWeb.SlipdockComponents

  defp query(html, selector), do: html |> LazyHTML.from_fragment() |> LazyHTML.query(selector)
  defp attr(node, name), do: node |> LazyHTML.attribute(name) |> List.first()
  defp count(html, selector), do: html |> query(selector) |> Enum.count()

  defp header(attrs) do
    defaults = %{sort: "votes", label: "Votes", config: %Config{}}
    assigns = %{attrs: Map.merge(defaults, Map.new(attrs))}

    rendered_to_string(~H"""
    <SlipdockComponents.sort_header {@attrs} />
    """)
  end

  defp select(attrs \\ []) do
    defaults = %{id: "prio-7", card_id: "7", priority: "high"}
    assigns = %{attrs: Map.merge(defaults, Map.new(attrs))}

    rendered_to_string(~H"""
    <SlipdockComponents.priority_select {@attrs} />
    """)
  end

  describe "sort_header/1" do
    test "is a real button that pushes table_sort with its key" do
      html = header([])
      button = query(html, "button")

      assert Enum.count(button) == 1
      assert attr(button, "type") == "button"
      assert attr(button, "phx-click") == "table_sort"
      assert attr(button, "phx-value-sort") == "votes"
      assert attr(button, "title") == "Sort by Votes"
      assert LazyHTML.text(button) =~ "Votes"
      assert count(html, "[role=button]") == 0
    end

    test "a column that isn't the sorted one has no mark and no arrow" do
      html = header(config: %Config{sort: "priority", dir: "asc"})

      refute attr(query(html, "button"), "class") =~ "text-primary"
      assert count(html, "[class*=hero-arrow]") == 0
    end

    test "the sorted column is marked, with an up arrow ascending" do
      html = header(config: %Config{sort: "votes", dir: "asc"})

      assert attr(query(html, "button"), "class") =~ "text-primary"
      assert count(html, "button .hero-arrow-up") == 1
      assert count(html, ".hero-arrow-down") == 0
    end

    test "and a down arrow descending" do
      html = header(config: %Config{sort: "votes", dir: "desc"})

      assert count(html, "button.text-primary .hero-arrow-down") == 1
      assert count(html, ".hero-arrow-up") == 0
    end

    test "in a reader's disabled fieldset it is a focusable span that answers Enter" do
      html = header(in_fieldset: true, config: %Config{sort: "votes", dir: "desc"})
      span = query(html, "span[role=button]")

      # A <button> in a disabled fieldset is dead, and a reader may sort.
      assert count(html, "button") == 0
      assert Enum.count(span) == 1
      assert attr(span, "tabindex") == "0"
      assert attr(span, "phx-click") == "table_sort"
      assert attr(span, "phx-keydown") == "table_sort"
      assert attr(span, "phx-key") == "Enter"
      assert attr(span, "phx-value-sort") == "votes"
      assert attr(span, "title") == "Sort by Votes"
      assert attr(span, "class") =~ "text-primary"
      assert count(html, "span[role=button] .hero-arrow-down") == 1
    end

    test "the span has no mark or arrow off the sorted column" do
      html = header(in_fieldset: true, config: %Config{sort: "title", dir: "asc"})

      refute attr(query(html, "span[role=button]"), "class") =~ "text-primary"
      assert count(html, "[class*=hero-arrow]") == 0
    end
  end

  describe "priority_select/1" do
    test "is a table_update form sending the card and field=priority" do
      html = select()
      form = query(html, "form")

      assert attr(form, "id") == "prio-7"
      assert attr(form, "phx-change") == "table_update"
      assert attr(form, "phx-submit") == "table_update"
      assert attr(query(html, "form input[type=hidden][name=card_id]"), "value") == "7"
      assert attr(query(html, "form input[type=hidden][name=field]"), "value") == "priority"
      assert count(html, "form select[name=value]") == 1
    end

    test "the select is labelled Priority" do
      assert attr(query(select(), "select"), "aria-label") == "Priority"

      assert attr(query(select(label: "Card priority"), "select"), "aria-label") ==
               "Card priority"
    end

    test "offers every priority in order, the card's own selected" do
      html = select()
      values = html |> query("option") |> LazyHTML.attribute("value")

      assert values == Enum.map(SlipdockComponents.priority_options(), &elem(&1, 1))
      assert values == ~w(none low medium high critical)
      assert html |> query("option[selected]") |> LazyHTML.attribute("value") == ["high"]
      assert LazyHTML.text(query(html, "option[selected]")) =~ "High"
    end

    test "its inner block is drawn in the form, before the select" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <SlipdockComponents.priority_select id="prio-7" card_id="7" priority="high">
          <SlipdockComponents.priority_badge priority="high" />
        </SlipdockComponents.priority_select>
        """)

      assert count(html, "form#prio-7 [data-role=priority][data-priority=high]") == 1
      assert count(html, "form#prio-7 [data-role=priority] + select") == 1
      # With no block there is only the select.
      assert count(select(), "form [data-role=priority]") == 0
    end

    test "a page's id passes through as given" do
      html = select(id: "prio-priority-page-3", card_id: "page-3", priority: "none")

      assert attr(query(html, "form"), "id") == "prio-priority-page-3"
      assert attr(query(html, "input[name=card_id]"), "value") == "page-3"
      assert html |> query("option[selected]") |> LazyHTML.attribute("value") == ["none"]
    end
  end

  describe "the views" do
    @views ~w(table_components.ex prioritise_components.ex)

    test "neither draws a sort heading or a priority form of its own" do
      for file <- @views do
        source = File.read!(Path.join("lib/slipdock_web/components", file))

        refute source =~ ~s(phx-click="table_sort"), "#{file} pushes table_sort itself"
        refute source =~ ~s(value="priority"), "#{file} has its own priority form"
        refute source =~ "priority_options()", "#{file} lists the priorities itself"
        assert source =~ "<.sort_header", "#{file} doesn't call sort_header/1"
        assert source =~ "<.priority_select", "#{file} doesn't call priority_select/1"
      end
    end
  end
end
