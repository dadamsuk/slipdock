defmodule SlipdockWeb.PulseStripDocsTest do
  @moduledoc """
  Where the board's header lines lead, as the README and the Right now
  page's moduledoc say (#2598): since #2124 the pulse strip opens Right now
  on a board with Agentic Building on and Visualise otherwise, and the
  delivery line (the rocket) opens Visualise. The board page's own tests
  (`pulse_live_test.exs`, `now_test.exs`) hold the links themselves.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)
  defp read(path), do: Slipdock.DocsText.read!(Path.join(@root, path))

  defp pulse_item do
    [_, item] = String.split(read("README.md"), "\n- **A board's pulse** — ", parts: 2)
    [item | _] = String.split(item, "\n- ", parts: 2)
    String.replace(item, ~r/\s+/, " ")
  end

  test "the README's pulse line says the strip opens Right now with Agentic Building on" do
    item = pulse_item()

    assert item =~
             "which opens *Right now* when clicked on a board with Agentic Building on, " <>
               "and *Visualise* otherwise."

    refute item =~ "which opens *Visualise* when clicked."
  end

  test "the Right now page's moduledoc names the pulse strip as its link, not the delivery line" do
    {:docs_v1, _, _, _, %{"en" => doc}, _, _} = Code.fetch_docs(SlipdockWeb.NowLive.Index)
    doc = String.replace(doc, ~r/\s+/, " ")

    assert doc =~ "the pulse strip (the first line over the lists) links here"
    assert doc =~ "The delivery line (the rocket) opens the Visualise view, not this page."
    refute doc =~ "the delivery line (the rocket) links here"
  end
end
