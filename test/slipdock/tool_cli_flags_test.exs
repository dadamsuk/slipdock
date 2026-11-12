defmodule Slipdock.ToolCliFlagsTest do
  @moduledoc """
  Every `slipdock …` flag a Tool's recurring card tells an agent to use is
  one the CLI parses (#2779): a card whose procedure names a flag the CLI
  doesn't have fails every run (`unknown option(s)`). Read from the CLI's
  own switch list in `cli/lib/slipdock_cli.ex`, since the CLI is a project
  of its own.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)

  defp switches do
    source = File.read!(Path.join(@root, "cli/lib/slipdock_cli.ex"))
    [_, list] = Regex.run(~r/@switches \[(.*?)\n  \]/s, source)

    ~r/^\s*([a-z_]+): :/m
    |> Regex.scan(list)
    |> Enum.map(fn [_, name] -> String.replace(name, "_", "-") end)
    |> MapSet.new()
  end

  # The flags inside each `slipdock …` code span of a card's description,
  # and in each bare one that starts with a flag (`--column Triage …`,
  # what a procedure tells an agent to add to its own `slipdock add`).
  defp flags(text) do
    for [span] <- Regex.scan(~r/`(?:slipdock |--)[^`]*`/, text),
        [_, flag] <- Regex.scan(~r/(?:^`|\s)--([a-z][a-z-]*)/, span),
        uniq: true,
        do: flag
  end

  defp descriptions do
    [Slipdock.Sweep.blueprint(), Slipdock.Handbook.blueprint()]
    |> Enum.flat_map(& &1["cards"])
    |> Enum.map(&{&1["title"], &1["description"] || ""})
  end

  test "every flag a Tool's card names is a CLI switch" do
    known = switches()
    assert MapSet.member?(known, "column")

    for {title, text} <- descriptions(), flag <- flags(text) do
      assert MapSet.member?(known, flag),
             "“#{title}” names --#{flag}, which the CLI doesn't parse"
    end
  end

  test "a bare flag span counts, and a typo in one is caught" do
    assert flags("file it (`--column Triage --origin sweep`), tag it `--tag security`") ==
             ~w(column origin tag)

    assert flags("run `slipdock add B \"x\" --column Housekeeping`") == ~w(column)
    refute MapSet.member?(switches(), "orign")
  end

  test "the sweep and the triage card name the flags they file with" do
    named = descriptions() |> Enum.flat_map(fn {_, text} -> flags(text) end) |> MapSet.new()
    assert MapSet.subset?(MapSet.new(~w(column origin desc)), named)
  end
end
