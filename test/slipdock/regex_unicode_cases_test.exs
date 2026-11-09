defmodule Slipdock.RegexUnicodeCasesTest do
  @moduledoc """
  The regexes over card, comment and page text read whole characters (#2593).

  Without `u`, OTP 27 cut "josé" to `jos` and the first byte of the `é`, and
  OTP 28 and later to `jos`: these expect the whole name either way. With
  `u`, `\\d` matches any decimal digit, so a number the text names is still
  read as ASCII digits only: `٣` is never handed to `String.to_integer/1`.
  `Slipdock.RegexUnicodeTest` holds the source to the rule.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias Slipdock.Handbook.Rules
  alias Slipdock.{Mentions, Quality, QuickAdd}
  alias Slipdock.Wiki.{Markup, Page, Query}

  test "a mention is the whole name, accents and all" do
    assert Mentions.names("Over to @josé… and @Åsa, cc @anna.") == ["josé", "anna"]
    assert Enum.all?(Mentions.names("@renée-x @zoë"), &String.valid?/1)
    assert SlipdockWeb.RichText.mentions?("ask @josé")
  end

  test "the wiki reads a mention whole, and a card or page code only in ASCII digits" do
    refs = Markup.refs("@josé on #12 and W-31; not #١٢ or W-٣١, nor café#12")

    assert Enum.map(refs, & &1.raw) == ["@josé", "#12", "W-31"]
    assert Enum.all?(refs, &String.valid?(&1.raw))
  end

  test "the text around the references survives byte for byte" do
    text = "Ça va, @josé? Voir #7 — «W-2» et …"
    assert text |> Markup.tokens() |> Enum.map_join(&Markup.raw/1) == text
  end

  test "a query clause with a field in letters reads it whole, and its days only in ASCII" do
    assert {:ok, [%{"op" => "within_days", "value" => 3}]} = Query.parse_filters("due within 3d")
    # Read as a comparison on a field it doesn't know, never as ٣ days.
    refute match?({:ok, [%{"op" => "within_days"}]}, Query.parse_filters("due within ٣d"))

    refute match?(
             {:ok, [%{"op" => "older_than_days"}]},
             Query.parse_filters("age older than ٣٠ d")
           )
  end

  test "quick add reads a tag or a name with accents whole" do
    board = %{columns: [%{id: 1, name: "To Do"}], tags: [%{id: 10, name: "café"}]}

    users = [
      %Slipdock.Accounts.User{id: 5, name: "José Ruiz", email: "jose@example.com"}
    ]

    parsed = QuickAdd.parse("Order beans #café @josé", board, today: ~D[2026-09-26], users: users)

    assert parsed.title == "Order beans"
    assert parsed.tags == [%{id: 10, name: "café"}]
    assert parsed.attrs["assignee_id"] == 5
    assert parsed.unknown == []
  end

  test "quick add reads a date or a rule in ASCII digits, and leaves ٣ in the title" do
    today = ~D[2026-09-26]
    parsed = QuickAdd.parse("Ship it due: in ٣ days", %{columns: [], tags: []}, today: today)
    refute Map.has_key?(parsed.attrs, "due_date")
    assert parsed.title == "Ship it due: in ٣ days"

    parsed = QuickAdd.parse("Pay rent every: ٣ days", %{columns: [], tags: []}, today: today)
    assert parsed.recurrence == nil

    parsed = QuickAdd.parse("Pay rent every: 3 days", %{columns: [], tags: []}, today: today)
    assert parsed.recurrence == "FREQ=DAILY;INTERVAL=3"

    parsed = QuickAdd.parse("Ship it due: in 3 days", %{columns: [], tags: []}, today: today)
    assert parsed.attrs["due_date"] == "2026-09-29"
  end

  test "a rule's check may name a test file with an accent in its path" do
    body =
      "# Ops\n\n## Rules\n\n- **OPS-1** must · test/données_test.exs · Exports keep accents.\n"

    page = %Page{
      code: "W-2593",
      title: "Ops",
      body: body,
      front_matter: "---\nhandbook: operations\n---\n"
    }

    assert {[%{check: "test/données_test.exs"}], []} = Rules.parse_page(page)
  end

  test "an inline card field takes its card in ASCII digits, and ٣ is no card at all" do
    assert Query.inline("card: #٣.title", %{}) == :error
    assert Query.inline("card:٣٠.title", %{}) == :error
  end

  test "a broken check is counted as a rule only when its id ends in ASCII digits" do
    body = fn label -> "Rejected.\n\nChecks:\n- #{label}: broken — why\n" end

    assert Quality.rejection_parts(body.("OPS-3"), DateTime.utc_now(), nil) == [
             {"rules", "OPS-3"}
           ]

    assert Quality.rejection_parts(body.("OPS-٣"), DateTime.utc_now(), nil) == []
  end

  test "a sprint is shortened under its bar only when its number is in ASCII digits" do
    sprint = fn title ->
      %{title: title, committed: 2, completed: 1, finished: true}
    end

    html =
      render_component(&SlipdockWeb.SprintChartComponents.velocity_chart/1,
        velocity: %{sprints: [sprint.("Sprint 12"), sprint.("Sprint ٣")], average: nil}
      )

    assert html =~ "S12"
    refute html =~ "S٣"
    assert html =~ "Sprint ٣"
  end
end
