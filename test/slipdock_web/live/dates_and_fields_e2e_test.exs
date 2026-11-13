defmodule SlipdockWeb.DatesAndFieldsE2ETest do
  @moduledoc """
  The "Dates and fields" e2e run (#1718, #2756): `tools/e2e/dates-and-fields.sh`
  runs each subcard's browser script in turn, and every script it names is
  there, executable, and has its Playwright `.mjs` beside it. CI runs no e2e
  script, so a renamed or dropped one would otherwise break the run unseen.
  """
  use ExUnit.Case, async: true

  @e2e Path.expand("../../../tools/e2e", __DIR__)
  @scripts ~w(date-field date-sweep file-picker card-back-fields)

  # The names in the runner's `for check in …; do` line, in order.
  defp runner_scripts(runner) do
    case Regex.run(~r/^for check in ([^;\n]+); do$/m, runner) do
      [_, names] -> String.split(names)
      nil -> flunk("dates-and-fields.sh has no `for check in …; do` line")
    end
  end

  # What is wrong with each named script in `dir`: missing, not executable,
  # or without its `.mjs`.
  defp problems(dir, names) do
    Enum.flat_map(names, fn name ->
      sh = Path.join(dir, "#{name}.sh")

      sh_problems =
        case File.stat(sh) do
          {:ok, %File.Stat{mode: mode}} when Bitwise.band(mode, 0o111) != 0 -> []
          {:ok, _} -> ["#{name}.sh is not executable"]
          {:error, _} -> ["#{name}.sh is missing"]
        end

      mjs =
        if File.exists?(Path.join(dir, "#{name}.mjs")), do: [], else: ["#{name}.mjs is missing"]

      sh_problems ++ mjs
    end)
  end

  test "dates-and-fields.sh runs the four scripts, in order, from tools/e2e" do
    runner = File.read!(Path.join(@e2e, "dates-and-fields.sh"))
    assert runner_scripts(runner) == @scripts
    assert runner =~ "tools/e2e/$check.sh"
  end

  test "every script the runner names is there, executable, with its .mjs" do
    names = runner_scripts(File.read!(Path.join(@e2e, "dates-and-fields.sh")))
    %File.Stat{mode: mode} = File.stat!(Path.join(@e2e, "dates-and-fields.sh"))
    assert Bitwise.band(mode, 0o111) != 0, "dates-and-fields.sh is not executable"
    assert problems(@e2e, names) == []

    for name <- names do
      script = File.read!(Path.join(@e2e, "#{name}.sh"))
      assert script =~ ~s[source "$(dirname "$0")/lib.sh"], "#{name}.sh doesn't use lib.sh"
      assert script =~ "e2e_start"
    end
  end

  @tag :tmp_dir
  test "a missing, non-executable or .mjs-less script is reported", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "ok.sh"), "")
    File.chmod!(Path.join(dir, "ok.sh"), 0o755)
    File.write!(Path.join(dir, "ok.mjs"), "")

    File.write!(Path.join(dir, "plain.sh"), "")
    File.chmod!(Path.join(dir, "plain.sh"), 0o644)
    File.write!(Path.join(dir, "plain.mjs"), "")

    File.write!(Path.join(dir, "half.sh"), "")
    File.chmod!(Path.join(dir, "half.sh"), 0o755)

    File.write!(Path.join(dir, "gone.mjs"), "")

    assert problems(dir, ~w(ok plain half gone)) == [
             "plain.sh is not executable",
             "half.mjs is missing",
             "gone.sh is missing"
           ]
  end

  test "a runner without its script loop is refused, not read as no scripts" do
    assert_raise ExUnit.AssertionError, ~r/no `for check in/, fn ->
      runner_scripts("#!/usr/bin/env bash\necho nothing\n")
    end
  end
end
