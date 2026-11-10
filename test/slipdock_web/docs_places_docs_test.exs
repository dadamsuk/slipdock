defmodule SlipdockWeb.DocsPlacesDocsTest do
  @moduledoc """
  How SPEC-10 is judged (#2694): the manual's Verified work page and the
  agents help's handbook part and the Flow page say it is checked by enumeration, give the
  four results, and say a deferral counts only when its card's bar names
  the place.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  @root Path.expand("../..", __DIR__)

  defp flat(text), do: String.replace(text, ~r/\s+/u, " ")

  test "the manual's Verified work page says how SPEC-10 is judged" do
    manual = @root |> Path.join("docs/manual/verified-work.md") |> File.read!() |> flat()

    assert manual =~ "**SPEC-10 is checked by enumeration, not judged.**"
    assert manual =~ "take the names the change introduces or alters from the diff"
    assert manual =~ "grep them across the seven places"

    assert manual =~
             "*updated*, *deferred to #N* (only when card #N's bar names that place), *n/a* with why, or *missing*"

    assert manual =~ "One missing is `--check rule:SPEC-10=broken:<file>:<name>`"
    assert manual =~ "a deferral to a card whose bar doesn't name the place counts as missing"
    assert manual =~ "list each place its lane can't reach on the deferral card's bar"
  end

  test "the agents help's handbook part says it", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/help/agents/skills")
    doc = LazyHTML.from_document(html)
    text = doc |> LazyHTML.query("#help-handbook-docs-places") |> LazyHTML.text() |> flat()

    assert text =~ "is checked by enumeration, not judged"
    assert text =~ "greps them across the seven places"

    assert text =~
             "updated, deferred to a card whose bar names that place, not applicable with why, or missing"

    assert text =~ "One missing is the rule broken"
    assert text =~ "a deferral whose bar doesn't list the place doesn't count"
  end

  test "the Flow help page's verifier says it", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/help/agents/flow")
    text = html |> LazyHTML.from_document() |> LazyHTML.text() |> flat()

    assert text =~ "(SPEC-10) is checked by enumeration"

    assert text =~
             "updated, deferred to a card whose bar names that place, not applicable with why, or missing, and one missing is the rule broken"
  end
end
