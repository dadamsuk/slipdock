defmodule SlipdockWeb.AgentTextShapeDocsTest do
  @moduledoc """
  What an agent writes onto a card has a shape (#2692, #2699): the README,
  the manual's Verified work page, the How work flows help page and the API
  guide say a reason or evidence is lines, not a paragraph, sent on stdin
  (`--reason -`, `--evidence -`), and their examples are in that shape; the
  manual and the guide say an agent's verdict whose reason is a bare `-` is
  refused.
  """
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.DocsFacts, only: [assert_states: 2, assert_states: 3]

  import Phoenix.LiveViewTest

  alias SlipdockWeb.HelpLive.Flow

  @root Path.expand("../..", __DIR__)

  defp read(path), do: @root |> Path.join(path) |> File.read!()

  # Verified work is in the API guide only for a reader with a board that has
  # it on: this one has evidence, a second agent and pull requests.
  defp guide do
    owner = Slipdock.Fixtures.user_fixture("text-shape-owner@example.com")
    board = Slipdock.Fixtures.board_fixture(%{"name" => "Shapes"}, owner: owner)

    {:ok, _} =
      Slipdock.Boards.update_board(board, %{
        "evidence_required" => true,
        "verify_work" => true,
        "ship_via" => "pull_request"
      })

    SlipdockWeb.APIGuide.markdown(user: owner)
  end

  defp flat(text), do: String.replace(text, ~r/\s+/u, " ")

  # The shape, said: a first line that stands alone, a blank line, a line per
  # point, the parts in their fields.
  defp assert_says_the_shape(flat, where) do
    assert flat =~ "lines, not a paragraph", where
    assert_states(flat, "a first line that stands alone", where)
    assert flat =~ "a blank line", where
    assert flat =~ "one short line per point", where
    assert flat =~ "--check", where
  end

  # Every heredoc in `text` that feeds `--evidence -` or `--reason -` is the
  # shape: a first line, a blank line, then only `- ` lines up to EOF.
  defp heredocs(text) do
    ~r/--(?:evidence|reason) - <<'EOF'\n(.*?)\n\s*EOF/su
    |> Regex.scan(text, capture: :all_but_first)
    |> Enum.map(fn [body] ->
      body |> String.split("\n") |> Enum.map(&String.trim/1)
    end)
  end

  defp assert_shaped_examples(text, at_least, where) do
    docs = heredocs(text)
    assert length(docs) >= at_least, "#{where}: #{length(docs)} stdin examples"

    for [first, blank | points] <- docs do
      refute first == "", "#{where}: an example opens with a blank line"
      refute String.starts_with?(first, "- "), "#{where}: an example opens with a point"
      assert blank == "", "#{where}: no blank line after #{inspect(first)}"
      assert points != [], "#{where}: #{inspect(first)} has no points"

      for point <- points,
          do: assert(String.starts_with?(point, "- "), "#{where}: #{inspect(point)}")
    end
  end

  # No example passes the text as one shell argument.
  defp refute_one_argument(flat, where) do
    refute flat =~ ~r/--evidence ["<]|--evidence TEXT/u, "#{where} shows --evidence \"…\""

    refute flat =~ ~r/(?:reject|disagree|accept\|reject) --reason ["…]|--reason TEXT/u,
           "#{where} shows --reason \"…\""
  end

  test "the feature digest's Verified work says the shape, with an example on stdin" do
    readme = read("docs/manual/every-feature-in-brief.md")
    flat = flat(readme)

    assert flat =~ "`slipdock done 12 --evidence-commit abc1234 --evidence -`"
    assert flat =~ "`slipdock verify 12 accept|reject --reason -`"
    assert_states(flat, "Evidence and a reason are lines, not a paragraph, sent on stdin")
    assert_says_the_shape(String.downcase(flat), "docs/manual/every-feature-in-brief.md")
    assert flat =~ ~s(--no-code "<why>" --evidence -`)
    assert_shaped_examples(readme, 1, "docs/manual/every-feature-in-brief.md")
    refute_one_argument(flat, "docs/manual/every-feature-in-brief.md")
  end

  test "the manual's Verified work page: each example on stdin and in the shape" do
    page = read("docs/manual/verified-work.md")
    flat = flat(page)

    assert_states(flat, "**Evidence and a reason are lines, not a paragraph.**")
    assert_says_the_shape(String.downcase(flat), "verified-work.md")
    assert flat =~ "`slipdock done 12 --evidence-commit abc1234 --evidence -`"
    assert_states(flat, "`slipdock reject 12 --reason -`, the reason on stdin as lines")
    assert page =~ ~s(--check bar:2=fail:"no footer" --reason - <<'EOF')
    assert_states(flat, "`disagree --reason -` (the reason on stdin as lines")
    assert_states(page, "slipdock done 12 --evidence - <<'EOF'\nSubcards merged; main green.")

    assert page =~
             ~s(--no-code "a read-only sweep: filed #40 and #41" --evidence - <<'EOF')

    # The completion, the rejection, the epic's and the no-code card's.
    assert_shaped_examples(page, 4, "verified-work.md")
    refute_one_argument(flat, "verified-work.md")
  end

  test "the manual and the API guide say a bare `-` reason is refused, beside the dashed evidence" do
    page = flat(read("docs/manual/verified-work.md"))

    assert_states(
      page,
      "Evidence that is a bare `-` (once trimmed) is refused for agents"
    )

    assert_states(
      page,
      "An agent's verdict whose reason is a bare `-` is refused the same way (`422`), on accept, reject, agree and disagree"
    )

    assert page =~ "A person is never refused."

    guide = flat(guide())
    assert_states(guide, "So is evidence that is a bare `-` once trimmed")

    assert_states(
      guide,
      "An agent's verdict whose reason is a bare `-` is refused the same way (`422`), on accept, reject, agree and disagree"
    )

    assert guide =~ "a person is never refused"
  end

  test "the API guide's Verified work: the shape, and its epic, no-code, verify and audit examples on stdin" do
    guide = guide()
    flat = flat(guide)

    assert_states(flat, "**Evidence and a reason are lines, not a paragraph.**")
    assert_says_the_shape(String.downcase(flat), "the API guide")
    assert_states(flat, "`slipdock done ID --evidence -`, the evidence on stdin as lines")
    assert flat =~ ~s(--no-code "<why>" --evidence -`, what you did on stdin as lines)
    assert flat =~ "`slipdock verify ID accept|reject --reason - --evidence-commit SHA`"
    assert flat =~ "agree|disagree --reason -` (`verify_card`), the reason on stdin as lines"
    assert guide =~ ~s(--check bar:2=fail:"no test" --reason - <<'EOF')

    # The completion and the rejection.
    assert_shaped_examples(guide, 2, "the API guide")
    refute_one_argument(flat, "the API guide")
  end

  test "How work flows says the shape, and shows the completion and the rejection on stdin",
       %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/help/agents/flow")
    doc = LazyHTML.from_document(html)
    text = doc |> LazyHTML.text() |> flat()

    assert_states(text, "Evidence and a reason are lines, not a paragraph")
    assert_says_the_shape(String.downcase(text), "HelpLive.Flow")
    assert_states(text, "slipdock verify 12 reject --reason -, the reason on stdin as lines")

    for {role, example} <- [
          {"evidence-example", Flow.evidence_example()},
          {"reason-example", Flow.reason_example()}
        ] do
      shown = doc |> LazyHTML.query(~s(pre[data-role="#{role}"])) |> LazyHTML.text()
      assert shown == example, role
      assert_shaped_examples(example, 1, role)
    end

    assert Flow.reason_example() =~ ~s(--check bar:2=fail:"no test" --reason - <<'EOF')
    refute_one_argument(text, "HelpLive.Flow")
  end

  test "the shape check itself catches a paragraph and an example without its blank line" do
    assert [["Built.", "", "- one"]] = heredocs("x --evidence - <<'EOF'\nBuilt.\n\n- one\nEOF")

    assert_raise ExUnit.AssertionError, fn ->
      assert_shaped_examples("--reason - <<'EOF'\nbar 2: no test\n- a point\nEOF", 1, "t")
    end

    assert_raise ExUnit.AssertionError, fn ->
      assert_shaped_examples(
        "--evidence - <<'EOF'\nBuilt, tested, CI green, docs updated.\n\nand more prose\nEOF",
        1,
        "t"
      )
    end

    assert_raise ExUnit.AssertionError, fn ->
      refute_one_argument(~s(slipdock verify 12 reject --reason "bar 2: …"), "t")
    end
  end
end
