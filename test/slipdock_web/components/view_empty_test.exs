defmodule SlipdockWeb.ViewEmptyTest do
  @moduledoc """
  `view_empty/1` (#2885): what a board view shows with nothing to draw. One
  sentence saying why (the filters hide every card, the board has none, or
  the view's own line), a Clear filters button while a filter is set, and
  whatever the view puts after it. Its last test reads the view modules'
  source, so the block is not pasted into one again.
  """
  use ExUnit.Case, async: true

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest

  alias Slipdock.Swimlanes.Config
  alias SlipdockWeb.SlipdockComponents

  @filtered "No cards match the current filters."
  @none "This board has no cards yet."

  defp root(html), do: html |> LazyHTML.from_fragment() |> LazyHTML.query("[data-view-empty]")
  defp class(node), do: node |> LazyHTML.attribute("class") |> hd()
  defp button(html), do: html |> LazyHTML.from_fragment() |> LazyHTML.query("button")

  defp render_empty(attrs) do
    assigns = %{attrs: Map.new(attrs) |> Map.put_new(:config, %Config{})}

    rendered_to_string(~H"""
    <SlipdockComponents.view_empty {@attrs}>
      <:line>Nothing on these axes.</:line>
    </SlipdockComponents.view_empty>
    """)
  end

  describe "the sentence" do
    test "the filters hide every card: nothing shown, some hidden" do
      html = render_empty(hidden: 3)
      assert html =~ @filtered
      refute html =~ @none
      refute html =~ "Nothing on these axes."
    end

    test "one hidden card is enough" do
      assert render_empty(shown: 0, hidden: 1) =~ @filtered
    end

    test "the board has no cards: nothing shown, nothing hidden" do
      html = render_empty(hidden: 0)
      assert html =~ @none
      refute html =~ @filtered
      refute html =~ "Nothing on these axes."
    end

    test "cards are shown but the view draws none: the view's own line, whatever is hidden" do
      for hidden <- [0, 4] do
        html = render_empty(shown: 2, hidden: hidden)
        assert html =~ "<p>Nothing on these axes.</p>"
        refute html =~ @filtered
        refute html =~ @none
      end
    end

    test "cards shown and no line given: no sentence, and no empty paragraph" do
      assigns = %{config: %Config{}}

      html =
        rendered_to_string(~H"""
        <SlipdockComponents.view_empty shown={1} hidden={0} config={@config} />
        """)

      refute html =~ "<p"
      assert Enum.count(root(html)) == 1
    end
  end

  describe "the Clear filters button" do
    test "is there while a filter is set, and pushes swim_clear_filters" do
      html = render_empty(hidden: 3, config: %Config{q: "parser"})
      button = button(html)

      assert Enum.count(button) == 1
      assert LazyHTML.text(button) =~ "Clear filters"
      assert LazyHTML.attribute(button, "phx-click") == ["swim_clear_filters"]
      assert LazyHTML.attribute(button, "type") == ["button"]
      assert LazyHTML.attribute(button, "class") == ["btn btn-sm"]
    end

    test "is there with a filter set even when the view's own line is shown" do
      html = render_empty(shown: 2, hidden: 0, config: %Config{q: "parser"})
      assert Enum.count(button(html)) == 1
    end

    test "is not there with no filter set" do
      assert Enum.count(button(render_empty(hidden: 0))) == 0
      assert Enum.count(button(render_empty(hidden: 3))) == 0
    end
  end

  describe "the variants" do
    test "fill is the default: the view's whole height, with the icon" do
      html = render_empty(hidden: 0, icon: "hero-table-cells")
      root = root(html)

      assert LazyHTML.attribute(root, "data-view-empty") == ["fill"]

      assert class(root) ==
               "flex h-full flex-col items-center justify-center gap-2 p-8 text-center text-base-content/60"

      assert html =~ "hero-table-cells"
      assert html =~ "size-10 opacity-40"
    end

    test "block is a fixed height" do
      root = root(render_empty(hidden: 0, variant: "block"))
      assert LazyHTML.attribute(root, "data-view-empty") == ["block"]
      assert class(root) =~ "h-64"
      refute class(root) =~ "h-full"
    end

    test "strip is a bordered line, smaller, with no icon unless one is given" do
      html = render_empty(hidden: 0, variant: "strip")
      root = root(html)

      assert class(root) =~ "border-t border-base-300"
      assert class(root) =~ "text-sm"
      refute class(root) =~ "h-full"
      refute html =~ "hero-"
      assert html =~ "<p>#{@none}</p>"
    end

    test "inline is a note: the sentence with a small button beside it, no paragraph or icon" do
      html =
        render_empty(hidden: 2, variant: "inline", icon: "hero-scale", config: %Config{q: "x"})

      root = root(html)

      assert class(root) == "rounded-lg bg-base-200/60 p-3 text-sm text-base-content/60"
      assert html =~ @filtered
      refute html =~ "<p"
      refute html =~ "hero-scale"
      assert LazyHTML.attribute(button(html), "class") == ["btn btn-xs ml-2"]
    end

    test "inline shows the view's own line when cards are shown" do
      html = render_empty(shown: 1, hidden: 0, variant: "inline")
      assert html =~ "Nothing on these axes."
      refute html =~ @none
    end

    test "id and class reach the root" do
      root = root(render_empty(hidden: 0, id: "table-empty", class: "mt-4"))
      assert LazyHTML.attribute(root, "id") == ["table-empty"]
      assert class(root) =~ ~r/text-base-content\/60 mt-4$/
    end

    test "a variant that isn't one raises" do
      assert_raise KeyError, fn -> render_empty(hidden: 0, variant: "huge") end
    end
  end

  test "the inner block follows the button" do
    assigns = %{config: %Config{q: "parser"}}

    html =
      rendered_to_string(~H"""
      <SlipdockComponents.view_empty hidden={1} config={@config}>
        <form id="table-add"></form>
      </SlipdockComponents.view_empty>
      """)

    assert [_before, after_button] = String.split(html, "</button>")
    assert after_button =~ ~s(id="table-add")
    assert Enum.count(LazyHTML.query(root(html), "form#table-add")) == 1
  end

  describe "the views" do
    @web Path.expand("../../../lib/slipdock_web", __DIR__)
    @home Path.join(@web, "components/slipdock_components/chrome.ex")

    test "the two sentences are written once, in the component" do
      sources = Path.wildcard(Path.join(@web, "**/*.{ex,heex}"))
      assert @home in sources

      for sentence <- [@filtered, @none] do
        assert [@home] == Enum.filter(sources, &(File.read!(&1) =~ sentence)),
               "#{inspect(sentence)} belongs to view_empty/1 alone: call <.view_empty> instead of pasting it"

        assert [_once] = Regex.scan(~r/#{Regex.escape(sentence)}/, File.read!(@home))
      end
    end

    test "every view that had the block calls the component" do
      calls =
        for view <- ~w(table timeline swimlane outline prioritise calendar narrative),
            into: %{} do
          source = File.read!(Path.join(@web, "components/#{view}_components.ex"))
          {view, length(Regex.scan(~r/<\.view_empty\b/, source))}
        end

      assert calls == %{
               "table" => 2,
               "timeline" => 2,
               "swimlane" => 2,
               "outline" => 1,
               "prioritise" => 1,
               "calendar" => 1,
               "narrative" => 1
             }
    end
  end
end
