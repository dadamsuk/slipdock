defmodule Slipdock.RepoChecksTest do
  @moduledoc """
  `test/repo_checks.txt` (#1867): the tests that hold the repository's own
  files, docs and skills to a rule or to the server, which `mix pre_push`
  runs. This keeps the list honest: a test file that reads `docs/` or
  `priv/skills/`, wildcards over `lib/` or `test/`, or reads the compiler's
  cross-reference graph (`mix xref`), is either on the list or among its
  exceptions, each with its reason.

  It also keeps the skills to one source (#2048): no test reads an installed
  copy of a skill (`~/.claude/skills/`), only the packaged one in
  `priv/skills/`. A runner installs the server's skills before each job, so
  a copy on one machine is never a second thing for the checks to hold.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)
  @list_file Path.join(@root, "test/repo_checks.txt")

  # The ones the card that made the list named: each failed a pull request's
  # first CI run because the builder hadn't run it. The boundaries test
  # (#1963) did the same on four cards: a context calling SlipdockWeb.
  @required ~w(
    test/slipdock_web/fonts_test.exs
    test/slipdock_web/controllers/api/skills_test.exs
    test/slipdock/tool_packages_doc_test.exs
    test/slipdock/fixtures_test.exs
    test/slipdock/nothing_personal_test.exs
    test/slipdock/boundaries_test.exs
  )

  defp parsed, do: Mix.Project.get!().parse_repo_checks(File.read!(@list_file))
  defp listed, do: parsed().tests
  defp exceptions, do: parsed().exceptions

  defp test_files do
    @root
    |> Path.join("test/**/*_test.exs")
    |> Path.wildcard()
    |> Enum.map(&Path.relative_to(&1, @root))
    |> Enum.sort()
  end

  @doc false
  # Why a test file's source looks like a check on the repo itself, or [].
  def reasons(source, exists? \\ &File.regular?(Path.join(@root, &1))) do
    docs = for [doc] <- Regex.scan(~r{\bdocs/[\w.\-/]+\.\w+}, source), exists?.(doc), do: doc

    [
      docs != [] && "reads #{Enum.uniq(docs) |> Enum.join(", ")}",
      source =~ ~r{priv/skills|"priv",\s*"skills"} && "reads priv/skills/",
      (source =~ "Path.wildcard" and source =~ ~r{"(\.\./)*(lib|test)(/[^"]*)?"}) &&
        "wildcards over lib/ or test/",
      source =~ ~r{\[\s*"xref"} && "reads mix xref"
    ]
    |> Enum.filter(& &1)
  end

  @doc false
  # Why a test file's source reads this machine's installed skills, or nil:
  # the home directory's `.claude`, by `~` or by `System.user_home`. A
  # `.claude` under a temporary HOME the test made is not that.
  def installed_read(source) do
    cond do
      source =~ ~r{Path\.expand\(\s*"~/\.claude} ->
        "expands ~/.claude"

      source =~ ~r{System\.user_home} and source =~ ".claude" ->
        "joins System.user_home and .claude"

      true ->
        nil
    end
  end

  defp flagged do
    for path <- test_files(),
        path != "test/slipdock/repo_checks_test.exs",
        why = reasons(File.read!(Path.join(@root, path))),
        why != [],
        into: %{},
        do: {path, why}
  end

  describe "the list" do
    test "names the tests the card asked for" do
      for path <- @required, do: assert(path in listed(), "#{path} isn't in repo_checks.txt")
    end

    test "names test files that exist, once each" do
      for path <- listed() ++ Map.keys(exceptions()) do
        assert File.regular?(Path.join(@root, path)), "repo_checks.txt names #{path}, not a file"
        assert String.ends_with?(path, "_test.exs"), "#{path} isn't a test file"
      end

      all = listed() ++ Map.keys(exceptions())
      assert all -- Enum.uniq(all) == [], "repo_checks.txt names a file twice"
    end

    test "gives each exception its reason" do
      for {path, reason} <- exceptions() do
        assert String.length(reason) >= 10, "#{path}: say why it isn't on the list"
      end
    end

    test "every test file that reads docs or skills, or wildcards over the code, is on it" do
      missing =
        for {path, why} <- flagged(),
            path not in listed(),
            not Map.has_key?(exceptions(), path),
            do: "#{path} (#{Enum.join(why, "; ")})"

      assert missing == [], """
      These test files look like checks on the repository itself. Add each to
      test/repo_checks.txt, so `mix pre_push` runs it, or add it there as
      `except <path>: <why it isn't one>` (W-1950 §Tests):

      #{Enum.join(missing, "\n")}
      """
    end

    test "has no stale exception: each still reads docs, skills or the code" do
      stale = Map.keys(exceptions()) -- Map.keys(flagged())
      assert stale == [], "No longer needed in repo_checks.txt: #{Enum.join(stale, ", ")}"
    end
  end

  describe "one source for each skill (#2048)" do
    test "no test reads the installed copies under ~/.claude/skills" do
      reading =
        for path <- test_files(),
            path != "test/slipdock/repo_checks_test.exs",
            why = installed_read(File.read!(Path.join(@root, path))),
            do: "#{path} (#{why})"

      assert reading == [], """
      These tests read this machine's installed skills. The one source is
      priv/skills/ (W-1950 §Tests, #2048): read the packaged copy instead.

      #{Enum.join(reading, "\n")}
      """
    end

    test "an installed copy read by ~ or by the home directory is caught" do
      assert installed_read(~S|Path.expand("~/.claude/skills/slipdock/SKILL.md")|) ==
               "expands ~/.claude"

      assert installed_read(~S|@installed Path.expand( "~/.claude/skills")|) ==
               "expands ~/.claude"

      assert installed_read(~S|Path.join([System.user_home!(), ".claude", "skills"])|) ==
               "joins System.user_home and .claude"
    end

    test "the packaged copy, or a .claude under a temporary HOME, is not" do
      assert installed_read(~S|Path.join(@root, "priv/skills/slipdock/SKILL.md")|) == nil
      assert installed_read(~S|File.cp_r!(skills, Path.join([home, ".claude", "skills"]))|) == nil
      assert installed_read(~S|System.user_home!() <> "/notes"|) == nil
      assert installed_read(~S|Path.expand("~/notes")|) == nil
    end
  end

  describe "parse_repo_checks/1" do
    test "reads paths and exceptions, and skips comments and blank lines" do
      text = """
      # The header.

      test/a_test.exs
        test/b_test.exs
      except test/c_test.exs: lane globs as data
      # except test/d_test.exs: commented out
      """

      assert Mix.Project.get!().parse_repo_checks(text) == %{
               tests: ["test/a_test.exs", "test/b_test.exs"],
               exceptions: %{"test/c_test.exs" => "lane globs as data"}
             }
    end

    test "an exception without a reason has an empty one, which the list test refuses" do
      assert %{exceptions: %{"test/c_test.exs" => ""}} =
               Mix.Project.get!().parse_repo_checks("except test/c_test.exs")
    end
  end

  describe "reasons/2" do
    defp exists?(path), do: path in ["docs/manual.md", "docs/agents.md"]

    test "a docs file that exists is read; one that doesn't is a lane path as data" do
      assert reasons(~S|File.read!("docs/manual.md")|, &exists?/1) == ["reads docs/manual.md"]
      assert reasons(~S|paths: ["docs/x.md", "docs/{a,b}.md"]|, &exists?/1) == []
    end

    test "names each docs file once" do
      source = ~S|read("docs/manual.md") <> read("docs/agents.md") <> read("docs/manual.md")|
      assert reasons(source, &exists?/1) == ["reads docs/manual.md, docs/agents.md"]
    end

    test "priv/skills, written either way" do
      assert reasons(~S|read("priv/skills/slipdock/SKILL.md")|, &exists?/1) ==
               ["reads priv/skills/"]

      assert reasons(~S|Path.join([@root, "priv", "skills", s])|, &exists?/1) ==
               ["reads priv/skills/"]
    end

    test "a wildcard over lib/ or test/, but not a lib/ glob held as data" do
      assert reasons(~S|Path.wildcard("lib/**/*.ex")|, &exists?/1) ==
               ["wildcards over lib/ or test/"]

      assert reasons(
               ~S|@root "lib/slipdock_web" ... Path.wildcard(Path.join(@root, "**"))|,
               &exists?/1
             ) ==
               ["wildcards over lib/ or test/"]

      assert reasons(~S|Path.wildcard(Path.join(dir, "*.bak.*"))|, &exists?/1) == []
      assert reasons(~S|card(column, "A", "lib/**")|, &exists?/1) == []
    end

    test "running mix xref, but not the word xref in prose" do
      assert reasons(~S|System.cmd("mix", ["xref", "graph", "--no-compile"])|, &exists?/1) ==
               ["reads mix xref"]

      assert reasons(~S{System.cmd("mix", [ "xref" | args])}, &exists?/1) == ["reads mix xref"]

      assert reasons(~S|# read from the compiler's xref data (`mix xref graph`)|, &exists?/1) ==
               []
    end
  end
end
