defmodule Slipdock.JobSearchPackageTest do
  @moduledoc """
  The job-search Tool kept in `packages/job-search` (#1148, design W-1850).
  Its skills are stubs that fetch their procedure from the server at run time,
  so these tests hold the stubs to the paths they fetch, the procedures to the
  board they run against, and all of it to containing nothing about any one
  person.
  """
  use ExUnit.Case, async: true

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
    assert generate =~ "claim_job` with the board and pool `generate`"

    # Files move by single-use link, never as base64 through the conversation.
    assert generate =~ "`download_file` with `link: true`"
    assert generate =~ "`upload_file` with `card`, `link: true`"
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
