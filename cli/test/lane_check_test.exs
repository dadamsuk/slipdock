defmodule SlipdockCLI.LaneCheckTest do
  @moduledoc """
  The lane-check hook (#1629): `slipdock hook install lane-check` and the
  `lane-check` it runs, against throwaway git repositories and a fake
  server — in-lane commits pass, out-of-lane ones are refused with the
  files listed, a card with no paths (or no card) passes, and a board that
  can't be reached warns and passes.
  """
  use ExUnit.Case, async: false

  alias SlipdockCLI.{FakeServer, Lanes}

  setup do
    home =
      Path.join(System.tmp_dir!(), "slipdock-lanecheck-#{System.unique_integer([:positive])}")

    File.mkdir_p!(home)
    # Resolved, as git reports paths: macOS's tmp dir is /var/folders/…, a
    # link to /private/var/folders/… (#1974).
    {real, 0} = System.cmd("pwd", ["-P"], cd: home)
    home = String.trim_trailing(real, "\n")
    repo = Path.join(home, "repo")
    File.mkdir_p!(repo)
    saved = Map.new(~w(HOME SLIPDOCK_URL SLIPDOCK_TOKEN KANBAN_TOKEN), &{&1, System.get_env(&1)})
    System.put_env("HOME", home)
    System.put_env("SLIPDOCK_TOKEN", "test-token")
    Enum.each(~w(SLIPDOCK_URL KANBAN_TOKEN), &System.delete_env/1)

    on_exit(fn ->
      Enum.each(saved, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)

      File.rm_rf!(home)
    end)

    git(repo, ["init", "-q", "-b", "main"])
    File.write!(Path.join(repo, "README"), "hi\n")
    git(repo, ["add", "README"])
    git(repo, ["commit", "-q", "-m", "first"])
    %{home: home, repo: repo}
  end

  defp git(dir, args, env \\ []) do
    System.cmd("git", ["-c", "user.name=t", "-c", "user.email=t@example.com" | args],
      cd: dir,
      env: env,
      stderr_to_stdout: true
    )
  end

  defp stage(repo, files) do
    for file <- files do
      path = Path.join(repo, file)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "x\n")
    end

    {_, 0} = git(repo, ["add" | files])
  end

  defp serve(responses), do: System.put_env("SLIPDOCK_URL", FakeServer.start(responses))

  defp card(paths), do: {200, JSON.encode!(%{"card" => %{"id" => 12, "paths" => paths}})}

  describe "matching" do
    test "globs cover files as the server reads them" do
      assert Lanes.covers?("lib/a/**", "lib/a/b/c.ex")
      assert Lanes.covers?("lib/a", "lib/a/b.ex")
      assert Lanes.covers?("lib/a/", "lib/a/b.ex")
      assert Lanes.covers?("./lib/a.ex", "lib/a.ex")
      refute Lanes.covers?("lib/a", "lib/ab.ex")
      assert Lanes.covers?("lib/*.ex", "lib/x.ex")
      refute Lanes.covers?("lib/*.ex", "lib/x/y.ex")
      refute Lanes.covers?("lib/*.ex", "lib/x.exs")
      assert Lanes.covers?("**/*_test.exs", "test/a/b_test.exs")
      assert Lanes.covers?("**/*_test.exs", "b_test.exs")
      assert Lanes.covers?("docs/{manual,agents}.md", "docs/agents.md")
      refute Lanes.covers?("docs/{manual,agents}.md", "docs/readme.md")
      assert Lanes.covers?("lib/[ab].ex", "lib/a.ex")
      refute Lanes.covers?("lib/[ab].ex", "lib/c.ex")
      assert Lanes.covers?("lib/[!ab].ex", "lib/c.ex")
      assert Lanes.covers?("lib/?.ex", "lib/a.ex")
      refute Lanes.covers?("lib/?.ex", "lib/ab.ex")
      # Regex characters in a glob are themselves.
      assert Lanes.covers?("a+b (1).txt", "a+b (1).txt")
      refute Lanes.covers?("a+b.txt", "aab.txt")
    end

    test "outside lists the files no glob covers, in order" do
      assert Lanes.outside(["lib/a.ex", "docs/x.md", "mix.exs"], ["lib/**", "docs/*.md"]) ==
               ["mix.exs"]
    end
  end

  test "the card comes from --card, then $SLIPDOCK_CARD, then a card-<id> branch" do
    assert Lanes.card_id("7", "8", "card-9") == "7"
    assert Lanes.card_id("#7", nil, nil) == "7"
    assert Lanes.card_id(nil, "8", "card-9") == "8"
    assert Lanes.card_id(nil, "", "card-9") == "9"
    assert Lanes.card_id(nil, nil, "lanes/card-9") == "9"
    assert Lanes.card_id(nil, "not-a-number", "main") == nil
    assert Lanes.card_id(nil, nil, "card-9-and-more") == nil
  end

  describe "install and uninstall" do
    test "writes an executable pre-commit hook, again happily, and removes it", ctx do
      assert {:ok, path} = Lanes.install(ctx.repo)
      assert path == Path.join(ctx.repo, ".git/hooks/pre-commit")
      assert File.read!(path) =~ "exec slipdock lane-check"
      assert Bitwise.band(File.stat!(path).mode, 0o111) != 0
      assert {:ok, ^path} = Lanes.install(ctx.repo)

      assert {:ok, ^path} = Lanes.uninstall(ctx.repo)
      refute File.exists?(path)
      assert {:error, "no pre-commit hook" <> _} = Lanes.uninstall(ctx.repo)
    end

    test "never replaces or removes somebody else's hook", ctx do
      path = Path.join(ctx.repo, ".git/hooks/pre-commit")
      File.write!(path, "#!/bin/sh\nmake lint\n")
      assert {:error, message} = Lanes.install(ctx.repo)
      assert message =~ "isn't the lane-check hook"
      assert {:error, _} = Lanes.uninstall(ctx.repo)
      assert File.read!(path) == "#!/bin/sh\nmake lint\n"
    end

    test "a worktree shares its repository's hook; outside a repository is refused", ctx do
      {_, 0} = git(ctx.repo, ["worktree", "add", "-q", "-b", "card-12", "../wt"])
      assert {:ok, path} = Lanes.install(Path.join(ctx.home, "wt"))
      assert path == Path.join(ctx.repo, ".git/hooks/pre-commit")

      plain = Path.join(ctx.home, "plain")
      File.mkdir_p!(plain)
      assert {:error, message} = Lanes.install(plain)
      assert message =~ "not in a git repository"
    end
  end

  describe "the check" do
    test "a commit inside the card's paths passes", ctx do
      serve([card(["lib/**", "docs/manual.md"])])
      stage(ctx.repo, ["lib/a.ex", "docs/manual.md"])
      assert Lanes.check(ctx.repo, "12", nil) == {:pass, nil}
      assert_received {:request, "GET", "/api/cards/12", _}
    end

    test "files outside them are refused, listed, with what to do", ctx do
      serve([card(["lib/**"])])
      stage(ctx.repo, ["lib/a.ex", "mix.exs", "test/a_test.exs"])
      assert {:refuse, message} = Lanes.check(ctx.repo, nil, "12")
      assert message =~ "card #12's paths are\n  lib/**"
      assert message =~ "  mix.exs\n  test/a_test.exs"
      refute message =~ "  lib/a.ex"
      assert message =~ "--no-verify"
    end

    test "a deleted or renamed file counts on both sides", ctx do
      stage(ctx.repo, ["other/old.ex"])
      {_, 0} = git(ctx.repo, ["commit", "-q", "-m", "old"])
      File.mkdir_p!(Path.join(ctx.repo, "lib"))
      {_, 0} = git(ctx.repo, ["mv", "other/old.ex", "lib/new.ex"])
      serve([card(["lib/**"])])
      # Moved into the lane: the file it came from was outside it.
      assert {:refuse, message} = Lanes.check(ctx.repo, "12", nil)
      assert message =~ "  other/old.ex"
      refute message =~ "  lib/new.ex"
    end

    test "a card with no paths, or no card at all, passes", ctx do
      serve([card([])])
      stage(ctx.repo, ["anything.txt"])
      assert Lanes.check(ctx.repo, "12", nil) == {:pass, nil}
      assert_received {:request, "GET", "/api/cards/12", _}

      # No card: nothing is asked of the board.
      assert Lanes.check(ctx.repo, nil, nil) == {:pass, nil}
      refute_received {:request, "GET", "/api/cards/" <> _, _}
    end

    test "the card is read from a card-<id> branch", ctx do
      {_, 0} = git(ctx.repo, ["switch", "-q", "-c", "card-12"])
      serve([card(["lib/**"])])
      stage(ctx.repo, ["mix.exs"])
      assert {:refuse, _} = Lanes.check(ctx.repo, nil, nil)
      assert_received {:request, "GET", "/api/cards/12", _}
    end

    test "a board it can't reach, or an error answer, warns and passes", ctx do
      {:ok, listen} = :gen_tcp.listen(0, [])
      {:ok, port} = :inet.port(listen)
      :gen_tcp.close(listen)
      System.put_env("SLIPDOCK_URL", "http://127.0.0.1:#{port}")
      stage(ctx.repo, ["mix.exs"])
      assert {:warn, message} = Lanes.check(ctx.repo, "12", nil)
      assert message =~ "couldn't read card #12's paths (board unreachable"

      serve([{404, ~s({"error":"not found"})}])
      assert {:warn, message} = Lanes.check(ctx.repo, "12", nil)
      assert message =~ "HTTP 404"
    end
  end

  describe "the installed hook under git commit" do
    # A stand-in `slipdock` on the PATH, exiting as told: the hook's own
    # wiring, without the network.
    defp fake_slipdock(ctx, exit_code) do
      bin = Path.join(ctx.home, "bin")
      File.mkdir_p!(bin)
      path = Path.join(bin, "slipdock")
      File.write!(path, "#!/bin/sh\necho \"fake $*\" >&2\nexit #{exit_code}\n")
      File.chmod!(path, 0o755)
      bin
    end

    defp commit(ctx, path) do
      git(ctx.repo, ["commit", "-q", "-m", "work"], [{"PATH", path}])
    end

    test "the commit goes ahead when lane-check passes and stops when it refuses", ctx do
      {:ok, _} = Lanes.install(ctx.repo)
      stage(ctx.repo, ["a.txt"])

      {out, code} = commit(ctx, fake_slipdock(ctx, 1) <> ":/usr/bin:/bin")
      assert code != 0
      assert out =~ "fake lane-check"

      {_, 0} = commit(ctx, fake_slipdock(ctx, 0) <> ":/usr/bin:/bin")
    end

    test "with no slipdock on the PATH it says so and lets the commit through", ctx do
      {:ok, _} = Lanes.install(ctx.repo)
      stage(ctx.repo, ["a.txt"])
      git_dir = Path.dirname(System.find_executable("git"))
      {out, 0} = commit(ctx, git_dir <> ":/bin")
      assert out =~ "slipdock is not on the PATH; commit allowed"
    end
  end
end
