defmodule SlipdockWeb.TabsTest do
  @moduledoc """
  `tabs/1` (#1740): every tab bar's one look and its ARIA. A tablist of
  tabs, the active one selected and the only one in the Tab order, as
  buttons that switch a panel or links that patch. assets/js/tabs.test.js
  covers the keys; tools/e2e/tabs.sh drives them in Chromium.
  """
  use ExUnit.Case, async: true

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest

  alias SlipdockWeb.CoreComponents

  defp q(html, selector), do: html |> LazyHTML.from_fragment() |> LazyHTML.query(selector)
  defp attr(node, name), do: node |> LazyHTML.attribute(name) |> List.first()
  defp classes(node), do: node |> attr("class") |> String.split()

  defp buttons(active) do
    assigns = %{active: active}

    rendered_to_string(~H"""
    <CoreComponents.tabs id="t" label="Settings">
      <:tab
        :for={key <- ~w(one two three)}
        id={"t-#{key}"}
        active={@active == key}
        icon="hero-star"
        controls={"p-#{key}"}
        phx-click="pick"
        phx-value-tab={key}
      >
        {String.capitalize(key)}
      </:tab>
    </CoreComponents.tabs>
    """)
  end

  test "draws a labelled tablist with the keyboard hook" do
    list = q(buttons("one"), "#t")

    assert attr(list, "role") == "tablist"
    assert attr(list, "aria-label") == "Settings"
    assert attr(list, "phx-hook") == "Tabs"
    assert attr(list, "aria-orientation") == "horizontal"
    assert Enum.count(q(buttons("one"), "#t > [role=tab]")) == 3
  end

  test "button tabs switch a panel: their event, value and panel go on the button" do
    tab = q(buttons("one"), "button#t-two")

    assert attr(tab, "type") == "button"
    assert attr(tab, "role") == "tab"
    assert attr(tab, "phx-click") == "pick"
    assert attr(tab, "phx-value-tab") == "two"
    assert attr(tab, "aria-controls") == "p-two"
    assert LazyHTML.text(tab) |> String.trim() == "Two"
    assert Enum.count(q(buttons("one"), "button#t-two .hero-star")) == 1
  end

  test "only the active tab is selected and in the Tab order" do
    html = buttons("two")

    for {key, selected, tabindex} <- [
          {"one", "false", "-1"},
          {"two", "true", "0"},
          {"three", "false", "-1"}
        ] do
      tab = q(html, "#t-#{key}")
      assert attr(tab, "aria-selected") == selected, key
      assert attr(tab, "tabindex") == tabindex, key
    end
  end

  test "with no tab active, the first is the one in the Tab order and none is selected" do
    html = buttons(nil)

    assert attr(q(html, "#t-one"), "tabindex") == "0"
    assert attr(q(html, "#t-two"), "tabindex") == "-1"
    assert Enum.empty?(q(html, ~s|[aria-selected="true"]|))
  end

  test "one look: the active tab is raised and the rest muted, whatever the bar" do
    html = buttons("one")

    assert ~w(bg-base-100 text-primary shadow-sm) -- classes(q(html, "#t-one")) == []
    assert "text-base-content/60" in classes(q(html, "#t-two"))
    refute "shadow-sm" in classes(q(html, "#t-two"))
    assert ~w(rounded-xl bg-base-200/60) -- classes(q(html, "#t")) == []
  end

  test "a tab's own class is ignored, so every tab looks the same" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <CoreComponents.tabs id="t" label="L">
        <:tab id="a" active class="btn btn-primary">A</:tab>
      </CoreComponents.tabs>
      """)

    refute "btn-primary" in classes(q(html, "#a"))
    assert "bg-base-100" in classes(q(html, "#a"))
  end

  test "stretch shares the width; otherwise the bar fits its tabs" do
    assigns = %{}

    stretched =
      rendered_to_string(~H"""
      <CoreComponents.tabs id="t" label="L" stretch class="mt-3">
        <:tab id="a" active>A</:tab>
      </CoreComponents.tabs>
      """)

    assert "flex-1" in classes(q(stretched, "#a"))
    refute "w-fit" in classes(q(stretched, "#t"))
    assert "mt-3" in classes(q(stretched, "#t"))

    fitted = buttons("one")
    refute "flex-1" in classes(q(fitted, "#t-one"))
    assert "w-fit" in classes(q(fitted, "#t"))
  end

  test "patch and navigate tabs are links, with no panel or button type" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <CoreComponents.tabs id="t" label="How to look">
        <:tab id="s" active patch="/search?q=x">Search</:tab>
        <:tab id="a" navigate="/ask">Ask</:tab>
      </CoreComponents.tabs>
      """)

    search = q(html, "a#s")
    assert attr(search, "href") == "/search?q=x"
    assert attr(search, "data-phx-link") == "patch"
    assert attr(search, "role") == "tab"
    assert attr(search, "aria-selected") == "true"
    assert attr(search, "tabindex") == "0"
    assert attr(search, "aria-controls") == nil
    assert attr(search, "type") == nil

    ask = q(html, "a#a")
    assert attr(ask, "data-phx-link") == "redirect"
    assert attr(ask, "aria-selected") == "false"
    assert attr(ask, "tabindex") == "-1"
    assert Enum.empty?(q(html, "button"))
  end

  test "a nil patch is a button, not a link to nowhere" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <CoreComponents.tabs id="t" label="L">
        <:tab id="a" patch={nil} active>A</:tab>
      </CoreComponents.tabs>
      """)

    assert Enum.count(q(html, "button#a")) == 1
    assert Enum.empty?(q(html, "a"))
  end

  test "a bar whose tabs are all filtered out is an empty tablist, not an error" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <CoreComponents.tabs id="t" label="L">
        <:tab :for={_ <- []}>never</:tab>
      </CoreComponents.tabs>
      """)

    assert Enum.count(q(html, "#t[role=tablist]")) == 1
    assert Enum.empty?(q(html, "[role=tab]"))
  end
end
