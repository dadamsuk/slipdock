defmodule Slipdock.Handbook.RulesTest do
  @moduledoc """
  Handbook rules (#1773, W-2310 §Rules): list items in a page's `## Rules`,
  each with an id, a severity, a scope, a check and its text. The parser is
  a pure function of the pages, so these build pages in memory.
  """
  use ExUnit.Case, async: true

  alias Slipdock.Handbook.Rules
  alias Slipdock.Wiki.Page

  defp page(code, key, body, covers \\ "[]") do
    %Page{
      code: code,
      title: "Page #{code}",
      body: body,
      front_matter: "---\nhandbook: #{key}\ncovers: #{covers}\n---\n"
    }
  end

  defp handbook(pages), do: %{pages: pages}

  @ux """
  # UX & UI

  Prose about the interface. It says **UX-9** must · judgement · in passing, which is not a rule.

  ## Patterns

  - **UX-8** must · judgement · Outside Rules, so not a rule.

  ## Rules

  _One list item per rule._

  - **UX-1** must · test/slipdock_web/design_tokens_test.exs · No hex, rgb() or oklch() under lib/slipdock_web.
  - **UX-2** should · scope lib/slipdock_web/live/**, assets/css/** · judgement · A screen uses the
    layout's header, not one of its own.

  ### Controls

  * **UX-3** must · `test/a_test.exs`, tools/e2e/controls.sh · Buttons have a type · even in forms.

  ```
  - **UX-7** must · judgement · Inside a fence.
  ```

  ## Later

  - **UX-6** must · judgement · After the section.
  """

  describe "parse_page/1" do
    test "reads every part, and only items in ## Rules" do
      {rules, problems} =
        Rules.parse_page(page("W-4", "ux", @ux, "[lib/slipdock_web/**, assets/**]"))

      assert problems == []
      assert Enum.map(rules, & &1.id) == ["UX-1", "UX-2", "UX-3"]
      [one, two, three] = rules

      assert one == %{
               id: "UX-1",
               page: "W-4",
               page_title: "Page W-4",
               section: "UX & UI/Rules",
               line: 13,
               severity: "must",
               scope: ["lib/slipdock_web/**", "assets/**"],
               check: "test/slipdock_web/design_tokens_test.exs",
               text: "No hex, rgb() or oklch() under lib/slipdock_web."
             }

      # Its own scope wins over the page's covers; an indented line continues it.
      assert two.severity == "should"
      assert two.scope == ["lib/slipdock_web/live/**", "assets/css/**"]
      assert two.check == "judgement"
      assert two.text == "A screen uses the layout's header, not one of its own."

      # A ### groups rules; several checks; a ` · ` in the text survives.
      assert three.section == "UX & UI/Rules/Controls"
      assert three.check == "test/a_test.exs, tools/e2e/controls.sh"
      assert three.text == "Buttons have a type · even in forms."
    end

    test "a rule with no scope on a page that covers nothing applies everywhere" do
      body = "# Ops\n\n## Rules\n\n- **OPS-1** must · judgement · Deploys go through CI.\n"
      {[rule], []} = Rules.parse_page(page("W-8", "operations", body))
      assert rule.scope == ["**"]

      # A page with no covers key at all reads the same.
      bare = %Page{
        code: "W-8",
        title: "Ops",
        body: body,
        front_matter: "---\nhandbook: operations\n---\n"
      }

      assert {[%{scope: ["**"]}], []} = Rules.parse_page(bare)
    end

    test "a covers: written as one string is a one-glob scope" do
      body = "## Rules\n\n- **DATA-1** must · judgement · Never cast.\n"

      assert {[%{scope: ["priv/repo/**"]}], []} =
               Rules.parse_page(page("W-5", "data-model", body, "priv/repo/**"))
    end

    test "a page without a Rules section, or without a body, has no rules" do
      assert Rules.parse_page(page("W-2", "architecture", "# Arch\n\n## Contexts\n\n- a\n")) ==
               {[], []}

      assert Rules.parse_page(page("W-2", "architecture", nil)) == {[], []}
    end

    test "malformed items are left out and reported with the page and line" do
      body = """
      ## Rules

      - **UX-1** · judgement · No severity.
      - **UX-2** may · judgement · A severity that isn't one.
      - UX-3 must · judgement · No bold id.
      - **UX-4** must · No check at all.
      - **UX-5** must · judgement
      - **UX-6** must · scope lib/** · judgement · Fine.
      - **ux-7** must · judgement · Lower-case id.
      """

      {rules, problems} = Rules.parse_page(page("W-4", "ux", body))

      assert Enum.map(rules, & &1.id) == ["UX-6"]

      assert Enum.map(problems, &{&1.line, &1.problem}) == [
               {3, "no severity: `must` or `should` after the id"},
               {4, "no severity: `must` or `should` after the id"},
               {5, "no rule id: start the item with one in bold, like **UX-1**"},
               {6, "no check: a test path, or `judgement`"},
               {7, "no text: say what the rule is after the check"},
               {9, "no rule id: start the item with one in bold, like **UX-1**"}
             ]

      assert hd(problems).page == "W-4"
      assert hd(problems).item == "**UX-1** · judgement · No severity."
    end
  end

  describe "parse/1" do
    test "an id used twice is kept where it first appears and reported again" do
      first = page("W-4", "ux", "## Rules\n\n- **UX-1** must · judgement · First.\n")

      second =
        page(
          "W-9",
          "ux",
          "## Rules\n\n- **UX-2** should · judgement · Other.\n- **UX-1** must · judgement · Again.\n"
        )

      {rules, problems} = Rules.parse(handbook([first, second]))

      assert Enum.map(rules, &{&1.id, &1.text}) == [{"UX-1", "First."}, {"UX-2", "Other."}]

      assert [%{page: "W-9", line: 4, item: "UX-1", problem: problem}] = problems
      assert problem == "UX-1 is already used on W-4 line 3"
      assert Rules.rules(handbook([first, second])) == rules
      assert Rules.problems(handbook([first, second])) == problems
    end

    test "an id without its page's prefix still counts, and is reported" do
      body = "## Rules\n\n- **UX-1** must · judgement · On the wrong page.\n"
      {rules, problems} = Rules.parse(handbook([page("W-5", "data-model", body)]))

      assert [%{id: "UX-1"}] = rules
      assert [%{line: 3, problem: "UX-1 should start DATA- on this page"}] = problems
    end

    test "no handbook has no rules" do
      assert Rules.parse(nil) == {[], []}
      assert Rules.rules(nil) == []
    end
  end

  test "prefix/1 for the built-in sections and any other key" do
    assert Rules.prefix("ux") == "UX"
    assert Rules.prefix("data-model") == "DATA"
    assert Rules.prefix("specification") == "SPEC"
    assert Rules.prefix("testing") == "TEST"
    assert Rules.prefix("release-notes") == "RELEASENOTES"
    assert Rules.prefix(nil) == nil
  end
end
