defmodule Slipdock.RepoChecksTest do
  @moduledoc """
  `test/repo_checks.txt` (#1867): the tests that hold the repository's own
  files, docs and skills to a rule or to the server, which `mix pre_push`
  runs. This keeps the list honest: a test file that reads `docs/`,
  `README.md` or another file at the repository's root (`.gitignore`,
  `Dockerfile`, `mix.exs`), a module's moduledoc or `priv/skills/`, wildcards
  over `lib/` or `test/`, or reads the compiler's cross-reference graph (`mix
  xref`), is either on the list or among its exceptions, each with its reason
  (#2673 added the README and the moduledoc, #2972 the other root files).

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
      readme_read?(source) && "reads README.md",
      root_reason(source, exists?),
      moduledoc_read?(source) && "reads a moduledoc",
      (source =~ "Path.wildcard" and source =~ ~r{"(\.\./)*(lib|test)(/[^"]*)?"}) &&
        "wildcards over lib/ or test/",
      source =~ ~r{\[\s*"xref"} && "reads mix xref"
    ]
    |> Enum.filter(& &1)
  end

  # The root README read: passed to a call (`read("README.md")`,
  # `flat.("README.md")`), joined to the root, piped, or reached by `../`. A
  # `"README.md"` held as data (a package's file name, a lane path, a list of
  # paths for the rules) is not that.
  defp readme_read?(source) do
    source =~ ~r{(?<=\w|\w[!?]|\.)\(\s*"README\.md"} or
      source =~ ~r{Path\.join\(\s*@root,\s*"README\.md"} or
      source =~ ~r{"README\.md"\s*\|>} or
      source =~ ~r{"(\.\./)+README\.md"}
  end

  # Why the source reads other files at the repository's root, or nil (#2972):
  # `.gitignore`, `Dockerfile`, `mix.exs` and the like, each named once. A
  # name counts when it is a file there (`exists?`) and is read the ways the
  # README is: passed to a call, joined to `@root`, piped, or reached by
  # `../`. The same name joined to a scratch directory (`Path.join(dir,
  # ".gitignore")`) or held in a list is data. The README keeps its own
  # reason. The call's name is a lookbehind, so the scan starts at the
  # bracket: led by `\w` it took half a second over the test files.
  @root_reads [
    ~r{(?<=\w|\w[!?]|\.)\(\s*"([\w.\-]+)"},
    ~r{Path\.join\(\s*@root,\s*"([\w.\-]+)"},
    ~r{"([\w.\-]+)"\s*\|>},
    ~r{"(?:\.\./)+([\w.\-]+)"}
  ]

  defp root_reason(source, exists?) do
    names =
      for pattern <- @root_reads, [_, name] <- Regex.scan(pattern, source), uniq: true, do: name

    case Enum.filter(names -- ["README.md"], exists?) do
      [] -> nil
      root -> "reads #{Enum.join(root, ", ")} at the root"
    end
  end

  # A module's moduledoc read by `Code.fetch_docs`, or off a source file by a
  # pattern or string that names `@moduledoc`. A test module's own
  # `@moduledoc` attribute, at the start of a line, is not that.
  defp moduledoc_read?(source) do
    source =~ ~r{\bCode\.fetch_docs\b} or
      source =~ ~r{(~[rRsS]\W|")[^"\n]*@moduledoc}
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

  @doc false
  # The flagged files the list neither names nor excepts, each with its reasons.
  def missing(flagged, %{tests: tests, exceptions: exceptions}) do
    for {path, why} <- Enum.sort(flagged),
        path not in tests,
        not Map.has_key?(exceptions, path),
        do: "#{path} (#{Enum.join(why, "; ")})"
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

    test "every test file that reads docs, skills or a root file, or wildcards over the code, is on it" do
      missing = missing(flagged(), parsed())

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

  describe "missing/2 (#2673)" do
    defp sources_flagged(sources) do
      for {path, source} <- sources,
          why = reasons(source, fn _ -> false end),
          why != [],
          into: %{},
          do: {path, why}
    end

    @readers %{
      "test/x/readme_test.exs" => ~S|assert read("README.md") =~ "pulse"|,
      "test/x/moduledoc_test.exs" =>
        ~S|{:docs_v1, _, _, _, %{"en" => d}, _, _} = Code.fetch_docs(M)|,
      "test/x/plain_test.exs" => ~S|assert 1 + 1 == 2|
    }

    test "a README or moduledoc reader that isn't on the list is missing, and the list test fails" do
      flagged = sources_flagged(@readers)

      assert missing(flagged, %{tests: [], exceptions: %{}}) == [
               "test/x/moduledoc_test.exs (reads a moduledoc)",
               "test/x/readme_test.exs (reads README.md)"
             ]
    end

    test "listed, or excepted with a reason, it is not" do
      flagged = sources_flagged(@readers)

      assert missing(flagged, %{
               tests: ["test/x/readme_test.exs"],
               exceptions: %{"test/x/moduledoc_test.exs" => "its module is data"}
             }) == []
    end
  end

  describe "a root file's reader (#2972)" do
    @gitignore_links "test/slipdock/gitignore_links_test.exs"

    test "the .gitignore test is flagged, so the list without its line fails" do
      why = reasons(File.read!(Path.join(@root, @gitignore_links)))
      assert why == ["reads .gitignore at the root"]

      list = parsed()
      assert @gitignore_links in list.tests
      assert missing(%{@gitignore_links => why}, list) == []

      assert missing(%{@gitignore_links => why}, %{list | tests: list.tests -- [@gitignore_links]}) ==
               ["#{@gitignore_links} (reads .gitignore at the root)"]
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
    defp exists?(path),
      do:
        path in [
          "docs/manual.md",
          "docs/agents.md",
          ".gitignore",
          ".sobelow-conf",
          "Dockerfile",
          "mix.exs",
          "README.md"
        ]

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

    test "the README read by a call, joined to the root, piped or by ../ (#2673)" do
      for source <- [
            ~S|assert read("README.md") =~ "x"|,
            ~S|readme = Slipdock.DocsText.read!("README.md")|,
            ~S|assert flat.("README.md") =~ "x"|,
            ~S|File.read!(Path.join(@root, "README.md"))|,
            ~S{"README.md" |> read() |> String.split("\n")},
            ~S|File.read!(Path.expand("../../README.md", __DIR__))|
          ] do
        assert reasons(source, &exists?/1) == ["reads README.md"], source
      end
    end

    test "but not a README.md held as data: a package's file, a lane path, a list of paths" do
      for source <- [
            ~S|package(name, "1.1.0", %{"README.md" => "# Newer"})|,
            ~S|assert unpack(body)["README.md"] == "# Demo"|,
            ~S|Handbook.rules_for(h, ["README.md", "lib/other.ex"])|,
            ~S|handbook(conn, board, paths: "README.md")|,
            ~S|%{"file" => "README.md", "line" => 40}|,
            ~S|assert ("README.md" in paths)|,
            ~S|File.write!(Path.join(dir, "README.md"), "a")|
          ] do
        assert reasons(source, &exists?/1) == [], source
      end
    end

    test "a root file read by a call, joined to the root, piped or by ../ (#2972)" do
      for source <- [
            ~S|assert read(".gitignore") =~ "/deps"|,
            ~S|ignore = Slipdock.DocsText.read!(".gitignore")|,
            ~S|assert flat.(".gitignore") =~ "/deps"|,
            ~S|File.cp!(Path.join(@root, ".gitignore"), Path.join(dir, ".gitignore"))|,
            ~S|File.read!(Path.join( @root, ".gitignore"))|,
            ~S{".gitignore" |> read() |> String.split("\n")},
            ~S|File.read!(Path.expand("../../.gitignore", __DIR__))|,
            ~s|File.read!(\n  ".gitignore"\n)|,
            ~S|read( ".gitignore")|
          ] do
        assert reasons(source, &exists?/1) == ["reads .gitignore at the root"], source
      end

      # A name with a hyphen in it, as `.sobelow-conf` at the root has.
      for source <- [
            ~S|read(".sobelow-conf")|,
            ~S|File.read!(Path.join(@root, ".sobelow-conf"))|,
            ~S{".sobelow-conf" |> read()},
            ~S|File.read!(Path.expand("../../.sobelow-conf", __DIR__))|
          ] do
        assert reasons(source, &exists?/1) == ["reads .sobelow-conf at the root"], source
      end
    end

    test "but not a root file's name held as data, nor a name that is no file at the root" do
      for source <- [
            ~S|File.write!(Path.join(dir, ".gitignore"), "/_build/\n")|,
            ~S|assert untracked(dir) == [".gitignore"]|,
            ~S|assert Enum.sort(untracked(dir)) == [".gitignore", "_build", "deps"]|,
            ~S|%{"file" => "mix.exs", "line" => 4}|,
            ~S|assert ("mix.exs" in paths)|,
            ~S|File.regular?(Path.join([@root, "cli", "mix.exs"]))|,
            ~S|assert read("notes.txt") =~ "x"|,
            ~S|File.read!(Path.join(@root, "scratch.md"))|,
            ~S|File.read!(Path.expand("../../lib", __DIR__))|
          ] do
        assert reasons(source, &exists?/1) == [], source
      end
    end

    test "names each root file once, in the order read, beside the other reasons" do
      source =
        ~S|read("mix.exs") <> read("Dockerfile") <> File.read!(Path.join(@root, "mix.exs"))|

      assert reasons(source, &exists?/1) == ["reads mix.exs, Dockerfile at the root"]

      assert reasons(~S|read("README.md") <> read("Dockerfile")|, &exists?/1) ==
               ["reads README.md", "reads Dockerfile at the root"]

      assert reasons(~S|read("README.md")|, &exists?/1) == ["reads README.md"]
    end

    test "a moduledoc read by Code.fetch_docs or off a source file (#2673)" do
      assert reasons(
               ~S|{:docs_v1, _, _, _, %{"en" => doc}, _, _} = Code.fetch_docs(M)|,
               &exists?/1
             ) ==
               ["reads a moduledoc"]

      assert reasons(~S|Regex.scan(~r/@moduledoc """(.*?)"""/s, File.read!(path))|, &exists?/1) ==
               ["reads a moduledoc"]

      assert reasons(~S|String.split(source, "@moduledoc \"\"\"")|, &exists?/1) ==
               ["reads a moduledoc"]
    end

    test "but not a test module's own @moduledoc, nor the word in prose" do
      source = ~s|defmodule X do\n  @moduledoc """\n  Holds the moduledoc of Y.\n  """\nend|
      assert reasons(source, &exists?/1) == []
      assert reasons(~S|# @moduledoc false would hide it|, &exists?/1) == []
    end

    test "a file reading both the README and a moduledoc gives both reasons" do
      source = ~S|read("README.md") <> elem(Code.fetch_docs(M), 4)["en"]|
      assert reasons(source, &exists?/1) == ["reads README.md", "reads a moduledoc"]
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
