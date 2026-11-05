defmodule SlipdockWeb.AutomationsLayoutLiveTest do
  @moduledoc """
  The automations panel's ready-made rules as a grid of soft buttons (#1741):
  the group names in a column of their own and each group's buttons in a
  grid beside its name, so a long group wraps under its own buttons and
  never under the names; and each rule's on/off is the brand switch. The
  wrapping itself is measured at 1280 and 1440 in Chromium by
  `tools/e2e/board-settings.sh`.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.Automations
  alias Slipdock.Automations.Presets

  setup %{user: user} do
    board = board_fixture(%{"name" => "Rules laid out"}, owner: user)
    %{board: board}
  end

  defp open(conn, board) do
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/automations")
    view
  end

  defp doc(view), do: view |> render() |> LazyHTML.from_document()

  defp texts(nodes), do: Enum.map(nodes, &String.trim(LazyHTML.text(&1)))

  test "each group is a name beside a grid of its own buttons", %{conn: conn, board: board} do
    view = open(conn, board)
    html = doc(view)

    labels = LazyHTML.query(html, "#rule-presets [data-role=preset-group-label]")
    grids = LazyHTML.query(html, "#rule-presets [data-role=preset-group]")

    # The runner presets show only on a board with runners; the rest, in order.
    groups =
      Presets.all()
      |> Enum.reject(&(&1.key in ~w(send_to_runner feed_runner)))
      |> Enum.chunk_by(& &1.group)

    assert texts(labels) == Enum.map(groups, &hd(&1).group)
    assert Enum.count(grids) == length(groups)

    # Every preset's button is in its own group's grid, and nowhere else.
    for {group, grid} <- Enum.zip(groups, grids) do
      ids = grid |> LazyHTML.query("button") |> LazyHTML.attribute("id")
      assert ids == Enum.map(group, &"rule-preset-#{&1.key}")
    end

    # One grid of two columns, names then buttons: a wrap can't go under a name.
    [outer] =
      html
      |> LazyHTML.query("#rule-presets > div.grid")
      |> LazyHTML.attribute("class")

    assert outer =~ "grid-cols-[4.5rem_minmax(0,1fr)]"

    for class <- LazyHTML.attribute(grids, "class") do
      assert class =~ "grid-cols-[repeat(auto-fill,minmax(10.5rem,1fr))]"
    end
  end

  test "the buttons are soft buttons, not outlined chips", %{conn: conn, board: board} do
    html = conn |> open(board) |> doc()

    for class <-
          html
          |> LazyHTML.query("#rule-presets button[id^=rule-preset-]")
          |> LazyHTML.attribute("class") do
      assert class =~ ~r/\bbtn btn-sm btn-secondary\b/
      refute class =~ "chip-line"
    end
  end

  test "the picked one is pressed, and only it", %{conn: conn, board: board} do
    view = open(conn, board)

    view |> element("#rule-preset-due_soon") |> render_click()

    assert has_element?(view, ~s|#rule-preset-due_soon[aria-pressed="true"].ring-primary|)
    assert has_element?(view, ~s|#rule-preset-overdue[aria-pressed="false"]|)
    refute has_element?(view, ~s|#rule-preset-overdue.ring-primary|)
  end

  describe "a rule's switch" do
    setup %{conn: conn, board: board} do
      [_, doing | _] = board.columns
      view = open(conn, board)
      view |> element("#rule-preset-follow_list") |> render_click()

      view
      |> form("#rule-preset-form", %{"preset" => %{"column" => doing.name, "notify" => "alert"}})
      |> render_submit()

      [rule] = Automations.list_rules(board.id)
      %{view: view, rule: rule}
    end

    test "is the brand toggle, labelled with the rule's name", %{view: view, rule: rule} do
      switch = "#rule-switch-#{rule.id}"

      assert has_element?(
               view,
               ~s|#{switch}[role=switch][type=checkbox].toggle[aria-checked="true"]|
             )

      assert has_element?(view, ~s|#{switch}[aria-label="#{rule.name}"]|)

      # The class alone: no daisyUI colour or size beside it (#1704).
      [class] = view |> doc() |> LazyHTML.query(switch) |> LazyHTML.attribute("class")
      refute class =~ ~r/toggle-(?:xs|sm|md|lg|primary|success|neutral)/
    end

    test "turns the rule off and on, and says which", %{view: view, rule: rule} do
      switch = "#rule-switch-#{rule.id}"

      view |> element(switch) |> render_click()
      refute Automations.get_rule!(rule.id).enabled
      assert has_element?(view, ~s|#{switch}[aria-checked="false"]|)
      refute has_element?(view, "#{switch}[checked]")

      view |> element(switch) |> render_click()
      assert Automations.get_rule!(rule.id).enabled
      assert has_element?(view, ~s|#{switch}[aria-checked="true"][checked]|)
    end
  end
end
