defmodule Slipdock.GitignoreLinksTest do
  @moduledoc """
  A lane worktree can share the main checkout's `deps` and `_build` by
  symlinking them at its root (#2902). A `.gitignore` pattern ending in `/`
  matches only a directory, and git sees a symlink as a file, so `/deps/` left
  the link untracked in `git status` and `git add -A` would stage it. This
  copies the repository's `.gitignore` into a scratch repository and holds it
  to ignoring both, as links and as plain directories.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)
  @shared ["deps", "_build"]

  setup do
    dir = Path.join(System.tmp_dir!(), "gitignore-links-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {"", 0} = git(dir, ["init", "-q"])
    %{dir: dir}
  end

  # A git hook or a worktree can leave GIT_DIR and friends set, which would
  # point these commands at the real repository instead of the scratch one.
  defp git(dir, args) do
    env = for var <- ~w(GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE), do: {var, nil}
    System.cmd("git", args, cd: dir, env: env, stderr_to_stdout: true)
  end

  defp untracked(dir) do
    {out, 0} = git(dir, ["status", "--porcelain", "--untracked-files=all"])

    out
    |> String.split("\n", trim: true)
    |> Enum.map(&String.replace_prefix(&1, "?? ", ""))
  end

  defp link_shared(dir) do
    target = Path.join(dir, "elsewhere")

    for name <- @shared do
      File.mkdir_p!(Path.join([target, name, "lib"]))
      File.write!(Path.join([target, name, "lib", "file"]), "x")
      :ok = File.ln_s(Path.join(target, name), Path.join(dir, name))
    end

    # The links' targets sit inside the scratch repository; keep them out of
    # what is being checked.
    File.write!(Path.join(dir, ".git/info/exclude"), "/elsewhere/\n")
  end

  test "the repository's .gitignore ignores deps and _build symlinked at the root", %{dir: dir} do
    File.cp!(Path.join(@root, ".gitignore"), Path.join(dir, ".gitignore"))
    link_shared(dir)

    assert untracked(dir) == [".gitignore"]

    for name <- @shared do
      assert {_, 0} = git(dir, ["check-ignore", "-q", name]), "#{name} (a symlink) is not ignored"
    end
  end

  test "the repository's .gitignore still ignores deps and _build as directories", %{dir: dir} do
    File.cp!(Path.join(@root, ".gitignore"), Path.join(dir, ".gitignore"))

    for name <- @shared do
      File.mkdir_p!(Path.join(dir, name))
      File.write!(Path.join([dir, name, "file"]), "x")
    end

    assert untracked(dir) == [".gitignore"]
  end

  test "a pattern ending in / misses the links, so the check can tell", %{dir: dir} do
    File.write!(Path.join(dir, ".gitignore"), "/_build/\n/deps/\n")
    link_shared(dir)

    assert Enum.sort(untracked(dir)) == [".gitignore", "_build", "deps"]
  end
end
