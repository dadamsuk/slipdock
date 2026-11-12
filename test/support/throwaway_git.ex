defmodule Slipdock.ThrowawayGit do
  @moduledoc """
  Throwaway git repositories for tests, kept away from the checkout (#2914).

  ExUnit's `tmp_dir` is `tmp/<Module>/<test>/` inside the checkout, the same
  path in every run. Two runs in one checkout at once (`mix pre_push` beside
  `mix test --stale`) share it, and one run's cleanup can remove the other's
  `.git` between its `git init` and a later git command. Git then walks up
  from the throwaway directory into the real worktree and runs there: one
  such `git branch -m trunk` renamed the checkout's own branch (#2838).

  So a test that runs git takes its directory from `tmp_dir!/1` (unique to
  the test, under `System.tmp_dir!()`, removed when the test ends) and runs
  git with `env/0`, whose `GIT_CEILING_DIRECTORIES` stops git looking for a
  repository above the system temporary directory: a throwaway repository
  whose `.git` has gone is then no repository at all, rather than the
  checkout.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  @doc """
  A new, empty directory for this test alone, outside the checkout, removed
  when the test ends. Its name has random bytes in it: `System.unique_integer/1`
  starts again in every VM, so two runs at once would share it.
  """
  def tmp_dir!(label \\ "git") do
    random = Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
    dir = Path.join(System.tmp_dir!() |> Path.expand(), "slipdock-#{label}-#{random}")
    File.mkdir_p!(Path.dirname(dir))
    File.mkdir!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  @doc """
  The environment git runs with in a throwaway repository: it looks for a
  repository no higher than `ceiling`, the system temporary directory unless
  given.
  """
  def env(ceiling \\ System.tmp_dir!()),
    do: [{"GIT_CEILING_DIRECTORIES", Path.expand(ceiling)}]

  @doc """
  Runs git in `dir` with `env/1`, its stderr in the output. Options:
  `:ceiling` (for `env/1`) and `:env` (added to `env/1`'s); the rest go on
  to `System.cmd/3`.
  """
  def git(dir, args, opts \\ []) do
    {ceiling, opts} = Keyword.pop_lazy(opts, :ceiling, &System.tmp_dir!/0)
    {extra, opts} = Keyword.pop(opts, :env, [])

    System.cmd(
      "git",
      args,
      [cd: dir, env: env(ceiling) ++ extra, stderr_to_stdout: true] ++ opts
    )
  end
end
