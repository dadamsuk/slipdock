defmodule SlipdockWeb.VisualisePolishTest do
  @moduledoc """
  The Visualise page on a phone, in the dark and to assistive tech (#1195),
  and the docs that name it.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  @templates ~w(visualise.ex visualise_components.ex visualise_charts.ex)
             |> Enum.map(&Path.join("lib/slipdock_web/live/board_live", &1))

  setup %{user: user} do
    board = board_fixture(%{"name" => "Polish"}, owner: user)
    [_backlog, todo, doing, done] = board.columns
    card_fixture(todo)
    c = card_fixture(doing)
    :ok = Slipdock.Boards.move_card(c.id, done.id, nil)
    card_fixture(doing)
    %{board: board}
  end

  test "every grid is one column on a phone, and wide things scroll in their box",
       %{conn: conn, board: board} do
    {:ok, _view, html} = live(conn, ~p"/boards/#{board}/visualise")

    # The tiles, the pair of half-width cards and the charts all start at one column.
    assert html =~ "grid grid-cols-1 gap-3 sm:grid-cols-2"
    assert html =~ ~s|id="visualise-pair" class="grid gap-4 lg:grid-cols-2"|
    assert html =~ "grid gap-4 lg:grid-cols-2"
    # The flow strip wraps and hides its arrows; the page has no fixed widths.
    assert html =~ "flex flex-wrap items-stretch gap-2"
    [_, page] = String.split(html, ~s|id="visualise"|, parts: 2)
    refute page =~ ~r/[\s"]w-\[\d{3,}px\]/
    # The window switch is at the top, where a phone can reach it.
    assert html =~ ~s|id="window-switch"|
  end

  test "no colour is written by hand in the page's templates" do
    for path <- @templates do
      source = File.read!(path)
      refute source =~ ~r/(fill|stroke|color|background)[=:]\s*"?#[0-9a-fA-F]{3,8}\b/, path
      refute source =~ ~r/\b(text|bg|fill|stroke|border)-\[#/, path
      refute source =~ ~r/rgba?\(|oklch\(|hsla?\(/, path
    end
  end

  test "small muted words take more of the text colour in the dark" do
    css = File.read!("assets/css/app.css")
    assert css =~ ~s|[data-theme="dark"] #visualise .text-base-content\\/60|
    assert css =~ "var(--color-base-content) 65%"
  end

  test "every chart says what it shows, and the switch is real pressed buttons",
       %{conn: conn, board: board} do
    {:ok, view, html} = live(conn, ~p"/boards/#{board}/visualise")

    labels = Regex.scan(~r/<svg[^>]*role="img"[^>]*aria-label="([^"]*)"/, html)
    assert length(labels) >= 4
    assert Enum.all?(labels, fn [_, label] -> String.length(label) > 20 end)

    for d <- [7, 30, 90] do
      assert has_element?(view, ~s|button#window-#{d}[type="button"][aria-pressed]|)
    end

    assert html =~ "focus-visible:ring-primary/40"
    # The P85 line is dashed, not only another colour.
    assert has_element?(view, ~s|#chart-cycle line[data-line="p85"][stroke-dasharray]|)
  end

  test "the docs name the page and its new doors" do
    readme = File.read!("README.md")
    manual = File.read!("docs/manual.md")
    agents = File.read!("docs/agents.md")
    skill = File.read!("priv/skills/slipdock/SKILL.md")

    assert readme =~ "**Visualise**"
    assert readme =~ "slipdock flow <board>"
    assert readme =~ "slipdock runner-stats <board>"
    assert manual =~ "## Visualise: flow, velocity, runners and delivery"
    assert manual =~ "#visualise-flow-velocity-runners-and-delivery"
    assert agents =~ "history: true"
    assert agents =~ "runners: true"
    assert skill =~ "slipdock flow <board>"
    assert skill =~ "slipdock runner-stats <board>"
    assert SlipdockWeb.APIGuide.markdown() =~ "/flow?days="
  end

  test "/help/agents lists the flow and runner doors", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/help/agents")
    assert html =~ "slipdock flow, slipdock runner-stats"
    assert html =~ "get_board&#39;s history, runners"
  end
end
