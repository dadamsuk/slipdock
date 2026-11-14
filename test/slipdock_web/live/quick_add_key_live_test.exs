defmodule SlipdockWeb.QuickAddKeyLiveTest do
  @moduledoc """
  The header's quick add has one key, `q`, answered by the `Keys` hook with
  the rest of the page-wide shortcuts (#2871). It once had a second, `c`, from
  a hook of its own that skipped the guards `Keys` applies and fired beside
  the board's own `c`; these hold that it stays gone, that the docs name `q`,
  and that "is the user typing?" is asked in one place, `assets/js/typing.js`
  (its behaviour is in `assets/js/typing.test.js`).
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures
  import Slipdock.DocsFacts, only: [assert_states: 2]

  @root Path.expand("../../..", __DIR__)
  defp read(path), do: File.read!(Path.join(@root, path))

  describe "the header's quick add" do
    setup do
      %{board: board_fixture(%{"name" => "Keys"})}
    end

    test "carries no key hook of its own, and its button names q", %{conn: conn, board: board} do
      {:ok, view, _html} = live(conn, ~p"/boards/#{board}")

      assert has_element?(view, "#quick-add")
      refute has_element?(view, "#quick-add[phx-hook]")
      refute render(view) =~ "QuickAddKey"
      assert has_element?(view, ~s{#quick-add-open[title*="(q)"]})
    end

    test "opens and closes on the event the q key sends", %{conn: conn, board: board} do
      {:ok, view, _html} = live(conn, ~p"/boards/#{board}")
      refute has_element?(view, "#quick-add-panel")

      render_hook(view, "toggle_quick_add", %{})
      assert has_element?(view, "#quick-add-panel")

      render_hook(view, "toggle_quick_add", %{})
      refute has_element?(view, "#quick-add-panel")
    end
  end

  describe "the key, as it is written down" do
    test "the catalogue gives quick add q, and c to the board's lists" do
      keys = SlipdockWeb.Shortcuts.all()

      assert {"q", "Quick add a card"} in keys
      refute Enum.any?(keys, fn row -> elem(row, 0) == "c" and elem(row, 1) =~ ~r/quick add/i end)
    end

    test "the help page says q", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/help/boards")

      assert html =~ ~r{<strong>Quick add</strong>: press <kbd class="kbd kbd-xs">q</kbd>}
      refute html =~ ~r{<strong>Quick add</strong>: press <kbd class="kbd kbd-xs">c</kbd>}
    end

    test "the manual says q" do
      features = read("docs/manual/features.md")
      assert_states(features, "**Quick add in the header** of every page (or press `q`)")
      refute features =~ "(or press `c`)"

      assert read("docs/manual/quick-add.md") =~ "(or the `q` key)"
    end
  end

  describe "in the JavaScript" do
    test "the c hook is gone, and Keys still sends quick add on q" do
      app = read("assets/js/app.js")

      refute app =~ "QuickAddKey"
      assert app =~ ~s|case "q": return this.send(e, "toggle_quick_add", {})|
    end

    test "typing() is written once, in typing.js, and imported by the two that ask" do
      assert read("assets/js/typing.js") =~ "export function typing(el = document.activeElement)"

      for file <- ~w(assets/js/app.js assets/js/transcript_player.js) do
        source = read(file)
        refute source =~ ~r/function typing\(/, "#{file} has its own typing()"

        assert source =~ ~r/^import \{typing\} from "\.\/typing(\.js)?"$/m,
               "#{file} imports typing"
      end

      # No other module tests for a field by tag name on its own.
      for file <- Path.wildcard(Path.join(@root, "assets/js/*.js")),
          not String.ends_with?(file, ".test.js"),
          Path.basename(file) != "typing.js" do
        refute File.read!(file) =~ ~r/\[\s*"INPUT",\s*"TEXTAREA",\s*"SELECT"\s*\]/,
               "#{Path.basename(file)} writes the typing test again"
      end
    end
  end
end
