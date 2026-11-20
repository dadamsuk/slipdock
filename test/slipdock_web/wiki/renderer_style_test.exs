defmodule SlipdockWeb.Wiki.RendererStyleTest do
  @moduledoc """
  The inline style a page's HTML may carry (#3529): a colour, a background
  colour, a text alignment and a percentage width, which is what the
  renderer's own progress bar is made of. Any other declaration written in
  raw HTML is taken off, one declaration at a time.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.Boards
  alias SlipdockWeb.Wiki.Renderer

  # A style attribute written out in a source file, its value starting with
  # a property: the renderer's own `style="#{...}"` builds one, not writes one.
  @written ~r/style="([a-z-]+:[^"]*)"/

  defp styles(html) do
    ~r/ style="([^"]*)"/
    |> Regex.scan(html, capture: :all_but_first)
    |> List.flatten()
  end

  describe "style written in raw HTML" do
    test "positioning is taken off, and the attribute with it" do
      html = Renderer.to_html(~s|<div style="position:fixed;inset:0;z-index:50">Cover</div>|)

      assert html =~ "<div>Cover</div>"
      refute html =~ "style="
      refute html =~ "fixed"
      refute html =~ "z-index"
      refute html =~ "inset"
    end

    test "on every tag the sanitiser lets style through on" do
      html =
        Renderer.to_html("""
        <div style="position: absolute; top: 0">d</div>

        <span style="position: fixed">s</span> <code style="z-index: 9">c</code>

        <pre style="transform: scale(9)">p</pre>
        """)

      assert styles(html) == []
      assert html =~ "<div>d</div>"
      assert html =~ "<span>s</span>"
      assert html =~ "<code>c</code>"
      assert html =~ "<pre>p</pre>"
    end

    test "a mixed list keeps the allowed declarations and loses the rest" do
      html =
        Renderer.to_html(
          ~s|<span style="position:fixed; COLOR: Red; inset: 0; text-align:center; z-index:50">x</span>|
        )

      assert styles(html) == ["color: Red; text-align: center"]
    end

    test "colours in their usual forms are kept" do
      for colour <- ~w[red #fff #12345678 rgb(1,2,3) rgba(1,2,3,0.5) hsl(120,50%,50%)] do
        html = Renderer.to_html(~s|<span style="background-color: #{colour}">x</span>|)
        assert styles(html) == ["background-color: #{colour}"], colour
      end
    end

    test "a value outside the simple forms is taken off" do
      for style <- [
            "background-color: url(/x.png)",
            "color: red !important",
            "color: var(--x)",
            "color: expression(1)",
            "color: r\\65 d",
            "color: red/* c */",
            "text-align: -webkit-center",
            "width: 100vw",
            "width: 101%",
            "width: 1000%",
            "width: calc(100% + 1px)",
            "width: -5%"
          ] do
        html = Renderer.to_html(~s|<span style="#{style}">x</span>|)
        assert styles(html) == [], style
      end
    end

    test "a property is matched exactly, not by a part of it or an escape" do
      for style <- ["max-width: 50%", "border-color: red", "colour: red", "posit\\ion: fixed"] do
        html = Renderer.to_html(~s|<span style="#{style}">x</span>|)
        assert styles(html) == [], style
      end
    end

    test "an escaped character can't carry a declaration through" do
      html =
        Renderer.to_html(~s|<span style="color: red&amp;position:fixed;inset:0">x</span>|)

      assert styles(html) == []
      refute html =~ "position"
    end

    test "an empty or malformed style attribute goes" do
      html = Renderer.to_html(~s|<span style="">a</span> <span style=";;: ;color">b</span>|)
      refute html =~ "style="
    end

    test "a ` style=` inside another attribute's value is left as it is" do
      html = Renderer.to_html(~s|<span title="x style=" data-tag="position:fixed">t</span>|)

      assert html =~ ~s|<span title="x style=" data-tag="position:fixed">t</span>|
    end

    test "a tag the sanitiser gives no style keeps none, allowed or not" do
      html = Renderer.to_html(~s|<p style="color: red">p</p>|)
      assert html =~ "<p>p</p>"
    end
  end

  describe "the style the renderer writes" do
    setup do
      user = user_fixture()
      board = board_fixture(%{"name" => "Handbook", "code" => "style3529"}, owner: user)
      [backlog, doing | _] = board.columns
      card_fixture(backlog, %{"title" => "Open"})
      card_fixture(doing, %{"title" => "Shipped", "completed" => true})

      %{user: user, board: Boards.get_board!(board.id)}
    end

    test "a progress bar keeps its width", %{board: board, user: user} do
      html = Renderer.to_html("```slipdock\nview: progress\n```", board: board, as: user)

      assert html =~ ~s|<div class="wiki-progress-bar" style="width: 50%"></div>|
    end

    test "a table's column alignment still renders" do
      html = Renderer.to_html("| a | b |\n|:-:|--:|\n| 1 | 2 |\n")

      assert html =~ ~s|<th align="center">a</th>|
      assert html =~ ~s|<td align="right">2</td>|
    end

    # Every style the renderer and the transcript view write is allowed, so
    # a new one fails here rather than vanishing from the page unseen.
    test "every style written in their sources is allowed" do
      sources = [
        "lib/slipdock_web/wiki/renderer.ex",
        "lib/slipdock_web/components/transcript_view.ex"
      ]

      for path <- sources,
          [style] <- Regex.scan(@written, File.read!(path), capture: :all_but_first),
          declaration <- String.split(style, ";", trim: true),
          # An interpolated value, such as the progress bar's percentage,
          # is checked with a value it takes.
          declaration = String.replace(declaration, ~r/#\{[^}]*\}/, "50"),
          [property, value] = String.split(declaration, ":", parts: 2) do
        assert Renderer.allowed_style?(String.trim(property), String.trim(value)),
               "#{path}: #{declaration} is not allowed"
      end
    end
  end
end
