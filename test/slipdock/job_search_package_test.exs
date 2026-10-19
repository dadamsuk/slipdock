defmodule Slipdock.JobSearchPackageTest do
  @moduledoc """
  The job-search Tool kept in `packages/job-search` (#1148, design W-1850).
  Its skills are stubs that fetch their procedure from the server at run time,
  so these tests hold the stubs to the paths they fetch, the procedures to the
  board they run against, and all of it to containing nothing about any one
  person.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Automations, Repo, Tools, Wiki}
  alias Slipdock.Tools.Package

  @dir Path.expand("../../packages/job-search", __DIR__)
  @skills ~w(job-search-generate job-search-scan job-search-setup)
  @pages ["Criteria", "Sources", "Candidate Facts", "CV Baseline", "Writing Rules"]

  defp read(path), do: File.read!(Path.join(@dir, path))

  defp front_matter(text) do
    [_, yaml | _] = String.split(text, "---\n", parts: 3)

    yaml
    |> String.split("\n", trim: true)
    |> Map.new(fn line ->
      [k, v] = String.split(line, ": ", parts: 2)
      {k, v}
    end)
  end

  defp entries do
    @dir
    |> Path.join("**")
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&File.regular?/1)
    |> Enum.map(&{Path.relative_to(&1, @dir), File.read!(&1)})
  end

  defp tarball do
    path = Path.join(System.tmp_dir!(), "job-search-#{System.unique_integer([:positive])}.tar.gz")
    tar = Enum.map(entries(), fn {p, c} -> {String.to_charlist(p), c} end)
    :ok = :erl_tar.create(String.to_charlist(path), tar, [:compressed, :write])
    bytes = File.read!(path)
    File.rm!(path)
    bytes
  end

  defp installed do
    user = user_fixture()
    {:ok, version} = Tools.publish(user, tarball())
    Slipdock.TestConfig.own_uploads_dir()
    {:ok, %{board: board}} = Tools.install_board(user, version.tool)
    board
  end

  defp procedures, do: Enum.map(@skills, &read("skills/#{&1}/references/procedure.md"))

  defp all_text do
    @dir
    |> Path.join("skills/**/*.md")
    |> Path.wildcard()
    |> Enum.map_join("\n", &File.read!/1)
  end

  test "each skill is a stub that names itself and fetches its own procedure every way" do
    for skill <- @skills do
      stub = read("skills/#{skill}/SKILL.md")
      meta = front_matter(stub)
      path = "skills/#{skill}/references/procedure.md"

      assert meta["name"] == skill
      assert String.length(meta["description"]) > 100
      assert File.regular?(Path.join(@dir, path)), "#{path} is missing"

      assert stub =~ ~s({"tool": "job-search", "file": "#{path}"})
      assert stub =~ "slipdock tools file job-search #{path}"
      assert stub =~ "/api/tools/job-search/files/#{path}"
      # The stub carries no procedure of its own beyond the fetch.
      assert byte_size(stub) < 3_000
    end
  end

  test "the package reads, with its three skills, and ships the build script beside generate" do
    assert {:ok, package} = Package.read(tarball())
    assert package.manifest["name"] == "job-search"
    assert Enum.map(package.skills, & &1.name) == @skills

    generate = Enum.find(package.skills, &(&1.name == "job-search-generate"))
    assert "scripts/build_docs.py" in generate.files
  end

  test "its board has the lists W-1850 sets, with Found as the ready list and Closed as done" do
    board = installed()

    assert Enum.map(board.columns, & &1.name) ==
             ["Found", "Generate", "Ready", "Applied", "In conversation", "Closed"]

    roles = SlipdockWeb.APIGuide.list_roles(board.columns)
    assert roles.ready.name == "Found"
    assert roles.doing.name == "Generate"
    assert roles.done.name == "Closed"

    categories = Map.new(board.columns, &{&1.name, &1.category})
    assert categories["Ready"] == "doing"
    assert categories["Applied"] == nil
    assert categories["In conversation"] == nil
  end

  test "the five page skeletons sit in Config, and the build blocks parse" do
    board = installed()
    pages = board |> Wiki.list_pages() |> Repo.preload(:folder)

    assert pages |> Enum.map(&{&1.title, &1.folder.name}) |> Enum.sort() ==
             Enum.sort(Enum.map(@pages, &{&1, "Config"}))

    rules = Enum.find(pages, &(&1.title == "Writing Rules"))
    rules = Wiki.get_page!(rules.id)
    assert rules.body =~ "```build\nbullet: -\ncv pages: 2\n```"
    assert rules.body =~ "```checks\n```"

    criteria = Wiki.get_page!(Enum.find(pages, &(&1.title == "Criteria")).id)
    assert criteria.body =~ "- A posting becomes a card in Found at a score of: 6"
    refute criteria.body =~ "{{"
  end

  test "a card entering Generate queues a job for the generate pool, told to run generate" do
    board = installed()

    assert [rule] = Automations.list_rules(board.id)
    assert rule.spec["trigger"] == %{"type" => "card_entered", "column" => "Generate"}

    assert [%{"type" => "runner", "pool" => "generate", "prompt" => prompt} | _] =
             rule.spec["actions"]

    assert prompt =~ "job-search-generate skill"
    assert prompt =~ "{{card.id}}"
    assert prompt =~ "finish_job"
  end

  test "every package file a procedure or stub names exists" do
    paths =
      ~r{skills/job-search-[a-z]+/[A-Za-z0-9_./-]+\.(?:md|py)}
      |> Regex.scan(all_text())
      |> List.flatten()
      |> Enum.uniq()

    assert "skills/job-search-scan/references/linkedin.md" in paths
    assert "skills/job-search-generate/scripts/build_docs.py" in paths

    for path <- paths do
      assert File.regular?(Path.join(@dir, path)), "#{path} is named but not in the package"
    end
  end

  test "the procedures run against the board W-1850 describes" do
    [generate, scan, setup] = procedures()

    for page <- @pages, do: assert(setup =~ "`#{page}`")
    for page <- ["Criteria", "Sources", "Candidate Facts"], do: assert(scan =~ "`#{page}`")

    for page <- ["Criteria", "Candidate Facts", "CV Baseline", "Writing Rules"],
        do: assert(generate =~ "`#{page}`")

    # The board is found through the install, never by searching for a page title.
    for text <- procedures(), do: assert(text =~ ~s(`list_tools` with))
    assert setup =~ ~s(`install_tool` with `tool: "job-search"`)

    # There is no Interested list, and the scan only ever creates cards in Found.
    for text <- procedures(), do: refute(text =~ "Interested")
    assert scan =~ ~s(**always naming `column: "Found"`**)
    assert scan =~ "## 3. The ledger: `Seen YYYY-MM`"

    # Questions are listed by the scan and asked only by generate, as one wait.
    assert scan =~ "**Not asking questions.**"
    assert generate =~ "open **one** wait"
    assert generate =~ "`finish_job` with outcome `waiting`"
    assert generate =~ "Keep `needs` under\n**1,000 characters**"
    assert generate =~ "claim_job` with the board and pool `generate`"

    # Ledger rows are added by rewriting the section: append_section puts a blank
    # line before what it adds, which cuts a table row off from its table.
    assert scan =~ "in `replace_section` mode, section `Postings`"
    refute scan =~ ~r/Append rows with `write_page` in `append_section`/
    assert generate =~ "`write_page` in `append` mode with a body\nthat starts `## Talking points"

    # Files move by single-use link, never as base64 through the conversation.
    assert generate =~ "`download_file` with `link: true`"
    assert generate =~ "`upload_file` with `card`, `link: true`"
  end

  test "a card the person adds to Found with a link is adopted by the scan, never doubled (#1162)" do
    [_generate, scan, setup] = procedures()
    readme = read("README.md")
    stub = front_matter(read("skills/job-search-scan/SKILL.md"))

    # Every run, either kind, starts with them, ahead of the once-a-day stop.
    assert scan =~ "## Cards the person added"
    assert scan =~ "**Every run, of either kind, starts with the cards the person added**"

    [before_stop, _] =
      String.split(scan, "**If a daily or fallback run is\nalready logged for today**")

    assert before_stop =~ "starts with the cards the person added"

    # Found: a link and no `Posting id:` line yet; the scan's own review cards are not jobs.
    assert scan =~ "`list_cards` on the board's\n`Found` list"
    assert scan =~ "**no analysis yet** (no `Posting id:` line in its\ndescription)"
    assert scan =~ "other than the scan's own `Sources review` cards"
    assert scan =~ "**Every outcome writes a `Posting id:` line**"

    # The single-URL path adopts the person's card instead of making one, and keeps their link.
    assert scan =~ "**If the person already made the card, adopt it.**"
    assert scan =~ "Only a URL with no card creates a card."
    assert scan =~ "`- Added by hand: <their link>`"
    assert scan =~ "**Keep it whatever it scores**"
    assert scan =~ "**Exclusions apply in full.**"

    # The cloud cannot read LinkedIn, so a fallback run leaves those cards for the desktop.
    assert scan =~ "on a fallback run a LinkedIn card waits for the desktop scan"

    # The person is told how to do it: README, setup's closing summary, the skill's trigger.
    assert readme =~ "## Adding a job yourself"
    assert readme =~ "Add a card to **Found** with the posting's link on it"
    assert setup =~ "add a card to `Found` with the posting's link on it"
    assert stub["description"] =~ "a card the person added to Found with only a link on it"
  end

  test "the LinkedIn reference decodes only text that carries an entity" do
    linkedin = read("skills/job-search-scan/references/linkedin.md")

    assert linkedin =~ "const dec = s => typeof s === 'string' && ENTITY.test(s)"
    refute linkedin =~ ~r/const dec = s => typeof s === 'string'\n/
    refute linkedin =~ "Job Scan"
  end

  test "nothing in the skills is about one person" do
    text = all_text()

    for personal <- [
          ~r/David/,
          ~r/Adams/,
          ~r/da@dsc\.net/,
          ~r/\bDSC\b/,
          ~r/Atheneum/,
          ~r/1F3864/i,
          ~r/GBP 180/,
          ~r/Sheffield/,
          ~r/W-1[0-9]{3}/
        ] do
      refute text =~ personal, "#{inspect(personal)} found in the skills"
    end
  end
end
