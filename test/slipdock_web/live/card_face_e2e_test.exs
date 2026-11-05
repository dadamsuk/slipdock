defmodule SlipdockWeb.CardFaceE2ETest do
  @moduledoc """
  The calmer card face's e2e run (#1706): `tools/e2e/card-face.sh` runs
  each subcard's browser script, every one of them is there and runnable,
  and each starts its own throwaway server through `lib.sh`.
  """
  use ExUnit.Case, async: true

  @e2e Path.expand("../../../tools/e2e", __DIR__)
  @scripts ~w(card-title card-chips priority-start list-chrome toolbar-one-row)

  defp read(name), do: File.read!(Path.join(@e2e, name))

  test "card-face.sh runs each subcard's script, in order" do
    runner = read("card-face.sh")
    assert runner =~ "for script in #{Enum.join(@scripts, " ")}; do"
    assert runner =~ ~s("$here/$script.sh")
    # It stops at the first script that fails rather than reporting ok.
    assert runner =~ ~r/^set -e$/m
  end

  test "each script is there, executable, and has its Playwright half" do
    for name <- ["card-face" | @scripts] do
      path = Path.join(@e2e, "#{name}.sh")
      assert File.exists?(path), "#{name}.sh is missing"
      %File.Stat{mode: mode} = File.stat!(path)
      assert Bitwise.band(mode, 0o111) != 0, "#{name}.sh is not executable"
    end

    for name <- @scripts do
      assert File.exists?(Path.join(@e2e, "#{name}.mjs")), "#{name}.mjs is missing"
      script = read("#{name}.sh")
      assert script =~ ~s[source "$(dirname "$0")/lib.sh"], "#{name}.sh doesn't use lib.sh"
      assert script =~ "e2e_start"
    end
  end
end
