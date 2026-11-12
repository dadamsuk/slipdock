defmodule Slipdock.MigrationOrderTest do
  @moduledoc """
  DATA-14: a migration a branch adds has a version later than the newest on
  main (#2090). Ecto runs migrations in version order, and production has
  already run main's, so one older than main's newest is skipped there or
  runs out of order. It keeps being missed by judgement: a version written by
  hand at a round time that another card took the same day, and a rebase that
  brought in a newer migration from main (#2068).

  The branch's migrations are the ones added since where it left `origin/main`
  (or local `main` when there is no origin), counting staged, unstaged and
  untracked files, so `mix pre_push` catches one before it is committed.
  Main's newest is read off `origin/main` (or `main`) itself, not the merge
  base, so a newer one that main gained after the branch left it counts too.
  With neither ref (a shallow checkout) there is nothing to compare, and the
  check passes; so too when the ref shares no history with HEAD that the
  checkout has: a self-hosted runner keeps one job's full `origin/main` in
  the workspace the next job checks out shallowly (#2829).

  The fix it asks for: `mix ecto.gen.migration` again, or rename the file to a
  version later than main's newest (W-1950 §Tests, Migration versions).
  """
  use ExUnit.Case, async: true

  alias Slipdock.ThrowawayGit

  @migrations "priv/repo/migrations"

  describe "this checkout" do
    test "every migration the branch adds is newer than main's newest" do
      assert :ok == check_repo(File.cwd!())
    end
  end

  describe "check/2" do
    test "no new migration passes" do
      assert :ok == check(["20261108125537"], [])
    end

    test "a migration newer than main's newest passes" do
      assert :ok ==
               check(["20261001000000", "20261108125537"], [
                 "#{@migrations}/20261108130000_add_x.exs"
               ])
    end

    test "one older than main's newest fails, naming the file and main's newest" do
      assert {:error, message} =
               check(["20261108125537"], ["#{@migrations}/20261108120000_add_x.exs"])

      assert message =~ "#{@migrations}/20261108120000_add_x.exs"
      assert message =~ "20261108125537"
      assert message =~ "mix ecto.gen.migration"
    end

    test "one the same version as main's newest fails" do
      assert {:error, message} =
               check(["20261108125537"], ["#{@migrations}/20261108125537_add_y.exs"])

      assert message =~ "20261108125537_add_y.exs"
    end

    test "names every one that is too old, and only those" do
      assert {:error, message} =
               check(["20261108125537"], [
                 "#{@migrations}/20261108120000_a.exs",
                 "#{@migrations}/20261108130000_b.exs",
                 "#{@migrations}/20261107000000_c.exs"
               ])

      assert message =~ "20261108120000_a.exs"
      assert message =~ "20261107000000_c.exs"
      refute message =~ "20261108130000_b.exs"
    end

    test "main with no migrations at all passes anything" do
      assert :ok == check([], ["#{@migrations}/20200101000000_first.exs"])
    end
  end

  describe "check_repo/1, on a real git repository" do
    # Outside the checkout, so a run beside this one can't remove a
    # repository's .git and leave its git to find the checkout's (#2914).
    setup do
      %{tmp: ThrowawayGit.tmp_dir!("migration-order")}
    end

    test "a branch with no new migration passes", %{tmp: tmp} do
      work = clone_with_main(tmp, ["20261108125537_main.exs"])
      git!(work, ["switch", "-c", "card-1"])
      File.write!(Path.join(work, "README.md"), "a change that is not a migration\n")
      commit!(work, "no migration")

      assert :ok == check_repo(work)
    end

    test "a branch whose migration is newer passes", %{tmp: tmp} do
      work = clone_with_main(tmp, ["20261108125537_main.exs"])
      git!(work, ["switch", "-c", "card-1"])
      add_migration!(work, "20261108130000_newer.exs")
      commit!(work, "newer")

      assert :ok == check_repo(work)
    end

    test "a branch whose migration is older fails, naming it and main's newest", %{tmp: tmp} do
      work = clone_with_main(tmp, ["20261108125537_main.exs"])
      git!(work, ["switch", "-c", "card-1"])
      add_migration!(work, "20261108120000_older.exs")
      commit!(work, "older")

      assert {:error, message} = check_repo(work)
      assert message =~ "#{@migrations}/20261108120000_older.exs"
      assert message =~ "20261108125537"
    end

    test "an older migration not yet committed fails too", %{tmp: tmp} do
      work = clone_with_main(tmp, ["20261108125537_main.exs"])
      git!(work, ["switch", "-c", "card-1"])
      add_migration!(work, "20261108120000_untracked.exs")

      assert {:error, message} = check_repo(work)
      assert message =~ "20261108120000_untracked.exs"
    end

    test "main's migrations themselves don't count as the branch's", %{tmp: tmp} do
      work = clone_with_main(tmp, ["20261001000000_old.exs", "20261108125537_main.exs"])

      assert :ok == check_repo(work)
    end

    test "a newer migration main gained after the branch left it fails the branch (#2068)",
         %{tmp: tmp} do
      work = clone_with_main(tmp, ["20261108125537_main.exs"])
      git!(work, ["switch", "-c", "card-1"])
      add_migration!(work, "20261108130000_mine.exs")
      commit!(work, "mine")
      assert :ok == check_repo(work)

      upstream = Path.join(tmp, "upstream")
      add_migration!(upstream, "20261108140000_theirs.exs")
      commit!(upstream, "theirs")
      git!(work, ["fetch", "origin"])

      assert {:error, message} = check_repo(work)
      assert message =~ "20261108130000_mine.exs"
      assert message =~ "20261108140000"
    end

    test "with no origin, it compares against local main", %{tmp: tmp} do
      repo = init_repo!(Path.join(tmp, "solo"), ["20261108125537_main.exs"])
      git!(repo, ["switch", "-c", "card-1"])
      add_migration!(repo, "20261108120000_older.exs")
      commit!(repo, "older")

      assert {:error, message} = check_repo(repo)
      assert message =~ "20261108120000_older.exs"
      assert message =~ "main's newest is 20261108125537"
    end

    test "with a main that shares no history with HEAD, there is nothing to compare",
         %{tmp: tmp} do
      repo = init_repo!(Path.join(tmp, "apart"), ["20261108125537_main.exs"])
      git!(repo, ["checkout", "--quiet", "--orphan", "branch"])
      git!(repo, ["rm", "-r", "--quiet", "--cached", "."])
      add_migration!(repo, "20261108120000_older.exs")
      commit!(repo, "branch")

      # The same migration with main's history joined up fails (above), so
      # this passes only because there is no merge base.
      assert {_, 1} = ThrowawayGit.git(repo, ["merge-base", "main", "HEAD"])
      assert :ok == check_repo(repo)
    end

    test "with neither origin/main nor main, there is nothing to compare", %{tmp: tmp} do
      repo = init_repo!(Path.join(tmp, "solo"), ["20261108125537_main.exs"])
      git!(repo, ["branch", "-m", "trunk"])
      add_migration!(repo, "20261108120000_older.exs")

      assert :ok == check_repo(repo)
    end
  end

  # The check

  @doc false
  def check_repo(root) do
    case main_ref(root) do
      nil ->
        :ok

      ref ->
        case git(root, ["merge-base", ref, "HEAD"]) do
          {base, 0} -> check(main_versions(root, ref), added_migrations(root, String.trim(base)))
          {_, _} -> :ok
        end
    end
  end

  @doc false
  def check(main_versions, added_files) do
    newest = Enum.max(main_versions, fn -> nil end)

    case Enum.reject(added_files, &(newest == nil or version(&1) > newest)) do
      [] ->
        :ok

      too_old ->
        {:error,
         """
         DATA-14: a migration the branch adds is not later than the newest on main; \
         main's newest is #{newest}.

         #{Enum.map_join(too_old, "\n", &"  #{&1}")}

         Generate it again with `mix ecto.gen.migration` (or rename it to a version \
         later than #{newest}), and drop its row in schema_migrations if you ran it \
         (W-1950 §Tests, Migration versions).
         """}
    end
  end

  defp main_ref(root) do
    Enum.find(["origin/main", "main"], fn ref ->
      match?({_, 0}, git(root, ["rev-parse", "--verify", "--quiet", ref <> "^{commit}"]))
    end)
  end

  defp main_versions(root, ref) do
    {out, 0} = git(root, ["ls-tree", "--name-only", ref, @migrations <> "/"])
    out |> lines() |> Enum.map(&version/1)
  end

  # Added since the merge base: committed, staged or unstaged, then untracked.
  defp added_migrations(root, base) do
    {changed, 0} = git(root, ["diff", "--name-only", "--diff-filter=A", base, "--", @migrations])

    {untracked, 0} =
      git(root, ["ls-files", "--others", "--exclude-standard", "--", @migrations])

    (lines(changed) ++ lines(untracked))
    |> Enum.filter(&String.ends_with?(&1, ".exs"))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp version(path), do: path |> Path.basename() |> String.split("_", parts: 2) |> hd()

  defp lines(out), do: String.split(out, "\n", trim: true)

  # No higher than the system temporary directory: a throwaway repository
  # whose .git has gone is no repository, rather than the checkout (#2914).
  # The checkout itself has its .git at its root, so it is found there.
  defp git(root, args), do: ThrowawayGit.git(root, args)

  # Throwaway repositories

  defp clone_with_main(tmp, migrations) do
    upstream = init_repo!(Path.join(tmp, "upstream"), migrations)
    work = Path.join(tmp, "work")
    {_, 0} = ThrowawayGit.git(tmp, ["clone", "--quiet", upstream, work])
    work
  end

  defp init_repo!(dir, migrations) do
    File.mkdir_p!(dir)
    git!(dir, ["init", "--quiet", "--initial-branch=main"])
    File.write!(Path.join(dir, "README.md"), "a repository\n")
    Enum.each(migrations, &add_migration!(dir, &1))
    commit!(dir, "main")
    dir
  end

  defp add_migration!(dir, name) do
    path = Path.join([dir, @migrations, name])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "# a migration\n")
  end

  defp commit!(dir, message) do
    git!(dir, ["add", "--all"])

    git!(dir, [
      "-c",
      "user.name=Test",
      "-c",
      "user.email=test@example.com",
      "-c",
      "commit.gpgsign=false",
      "commit",
      "--quiet",
      "-m",
      message
    ])
  end

  defp git!(dir, args) do
    {out, status} = git(dir, args)
    assert status == 0, "git #{Enum.join(args, " ")} failed: #{out}"
    out
  end
end
