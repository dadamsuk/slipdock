defmodule Slipdock.VerifiedEveryInstanceFlowTest do
  @moduledoc """
  Help › How work flows says a rejection names every instance found (#2046):
  the verifying stage tells the reader that once a rule is broken, the
  verifier lists every instance of the same break under that one rule.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  @tag :anonymous
  test "the verifying stage says a rejection names every instance found", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/help/agents/flow")

    [verifying] =
      html
      |> LazyHTML.from_document()
      |> LazyHTML.query("#flow-verifying")
      |> Enum.map(&LazyHTML.text/1)

    text = String.replace(verifying, ~r/\s+/, " ")
    assert text =~ "A rejection names every instance found"
    assert text =~ "looks for every other instance of the same break"
    assert text =~ "each with its file and line"
  end
end
