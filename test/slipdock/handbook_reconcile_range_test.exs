defmodule Slipdock.HandbookReconcileRangeTest do
  @moduledoc """
  The reconcile card's range on a history with merges (#2911). Its step 3
  used to name `<to>..<the 20th>` from a `git log` list, and with merges the
  20th line isn't a descendant of every line before it: the range held fewer
  commits than were read, and the next night listed the rest again. These
  run the command the card itself gives, on real repositories.
  """
  use ExUnit.Case, async: true

  alias Slipdock.Handbook

  @moduletag :tmp_dir

  defp description do
    Handbook.blueprint()["cards"]
    |> Enum.find(&(&1["title"] == Handbook.reconcile_title()))
    |> Map.fetch!("description")
  end

  # The command step 3 gives for `<end>`, as the card writes it.
  defp end_command(to) do
    [_, command] = Regex.run(~r/`(git rev-list --first-parent [^`]+)`/, description())

    command
    |> String.replace("<to>", to)
    |> String.replace("<default branch>", "main")
  end

  defp git(dir, args, at \\ nil) do
    env =
      if at do
        date = "2026-01-01T00:00:00Z" |> DateTime.from_iso8601() |> elem(1) |> DateTime.add(at)
        stamp = DateTime.to_iso8601(date)
        [{"GIT_AUTHOR_DATE", stamp}, {"GIT_COMMITTER_DATE", stamp}]
      else
        []
      end

    config = ~w(-c user.name=Test -c user.email=test@example.com -c commit.gpgsign=false)
    {out, 0} = System.cmd("git", config ++ args, cd: dir, env: env, stderr_to_stdout: true)
    String.trim(out)
  end

  defp lines(""), do: []
  defp lines(out), do: String.split(out, "\n")

  defp rev_list(dir, range), do: lines(git(dir, ["rev-list", range]))

  # A repository with one commit on `main`; the clock counts seconds from it.
  defp repo(dir) do
    git(dir, ["init", "-q", "-b", "main"])
    git(dir, ["commit", "-q", "--allow-empty", "-m", "base"], 0)
    {:ok, clock} = Agent.start_link(fn -> 0 end)
    %{dir: dir, clock: clock, base: git(dir, ["rev-parse", "HEAD"])}
  end

  defp tick(%{clock: clock}), do: Agent.get_and_update(clock, &{&1 + 60, &1 + 60})

  defp commit(repo, subject),
    do: git(repo.dir, ["commit", "-q", "--allow-empty", "-m", subject], tick(repo))

  # `count` commits on a branch of its own, forked from `from`.
  defp branch(repo, name, count, from) do
    git(repo.dir, ["checkout", "-q", "-b", name, from])
    for n <- 1..count, do: commit(repo, "#{name} #{n}")
    git(repo.dir, ["checkout", "-q", "main"])
  end

  defp merge(repo, name) do
    git(repo.dir, ["merge", "-q", "--no-ff", "-m", "Merge #{name}", name], tick(repo))
    git(repo.dir, ["rev-parse", "HEAD"])
  end

  # What the card calls origin/<default branch>: here, wherever `main` is.
  defp publish(repo), do: git(repo.dir, ["update-ref", "refs/remotes/origin/main", "main"])

  defp range_end(repo, to) do
    {out, 0} = System.cmd("sh", ["-c", end_command(to)], cd: repo.dir, stderr_to_stdout: true)
    String.trim(out)
  end

  # The range holds exactly the commits read, and the next night starts
  # after every one of them: nothing is read twice and nothing is skipped.
  defp assert_exact(repo, to, the_end) do
    read = lines(git(repo.dir, ["log", "--oneline", "--reverse", "#{to}..#{the_end}"]))
    count = String.to_integer(git(repo.dir, ["rev-list", "--count", "#{to}..#{the_end}"]))
    assert length(read) == count

    tonight = rev_list(repo.dir, "#{to}..#{the_end}")
    tomorrow = rev_list(repo.dir, "#{the_end}..origin/main")
    assert tonight -- tomorrow == tonight, "tomorrow's range repeats a commit read tonight"

    assert Enum.sort(tonight ++ tomorrow) == Enum.sort(rev_list(repo.dir, "#{to}..origin/main"))
    assert the_end in lines(git(repo.dir, ["rev-list", "--first-parent", "origin/main"]))
    count
  end

  # Eight cards' branches, two commits each, all forked from the base and
  # then merged one after another: each merge brings in three commits.
  defp merged_history(dir) do
    repo = repo(dir)
    for n <- 1..8, do: branch(repo, "card-#{n}", 2, repo.base)
    merges = for n <- 1..8, do: merge(repo, "card-#{n}")
    publish(repo)
    {repo, merges}
  end

  describe "the card's text" do
    test "ends the range on a first-parent commit, and counts it from the range" do
      text = description()
      assert text =~ "ending the range on a commit of the default branch's own line"
      assert text =~ "The range is `<to>..<end>`"
      assert text =~ "`git rev-list --count <to>..<end>` is how many"
      refute text =~ "<the 20th>"
      # Step 8 logs that range, not another.
      assert text =~ "where `<from>..<to>` is step 3's range, `<n>` its count"
      numbers = for [_, n] <- Regex.scan(~r/^(\d+)\. /m, text), do: n
      assert numbers == Enum.map(1..9, &to_string/1)
    end
  end

  describe "the range on a history with merges" do
    test "the old range, ending on the list's 20th line, holds fewer than the 20 read",
         %{tmp_dir: dir} do
      {repo, _} = merged_history(dir)

      listed =
        lines(git(repo.dir, ["log", "--format=%H", "--reverse", "#{repo.base}..origin/main"]))

      assert length(listed) == 24
      twentieth = Enum.at(listed, 19)

      held = rev_list(repo.dir, "#{repo.base}..#{twentieth}")
      assert length(held) < 20
      # And the next night lists some of the 20 again.
      again = rev_list(repo.dir, "#{twentieth}..origin/main")
      assert Enum.any?(Enum.take(listed, 20), &(&1 in again))
    end

    test "the card's command ends on the last merge whose range holds at most 20",
         %{tmp_dir: dir} do
      {repo, merges} = merged_history(dir)

      the_end = range_end(repo, repo.base)
      assert the_end == Enum.at(merges, 5)
      assert assert_exact(repo, repo.base, the_end) == 18

      # The next night carries on from there, to the tip.
      next = range_end(repo, the_end)
      assert next == List.last(merges)
      assert assert_exact(repo, the_end, next) == 6
      assert rev_list(repo.dir, "#{next}..origin/main") == []
    end

    test "a range of exactly 20 is taken whole", %{tmp_dir: dir} do
      repo = repo(dir)
      for n <- 1..6, do: branch(repo, "card-#{n}", 3, repo.base)
      merges = for n <- 1..6, do: merge(repo, "card-#{n}")
      publish(repo)

      the_end = range_end(repo, repo.base)
      assert the_end == Enum.at(merges, 4)
      assert assert_exact(repo, repo.base, the_end) == 20
    end

    test "one merge that brings in more than 20 is taken whole, never split",
         %{tmp_dir: dir} do
      repo = repo(dir)
      branch(repo, "big", 25, repo.base)
      big = merge(repo, "big")
      after_it = commit(repo, "after") && git(repo.dir, ["rev-parse", "HEAD"])
      publish(repo)

      the_end = range_end(repo, repo.base)
      assert the_end == big
      assert assert_exact(repo, repo.base, the_end) == 26
      assert range_end(repo, big) == after_it
    end

    test "a `<to>` off the default branch's own line, as an old Log line can hold",
         %{tmp_dir: dir} do
      {repo, merges} = merged_history(dir)
      # The tip of card-3's branch: merged, but not a first-parent commit.
      to = git(repo.dir, ["rev-parse", "card-3"])
      refute to in lines(git(repo.dir, ["rev-list", "--first-parent", "origin/main"]))

      the_end = range_end(repo, to)
      assert the_end in merges
      count = assert_exact(repo, to, the_end)
      assert count > 0 and count <= 20
    end
  end

  describe "the range on a history without merges" do
    test "is the 20th commit, then the rest", %{tmp_dir: dir} do
      repo = repo(dir)
      for n <- 1..30, do: commit(repo, "commit #{n}")
      publish(repo)

      the_end = range_end(repo, repo.base)
      assert the_end == git(repo.dir, ["rev-parse", "main~10"])
      assert assert_exact(repo, repo.base, the_end) == 20

      next = range_end(repo, the_end)
      assert next == git(repo.dir, ["rev-parse", "main"])
      assert assert_exact(repo, the_end, next) == 10
    end

    test "fewer than 20 waiting: the range ends at the tip", %{tmp_dir: dir} do
      repo = repo(dir)
      for n <- 1..3, do: commit(repo, "commit #{n}")
      publish(repo)

      the_end = range_end(repo, repo.base)
      assert the_end == git(repo.dir, ["rev-parse", "main"])
      assert assert_exact(repo, repo.base, the_end) == 3
    end

    test "nothing new: no end at all", %{tmp_dir: dir} do
      repo = repo(dir)
      publish(repo)
      assert range_end(repo, repo.base) == ""
    end
  end
end
