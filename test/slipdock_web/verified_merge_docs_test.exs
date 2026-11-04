defmodule SlipdockWeb.VerifiedMergeDocsTest do
  @moduledoc """
  Where a merge goes (#1754), as the docs say it: a runner idle now first,
  else the one that accepted the card; a runner that can't merge in that
  repository hands it on, a bounded number of times.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)
  defp read(path), do: File.read!(Path.join(@root, path))

  test "the manual says where a merge goes and what a runner that can't merge does" do
    manual = read("docs/manual.md")
    assert manual =~ "It goes to a runner that can merge and is\nidle now"
    assert manual =~ "it\ngoes to the runner that accepted the card"
    assert manual =~ "**Merge handed on**"
    assert manual =~ "**Merge waiting**"
  end

  test "the agents page and the API guide say the same" do
    assert read("docs/agents.md") =~
             "The merge goes to a\nrunner that is idle now, else to the one that accepted the card"

    assert read("lib/slipdock_web/api_guide.ex") =~
             "queues a `merge` job for a runner (one idle now first, else the one\n    that accepted it)"
  end
end
