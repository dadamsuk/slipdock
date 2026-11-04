defmodule SlipdockWeb.PageHeaderTest do
  @moduledoc """
  `page_header/1` and `page/1` (#1714): a page's one h1 with its subtitle
  and its own buttons on the title's baseline, and the three widths a page
  can be: narrow, standard and full. tools/e2e/page-header.sh measures the
  baseline in a browser.
  """
  use ExUnit.Case, async: true

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest

  alias SlipdockWeb.CoreComponents

  defp doc(html), do: LazyHTML.from_fragment(html)
  defp q(html, selector), do: html |> doc() |> LazyHTML.query(selector)
  defp classes(node), do: node |> LazyHTML.attribute("class") |> hd() |> String.split()

  describe "page_header/1" do
    test "draws the title as the one h1, with the token title class" do
      assigns = %{}
      html = rendered_to_string(~H|<CoreComponents.page_header title="Templates" />|)

      h1 = q(html, "header#page-header[data-role=page-header] h1")
      assert Enum.count(h1) == 1
      assert LazyHTML.text(h1) |> String.trim() == "Templates"
      assert "page-title" in classes(h1)
      assert Enum.count(q(html, "h1")) == 1
    end

    test "with no subtitle and no actions, draws neither" do
      assigns = %{}
      html = rendered_to_string(~H|<CoreComponents.page_header title="Tools" />|)

      assert Enum.empty?(q(html, "[data-role=page-subtitle]"))
      assert Enum.empty?(q(html, "[data-role=page-actions]"))
    end

    test "draws a plain subtitle under the title" do
      assigns = %{}

      html =
        rendered_to_string(
          ~H|<CoreComponents.page_header title="Groups" subtitle="People you share with." />|
        )

      sub = q(html, "h1 + p[data-role=page-subtitle]")
      assert LazyHTML.text(sub) |> String.trim() == "People you share with."
    end

    test "the meta slot is a subtitle with markup in it" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.page_header title="Boards">
          <:meta><a id="open-wiki" href="/wiki">Wiki</a> · <span id="board-count">2 boards</span></:meta>
        </CoreComponents.page_header>
        """)

      assert Enum.count(q(html, "h1 + p > a#open-wiki")) == 1
      assert Enum.count(q(html, "h1 + p > #board-count")) == 1
    end

    test "actions sit on the right, baseline-aligned with the title" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.page_header title="Templates">
          <:actions><button id="new-template">New template</button></:actions>
        </CoreComponents.page_header>
        """)

      header = q(html, "header")
      assert "items-baseline" in classes(header)
      assert "justify-between" in classes(header)

      actions = q(html, "header > [data-role=page-actions]")
      # The row's baseline is a line of label text first in it, not the
      # first button's icon.
      assert html =~
               ~r/data-role="page-actions"[^>]*>\s*<span[^>]*data-role="page-actions-baseline"/

      assert Enum.count(LazyHTML.query(actions, "button#new-template")) == 1
      # The actions come after the title block, so they sit on the right.
      assert html =~ ~r/<h1.*data-role="page-actions"/s
    end

    test "the leading slot goes inside the h1, in front of the title, not as a flex box" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.page_header title="Multiboard" title_id="multiboard-title">
          <:leading><span class="dot"></span></:leading>
        </CoreComponents.page_header>
        """)

      h1 = q(html, "h1#multiboard-title")
      assert Enum.count(LazyHTML.query(h1, ".dot")) == 1
      refute "flex" in classes(h1)
      assert LazyHTML.text(h1) |> String.trim() == "Multiboard"
    end

    test "the bottom margin is mb-6 unless the page passes its own" do
      assigns = %{}
      default = rendered_to_string(~H|<CoreComponents.page_header title="A" />|)
      own = rendered_to_string(~H|<CoreComponents.page_header id="h" title="A" class="mb-4" />|)
      none = rendered_to_string(~H|<CoreComponents.page_header id="h" title="A" class="" />|)

      assert "mb-6" in classes(q(default, "header"))
      assert "mb-4" in classes(q(own, "header"))
      refute "mb-6" in classes(q(own, "header"))
      refute Enum.any?(classes(q(none, "header")), &String.starts_with?(&1, "mb-"))
    end
  end

  describe "page/1" do
    for {width, class} <- [
          {"narrow", "max-w-2xl"},
          {"standard", "max-w-5xl"},
          {"full", "max-w-none"}
        ] do
      test "#{width} is #{class}, centred and padded" do
        assigns = %{width: unquote(width)}

        html =
          rendered_to_string(~H"""
          <CoreComponents.page id="p" width={@width} class="space-y-6">
            <p>body</p>
          </CoreComponents.page>
          """)

        page = q(html, "#p")
        assert LazyHTML.attribute(page, "data-page-width") == [unquote(width)]
        assert unquote(class) in classes(page)
        assert "mx-auto" in classes(page)
        assert "px-4" in classes(page)
        assert "space-y-6" in classes(page)
        assert Enum.count(LazyHTML.query(page, "p")) == 1
      end
    end

    test "standard is the default" do
      assigns = %{}
      html = rendered_to_string(~H|<CoreComponents.page id="p">x</CoreComponents.page>|)
      assert LazyHTML.attribute(q(html, "#p"), "data-page-width") == ["standard"]
    end

    test "padded={false} leaves the padding to its container" do
      assigns = %{}

      html =
        rendered_to_string(
          ~H|<CoreComponents.page id="p" width="narrow" padded={false}>x</CoreComponents.page>|
        )

      refute "px-4" in classes(q(html, "#p"))
      assert "max-w-2xl" in classes(q(html, "#p"))
    end

    test "a width that isn't one of the three raises" do
      assert_raise ArgumentError, ~r/unknown page width "wide"/, fn ->
        render_component(&CoreComponents.page/1, width: "wide", inner_block: [])
      end

      assert_raise ArgumentError, fn -> CoreComponents.page_width_class(nil) end
    end

    test "page_width_class/1 gives each width's class" do
      assert CoreComponents.page_width_class("narrow") == "max-w-2xl"
      assert CoreComponents.page_width_class("standard") == "max-w-5xl"
      assert CoreComponents.page_width_class("full") == "max-w-none"
    end
  end
end
