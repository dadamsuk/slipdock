defmodule Slipdock.VerifyReportedSymptomTest do
  @moduledoc """
  The verifier's ask on a bug is the reported symptom (#1927): its prompt,
  and an audit's, reject a card whose symptom or cause was never seen,
  however good the tests, and the How work flows page says so.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.Verified

  @line "On a bug, the ask is the reported symptom, so the check is would the reporter now see it fixed, not does the work meet the bar"

  setup %{user: user} do
    board = board_fixture(%{"name" => "Checks", "code" => unique_code()}, owner: user)
    doing = Enum.find(board.columns, &(&1.category == "doing"))
    card = card_fixture(doing, %{"title" => "Settings half off the page on a phone"})
    %{board: board, card: card}
  end

  test "the verify prompt's ask step rejects a symptom never seen", %{board: board, card: card} do
    prompt = Verified.verify_prompt(card, board)
    [ask] = Regex.run(~r/^\d+\. The ask\..*$/m, prompt)

    assert ask =~ @line
    assert ask =~ "says the reported symptom or its cause was never seen"

    assert ask =~
             ~s(\("I couldn't tell what…", a cause made up in the test, a repro built until something failed\))

    assert ask =~
             "is a rejection (`the ask: the reported symptom was never seen`), however good the tests."

    # Still the ask step, before the bar: the reporter's view is judged first.
    assert ask =~ "Step: `judging the ask`"
    assert :binary.match(prompt, @line) < :binary.match(prompt, "The bar. Each item")
  end

  test "an audit judges the ask the same way", %{board: board, card: card} do
    assert Verified.audit_prompt(card, board) =~ @line
  end

  test "Help › How work flows says it in the verifying stage", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/help/agents/flow")

    text =
      html
      |> LazyHTML.from_document()
      |> LazyHTML.query("#flow-verifying")
      |> LazyHTML.text()
      |> String.replace(~r/\s+/u, " ")

    assert text =~
             "On a bug, the ask is the reported symptom: the check is would the reporter now see it fixed"

    assert text =~ "never conditions built until something fails"
    assert text =~ "says the reported symptom or its cause was never seen, however good the tests"
  end
end
