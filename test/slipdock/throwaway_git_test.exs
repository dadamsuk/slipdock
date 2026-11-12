defmodule Slipdock.ThrowawayGitTest do
  @moduledoc """
  The throwaway git repositories tests build (#2914): each in a directory of
  its own outside the checkout, and a repository whose `.git` has gone is no
  repository to git, rather than whatever repository is above it. A test's
  git found the checkout's `.git` once and renamed its branch (#2838).
  """
  use ExUnit.Case, async: true

  alias Slipdock.ThrowawayGit

  describe "tmp_dir!/1" do
    test "is a new empty directory under the system's temporary one, outside the checkout" do
      dir = ThrowawayGit.tmp_dir!("probe")

      assert File.dir?(dir)
      assert File.ls!(dir) == []
      assert String.starts_with?(dir, Path.expand(System.tmp_dir!()) <> "/")
      assert Path.basename(dir) =~ ~r/^slipdock-probe-[0-9a-f]{12}$/
      refute String.starts_with?(dir, File.cwd!() <> "/")
    end

    test "is a different directory every time" do
      dirs = for _ <- 1..20, do: ThrowawayGit.tmp_dir!("probe")
      assert Enum.uniq(dirs) == dirs
    end

    test "is removed when the test ends, whatever is in it" do
      # A label of its own, so the on_exit below can find the directory
      # (it runs in another process) and no other test's matches.
      label = "removed-" <> Integer.to_string(System.unique_integer([:positive]))
      pattern = Path.join(Path.expand(System.tmp_dir!()), "slipdock-#{label}-*")

      # Registered first, so it runs after tmp_dir!/1's own on_exit.
      on_exit(fn -> assert Path.wildcard(pattern) == [] end)

      dir = ThrowawayGit.tmp_dir!(label)
      File.mkdir_p!(Path.join(dir, "repo/.git"))
      File.write!(Path.join(dir, "repo/file"), "x")
      assert Path.wildcard(pattern) == [dir]
    end
  end

  describe "git/3" do
    test "runs git in the directory, its stderr in the output" do
      dir = ThrowawayGit.tmp_dir!()
      assert {_, 0} = ThrowawayGit.git(dir, ["init", "--quiet"])
      assert {".git\n", 0} = ThrowawayGit.git(dir, ["rev-parse", "--git-dir"])

      assert {out, status} = ThrowawayGit.git(dir, ["no-such-command"])
      assert status != 0
      assert out =~ "no-such-command"
    end

    test "a directory whose .git has gone is no repository, not the one above it" do
      outer = Path.join(ThrowawayGit.tmp_dir!(), "outer")
      inner = Path.join(outer, "inner")
      File.mkdir_p!(inner)
      assert {_, 0} = ThrowawayGit.git(outer, ["init", "--quiet", "--initial-branch=main"])
      {outer_top, 0} = ThrowawayGit.git(outer, ["rev-parse", "--show-toplevel"])

      # Below the ceiling, git walks up and finds the outer repository, as it
      # found the checkout's when a throwaway .git was removed under it...
      assert {^outer_top, 0} = ThrowawayGit.git(inner, ["rev-parse", "--show-toplevel"])

      # ...and with the ceiling at that repository, it doesn't look there.
      assert {out, 128} =
               ThrowawayGit.git(inner, ["branch", "-m", "trunk"], ceiling: outer)

      assert out =~ "not a git repository"
      assert {"main\n", 0} = ThrowawayGit.git(outer, ["symbolic-ref", "--short", "HEAD"])
    end

    test "adds :env to the ceiling, and the ceiling is the system's temporary directory" do
      dir = ThrowawayGit.tmp_dir!()

      assert {out, 0} =
               System.cmd("sh", ["-c", "echo $GIT_CEILING_DIRECTORIES $EXTRA"],
                 env: ThrowawayGit.env() ++ [{"EXTRA", "x"}],
                 cd: dir
               )

      assert out == "#{Path.expand(System.tmp_dir!())} x\n"

      assert {"yes\n", 0} =
               ThrowawayGit.git(dir, ["config", "--get", "x.y"],
                 env: [
                   {"GIT_CONFIG_COUNT", "1"},
                   {"GIT_CONFIG_KEY_0", "x.y"},
                   {"GIT_CONFIG_VALUE_0", "yes"}
                 ]
               )
    end
  end
end
