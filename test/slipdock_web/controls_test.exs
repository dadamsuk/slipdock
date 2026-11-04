defmodule SlipdockWeb.ControlsTest do
  @moduledoc """
  Brand system 4 (#1704): checkboxes, toggles and radios have one look each.

  The look lives in one place (the Controls block in `assets/css/app.css`),
  so the templates may only name the control — `checkbox`, `toggle` or
  `radio` — and never a daisyUI size or colour modifier beside it. These
  tests read the source: a template that brings back `checkbox-xs` (the
  6px-radius circle that passed for a radio) fails here.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]
  import Phoenix.Component, only: [sigil_H: 2]

  @modifier ~r/\b(?:checkbox|toggle|radio)-(?:xs|sm|md|lg|xl|primary|secondary|accent|neutral|success|warning|info|error)\b/

  # An <input …> tag, attributes spanning lines, quoted values and {…}
  # expressions included (neither may hide a `>`).
  @input_tag ~r/<input\b(?:[^>"{]|"[^"]*"|\{[^}]*\})*>/s

  defp sources do
    Path.wildcard("lib/slipdock_web/**/*.{ex,heex}")
    |> Enum.map(&{&1, File.read!(&1)})
  end

  @doc false
  # The modifiers in a source, as {line, text}.
  def modifiers(src) do
    src
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {line, n} ->
      @modifier |> Regex.scan(line) |> Enum.map(fn [m] -> {n, m} end)
    end)
  end

  @doc false
  # Checkbox and radio inputs whose class isn't the control's own class
  # (and that aren't visually hidden behind a custom control).
  def stray_inputs(src) do
    for [tag] <- Regex.scan(@input_tag, src),
        type = input_type(tag),
        type != nil,
        class = class_of(tag),
        not hidden?(class),
        not styled?(type, class) do
      {type, String.replace(tag, ~r/\s+/, " ")}
    end
  end

  defp input_type(tag) do
    case Regex.run(~r/\btype="(checkbox|radio)"/, tag) do
      [_, type] -> type
      _ -> nil
    end
  end

  defp class_of(tag) do
    case Regex.run(~r/\bclass=(?:"([^"]*)"|\{((?:[^{}]|\{[^{}]*\})*)\})/s, tag) do
      [_, quoted] -> quoted
      [_, "", expr] -> expr
      _ -> ""
    end
  end

  defp hidden?(class), do: class =~ ~r/(?:^|[\s"])(?:sr-only|hidden)(?:$|[\s"])/

  defp styled?("radio", class), do: class =~ ~r/(?:^|[\s"])radio(?:$|[\s"])/

  defp styled?("checkbox", class),
    do: class =~ ~r/(?:^|[\s"])(?:checkbox|toggle)(?:$|[\s"])/

  describe "the scanners" do
    test "find a modifier, with its line, and not a lookalike" do
      src =
        ~s(<input class="checkbox"/>\n<input class="checkbox checkbox-xs"/>\n) <>
          ~s(<b id="toggle-1" class="toggle-panel">)

      assert modifiers(src) == [{2, "checkbox-xs"}]

      assert modifiers(~s(class="toggle toggle-success radio-primary")) ==
               [{1, "toggle-success"}, {1, "radio-primary"}]
    end

    test "read a tag spread over lines, with an expression holding a >" do
      src = """
      <input
        type="checkbox"
        phx-click={if @a > 1, do: "x"}
        class="mt-0.5"
      />
      """

      assert [{"checkbox", _}] = stray_inputs(src)
    end

    test "accept the control's own class, in a string or a list" do
      assert stray_inputs(~s(<input type="checkbox" class="checkbox mt-0.5" />)) == []
      assert stray_inputs(~s(<input type="checkbox" class="toggle" />)) == []
      assert stray_inputs(~s(<input type="radio" class={["radio", @x && "mt-1"]} />)) == []
    end

    test "flag a radio styled as a checkbox, and an input with no class" do
      assert [{"radio", _}] = stray_inputs(~s(<input type="radio" class="checkbox" />))
      assert [{"checkbox", _}] = stray_inputs(~s(<input type="checkbox" name="a" />))
    end

    test "leave visually hidden inputs and other input types alone" do
      assert stray_inputs(~s(<input type="checkbox" class="peer sr-only" />)) == []
      assert stray_inputs(~s(<input type="radio" class="hidden" />)) == []
      assert stray_inputs(~s(<input type="text" class="input" />)) == []
    end
  end

  describe "the templates" do
    test "carry no size or colour modifier on a checkbox, toggle or radio" do
      found =
        for {path, src} <- sources(), {line, m} <- modifiers(src), do: "#{path}:#{line} #{m}"

      assert found == [],
             "modifiers to remove (the look is in app.css):\n" <> Enum.join(found, "\n")
    end

    test "give every visible checkbox and radio its control's class" do
      found =
        for {path, src} <- sources(),
            {type, tag} <- stray_inputs(src),
            do: "#{path} #{type}: #{tag}"

      assert found == [], Enum.join(found, "\n")
    end

    test "core_components' checkbox defaults to the plain class" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <SlipdockWeb.CoreComponents.input type="checkbox" name="done" value={true} label="Done" />
        """)

      assert html =~ ~s(class="checkbox")
      refute html =~ @modifier
    end
  end

  describe "app.css" do
    setup do
      %{css: File.read!("assets/css/app.css")}
    end

    # The body of the rule whose selector list is exactly `selector`.
    defp rule(css, selector) do
      want = normalise(selector)

      found =
        Regex.scan(~r/([^{}]+)\{([^{}]*)\}/, css)
        |> Enum.find(fn [_, sel, _] -> normalise(sel) == want end)

      case found do
        [_, _, body] -> body
        nil -> flunk("no rule for #{selector} in app.css")
      end
    end

    defp normalise(selector) do
      selector
      |> String.replace(~r{/\*.*?\*/}s, "")
      |> String.split(",")
      |> Enum.map_join(", ", &String.trim/1)
    end

    test "draws the checkbox square, 16px, with a 4px radius", %{css: css} do
      assert rule(css, ".checkbox, .radio") =~ "width: 1rem"
      assert rule(css, ".checkbox, .radio") =~ "height: 1rem"
      assert rule(css, ".checkbox") =~ "border-radius: 0.25rem"
    end

    test "fills a checked checkbox with the primary and a primary-content tick", %{css: css} do
      body =
        rule(css, ~s(.checkbox:checked, .checkbox[aria-checked="true"], .checkbox:indeterminate))

      assert body =~ "background-color: var(--color-primary)"
      assert body =~ "color: var(--color-primary-content)"
    end

    test "keeps the radio round, with a primary dot", %{css: css} do
      assert rule(css, ".radio") =~ "border-radius: 9999px"

      assert rule(css, ~s(.radio:checked, .radio[aria-checked="true"])) =~
               "color: var(--color-primary)"
    end

    test "fills a toggle that is on with the primary, in either theme", %{css: css} do
      body =
        rule(
          css,
          ~s(.toggle:checked, .toggle[aria-checked="true"], .toggle:has\(> input:checked\))
        )

      assert body =~ "background-color: var(--color-primary)"
      assert body =~ "border-color: var(--color-primary)"
      # Theme-free: the rule names tokens only, so light and dark both follow.
      refute css =~ ~r/\[data-theme[^\]]*\][^{]*\.toggle/
    end

    test "sizes the toggle apart from the checkbox and radio", %{css: css} do
      assert rule(css, ".toggle") =~ "--size: 1.25rem"
      assert rule(css, ".checkbox, .radio") =~ "--size: 1rem"
    end
  end
end
