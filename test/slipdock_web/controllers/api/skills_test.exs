defmodule SlipdockWeb.API.SkillsTest do
  @moduledoc """
  The agent instructions this app serves. They need no token, for the same
  reason the guide needs none: they say how to call the API, not what is on it.
  """
  use SlipdockWeb.ConnCase, async: true

  alias Slipdock.Skills

  @tag :anonymous
  test "lists the skills with a version each, without a token", %{conn: conn} do
    assert %{"skills" => skills} = conn |> get("/api/skills") |> json_response(200)

    names = Enum.map(skills, & &1["name"])
    assert "slipdock" in names
    assert "slipdock-wiki" in names
    assert "slipdock-docs" in names
    assert "slipdock-work" in names
    assert "slipdock-loop" in names

    loop = Enum.find(skills, &(&1["name"] == "slipdock-loop"))
    assert loop["description"] =~ "To Do"

    wiki = Enum.find(skills, &(&1["name"] == "slipdock-wiki"))
    assert wiki["description"] =~ "wiki"
    assert "SKILL.md" in wiki["files"]
    assert "references/markup.md" in wiki["files"]
    assert String.length(wiki["sha"]) == 16
  end

  @tag :anonymous
  test "serves a skill and its reference files", %{conn: conn} do
    assert %{"content" => body, "file" => "SKILL.md"} =
             conn |> get("/api/skills/slipdock-wiki") |> json_response(200)

    assert body =~ "name: slipdock-wiki"

    assert %{"content" => markup} =
             conn |> get("/api/skills/slipdock-wiki/references/markup.md") |> json_response(200)

    assert markup =~ "[[Retry policy]]"
  end

  @tag :anonymous
  test "slipdock-loop watches the CI build after every push", %{conn: conn} do
    assert %{"content" => body} =
             conn |> get("/api/skills/slipdock-loop") |> json_response(200)

    # Before picking: a red default branch becomes a card on top of To Do.
    assert body =~ "## 2a. Check CI before you pick"
    assert body =~ "gh run list --branch <default-branch> --limit 1"
    assert body =~ ~s(CI failing on <branch>)

    # A pass that died mid-watch resumes the watch rather than the work.
    assert body =~ "last comment is `Build started`"

    # ...including on an epic's sub-board, not just the top level.
    assert body =~ "slipdock cards <sub-board-id> --column \"In Progress\" --assignee me --open"

    # Closing out: announce the build, watch it quietly, report either way.
    assert body =~ "gh run list --commit <full-sha>"
    assert body =~ "gh run watch <run-id> --exit-status --interval 10 > /dev/null"
    refute body =~ "--interval 30"

    # Headless (`claude -p`) passes exit when the turn ends, so the watch can't
    # be left in the background to report back later.
    assert body =~ "**Run it in the foreground**"
    assert body =~ "Never run the watch in\n   the background"
    refute body =~ "background and wait to be notified"
    assert body =~ "**Passed:** `Build passed:"
    assert body =~ "**Failed:** `Build failed:"
    assert body =~ "After **two** failed fix attempts"
    assert body =~ "CI: passed"
    assert body =~ "**Never close a card on a red build.**"

    # The version `skills check` compares moved off the copy without any of it.
    refute Skills.get("slipdock-loop").sha == "04da54775b80ab49"
  end

  @tag :anonymous
  test "slipdock-loop leaves the full suite to CI and files flaky tests", %{conn: conn} do
    assert %{"content" => body} =
             conn |> get("/api/skills/slipdock-loop") |> json_response(200)

    # Where CI runs the whole suite, only the tests the change touches run
    # locally; without CI the whole suite still runs before the push.
    assert body =~ "don't run the\n   whole suite here as well"
    assert body =~ "`mix test --stale`"
    assert body =~ "With no CI, run the whole suite."
    refute body =~ "Run the project's test suite if the card touched code"

    # A failure that doesn't come back is a card, not a reason to rerun.
    assert body =~ "do not rerun the suite until it is\n   green, add a card for it"

    # The wrap-up example says where the full run happened.
    assert body =~ "Tests: mix test --stale — 38 passed, 0 failed; full suite in CI"
  end

  @tag :anonymous
  test "slipdock-loop raises the alarm when its token dies, rather than stalling", %{conn: conn} do
    assert %{"content" => body} =
             conn |> get("/api/skills/slipdock-loop") |> json_response(200)

    # The token is checked every pass, not once per session.
    refute body =~ "## Preflight, once per session"
    assert body =~ "`whoami` runs at the start of **every** pass"

    # A dead token mid-card is loud: no retries, no self-auth, an alert, a stopped loop.
    assert body =~ "## When the token dies"
    assert body =~ "never run `slipdock auth`\n   yourself"
    assert body =~ "start the pass report with `SLIPDOCK AUTH FAILED`"
    assert body =~ "ScheduleWakeup with `stop: true`"
  end

  @tag :anonymous
  test "a skill that is not there is a 404", %{conn: conn} do
    assert conn |> get("/api/skills/nope") |> json_response(404)
  end

  @tag :anonymous
  test "cannot be used to read outside the skills directory", %{conn: conn} do
    assert conn |> get("/api/skills/slipdock-wiki/../../../mix.exs") |> json_response(404)
    assert {:error, :not_found} = Skills.read("slipdock-wiki", "../../mix.exs")
    assert {:error, :not_found} = Skills.read("../repo", "SKILL.md")
  end

  test "the sha changes when a file does, which is what `skills check` compares" do
    [%{sha: sha}] = Skills.list() |> Enum.filter(&(&1.name == "slipdock-wiki"))
    assert is_binary(sha)
    assert Skills.get("slipdock-wiki").sha == sha
  end
end
