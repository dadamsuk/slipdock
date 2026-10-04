defmodule SlipdockCLI.ContainedTest do
  @moduledoc """
  `page export` and `skills install` write files the server names. The names
  must not choose where on this machine they land.
  """
  use ExUnit.Case, async: true

  @dir "/tmp/wiki"

  test "a plain relative path lands under the folder" do
    assert {:ok, "/tmp/wiki/Deploys/Rollback.md"} =
             SlipdockCLI.contained(@dir, "Deploys/Rollback.md")
  end

  test "'..' that stays inside is still inside" do
    assert {:ok, "/tmp/wiki/b.md"} = SlipdockCLI.contained(@dir, "a/../b.md")
  end

  test "climbing out is refused" do
    assert :error = SlipdockCLI.contained(@dir, "../../.claude/CLAUDE.md")
    assert :error = SlipdockCLI.contained(@dir, "a/../../b.md")
    assert :error = SlipdockCLI.contained(@dir, "..")
  end

  test "a sibling that shares the prefix is outside" do
    assert :error = SlipdockCLI.contained(@dir, "../wiki-other/x.md")
  end

  test "an absolute path is refused" do
    assert :error = SlipdockCLI.contained(@dir, "/etc/passwd")
  end

  test "the folder itself is not a file inside it" do
    assert :error = SlipdockCLI.contained(@dir, ".")
    assert :error = SlipdockCLI.contained(@dir, "")
  end
end
