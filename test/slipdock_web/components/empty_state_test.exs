defmodule SlipdockWeb.EmptyStateTest do
  @moduledoc """
  `empty_state/1` (#1715): what a page or a section shows with nothing in
  it. An icon in a tinted square, a heading, one line of copy and an
  optional action; full for a page, compact for a section in a card.
  """
  use ExUnit.Case, async: true

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest

  alias SlipdockWeb.CoreComponents

  defp root(html), do: html |> LazyHTML.from_fragment() |> LazyHTML.query("[data-empty-state]")
  defp class(node), do: node |> LazyHTML.attribute("class") |> hd()

  describe "the full variant" do
    setup do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.empty_state id="things-empty" icon="hero-heart" title="Nothing here yet">
          Press the heart on a card.
        </CoreComponents.empty_state>
        """)

      %{html: html, root: root(html)}
    end

    test "is a surface of its own with a tinted square, an h2 and its copy", %{
      html: html,
      root: root
    } do
      assert Enum.count(root) == 1
      assert LazyHTML.attribute(root, "data-empty-state") == ["full"]
      assert LazyHTML.attribute(root, "id") == ["things-empty"]
      assert class(root) =~ "rounded-2xl"
      assert class(root) =~ "ring-1"
      assert class(root) =~ "text-center"

      square = LazyHTML.query(root, "span:has(> .hero-heart)")
      assert Enum.count(square) == 1
      assert class(square) =~ "size-12"
      assert class(square) =~ "bg-primary/10"
      assert class(square) =~ "text-primary"

      assert root |> LazyHTML.query("h2.section-title") |> LazyHTML.text() == "Nothing here yet"
      assert root |> LazyHTML.query("h3") |> Enum.count() == 0
      assert root |> LazyHTML.query("p") |> LazyHTML.text() =~ "Press the heart on a card."
      refute html =~ "empty-state-action"
    end
  end

  describe "the compact variant" do
    test "is dashed and smaller, with an h3, for a section inside a card" do
      assigns = %{}

      root =
        root(
          rendered_to_string(~H"""
          <CoreComponents.empty_state icon="hero-key" title="No tokens yet" compact>
            Make one.
          </CoreComponents.empty_state>
          """)
        )

      assert LazyHTML.attribute(root, "data-empty-state") == ["compact"]
      assert class(root) =~ "border-dashed"
      refute class(root) =~ "ring-1"

      square = LazyHTML.query(root, "span:has(> .hero-key)")
      assert class(square) =~ "size-9"
      assert root |> LazyHTML.query(".hero-key") |> class() =~ "size-5"
      assert root |> LazyHTML.query("h3") |> LazyHTML.text() == "No tokens yet"
      assert root |> LazyHTML.query("h2") |> Enum.count() == 0
    end
  end

  describe "the action" do
    test "renders its slot in an action row" do
      assigns = %{}

      root =
        root(
          rendered_to_string(~H"""
          <CoreComponents.empty_state icon="hero-user-group" title="No groups yet">
            Make one.
            <:action><button id="make-one" type="button">Create group</button></:action>
          </CoreComponents.empty_state>
          """)
        )

      action = LazyHTML.query(root, "[data-role=empty-state-action]")
      assert Enum.count(action) == 1
      assert action |> LazyHTML.query("button#make-one") |> LazyHTML.text() == "Create group"
    end

    test "a slot that is :if'd away leaves no empty action row" do
      refute guarded(false) =~ "empty-state-action"
      refute guarded(false) =~ "Create group"
      assert guarded(true) =~ "empty-state-action"
    end
  end

  defp guarded(can?) do
    assigns = %{can?: can?}

    rendered_to_string(~H"""
    <CoreComponents.empty_state icon="hero-user-group" title="No groups yet">
      Make one.
      <:action :if={@can?}><button type="button">Create group</button></:action>
    </CoreComponents.empty_state>
    """)
  end

  describe "attributes" do
    test "the rose tone tints the square rose instead of primary" do
      assigns = %{}

      root =
        root(
          rendered_to_string(~H"""
          <CoreComponents.empty_state icon="hero-heart" title="x" tone="rose" />
          """)
        )

      square = LazyHTML.query(root, "span:has(> .hero-heart)")
      assert class(square) =~ "bg-rose-500/10"
      refute class(square) =~ "bg-primary/10"
    end

    test "with no copy there is no empty paragraph; class and global attrs pass through" do
      assigns = %{}

      root =
        root(
          rendered_to_string(~H"""
          <CoreComponents.empty_state
            icon="hero-clock"
            title="No versions yet"
            class="mt-7"
            data-test="x"
          />
          """)
        )

      assert root |> LazyHTML.query("p") |> Enum.count() == 0
      assert class(root) =~ "mt-7"
      assert LazyHTML.attribute(root, "data-test") == ["x"]
      assert LazyHTML.attribute(root, "id") == []
    end

    test "inline code in the copy stays in the sentence, in mono" do
      assigns = %{}

      root =
        root(
          rendered_to_string(~H"""
          <CoreComponents.empty_state icon="hero-key" title="x" compact>
            Run <code>slipdock auth</code> after.
          </CoreComponents.empty_state>
          """)
        )

      p = LazyHTML.query(root, "p")
      assert class(p) =~ "[&_code]:font-mono"
      assert p |> LazyHTML.query("code") |> LazyHTML.text() == "slipdock auth"
      assert LazyHTML.text(p) =~ ~r/Run\s+slipdock auth\s+after\./
    end

    test "an unknown tone is an error, not a square with no tint" do
      assigns = %{tone: Enum.join(["li", "me"])}

      assert_raise FunctionClauseError, fn ->
        rendered_to_string(~H"""
        <CoreComponents.empty_state icon="hero-x-mark" title="x" tone={@tone} />
        """)
      end
    end
  end
end
