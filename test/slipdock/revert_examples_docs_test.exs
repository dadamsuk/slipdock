defmodule Slipdock.RevertExamplesDocsTest do
  @moduledoc """
  `revert_page` takes `revision` and a required `base_hash` (#3188), and
  REST refuses the old `revision_id`. Every revert example in the skills
  and the API guide has to send what REST takes.
  """
  use ExUnit.Case, async: true

  # The rejection of #3188: a skill still sent the old `revision_id`, which
  # REST now refuses. Every revert example in the skills and the API guide
  # sends `revision` and `base_hash`.
  test "the skills' and the guide's revert examples send revision and base_hash" do
    examples =
      (Path.wildcard("priv/skills/**/*.md") ++ Path.wildcard("lib/slipdock_web/api_guide/*.md"))
      |> Enum.flat_map(fn path ->
        path
        |> File.read!()
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.filter(fn {line, _} -> line =~ ~r{/revert\b.*-d } end)
        |> Enum.map(fn {line, n} -> {"#{path}:#{n}", line} end)
      end)

    assert examples != []

    for {where, line} <- examples do
      refute line =~ "revision_id", "#{where} sends revision_id, which REST refuses"
      assert line =~ ~s("revision"), "#{where} doesn't send revision"
      assert line =~ "base_hash", "#{where} doesn't send base_hash"
    end
  end
end
