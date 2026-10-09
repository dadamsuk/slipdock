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
  test "slipdock-loop takes a job from a pool's queue when it is given one", %{conn: conn} do
    assert %{"content" => body} =
             conn |> get("/api/skills/slipdock-loop") |> json_response(200)

    assert body =~ "## 2b. A job first, when you are given a pool"
    assert body =~ "slipdock claim-job <board> --pool <pool>"
    # The running log doubles as the heartbeat, and the job ends with the card.
    assert body =~ "slipdock job-progress <job> --message"
    assert body =~ "slipdock finish-job <job> --status done"
    # No job means stop, unless told to fall back; an older server is no reason to fail.
    assert body =~ "only if the\n  invocation says to fall back"
    assert body =~ "one older than runners"

    assert %{"content" => work} = conn |> get("/api/skills/slipdock-work") |> json_response(200)
    assert work =~ "runner job"
    assert work =~ "slipdock finish-job <job>"
  end

  # The runner setup's prompts turn each toggle off in so many words; the
  # skill names those same words, so the two can't drift apart (#514).
  @tag :anonymous
  test "slipdock-loop names every toggle the setup prompts can turn off", %{conn: conn} do
    assert %{"content" => body} =
             conn |> get("/api/skills/slipdock-loop") |> json_response(200)

    assert body =~ "## What the invocation says wins"

    for {toggle, words} <- Slipdock.Runners.Setup.off_wording() do
      assert body =~ words, "#{toggle}: #{words}"
      # ...and they are what the prompts actually say.
      {:ok, a} = Slipdock.Runners.Setup.normalise(%{"commit" => toggle == "push"})
      assert Slipdock.Runners.Setup.card_text(a) =~ words, toggle
    end

    assert Enum.sort(Map.keys(Slipdock.Runners.Setup.off_wording())) ==
             Enum.sort(Slipdock.Runners.Setup.toggles())

    # Nothing written on the card: no comments, and job-progress with no message.
    assert body =~ ~s("Don't comment on the card at all")
    assert body =~ "with no `--message`"

    assert Slipdock.Runners.Setup.instructions(%{
             "scenario" => "loop",
             "verbosity" => "nothing",
             "instructions" => ""
           }) =~
             "Don't comment on the card at all"

    # Run by hand, the skill still does all of it.
    assert body =~ "Run by hand, with nothing said, do all of it"
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
    assert body =~ "**Never close a top-level card on a red build.**"
    refute body =~ "**Never close a card on a red build.**"

    # The version `skills check` compares moved off the copy without any of it.
    refute Skills.get("slipdock-loop").sha == "04da54775b80ab49"
  end

  @tag :anonymous
  test "slipdock-loop waits for the build only when the top-level card closes", %{conn: conn} do
    assert %{"content" => body} =
             conn |> get("/api/skills/slipdock-loop") |> json_response(200)

    # A subcard closes on `Build started`; only the epic (or a lone card) waits.
    assert body =~ "4. **Wait for the build — for the pass's top-level card only.**"
    assert body =~ "**A subcard** does not wait."

    assert body =~
             "started — <workflow> #<run-id> <run url> (checked before the\n     epic closes)"

    assert body =~ "waits for the build of the last push"

    # Between subcards: one look at the latest build, and a red one comes first.
    assert body =~ "**before\nclaiming the next subcard, look at the latest build on the branch**"
    assert body =~ "gh run list --branch <branch> --limit 1"
    assert body =~ "`slipdock undone <id>`"

    # The epic closes only on a green build of its last push.
    assert body =~ "the build\nof the last push is green"

    # A red build from a dead pass's subcard goes back to that subcard, not a new card.
    assert body =~ "If the commit is a closed subcard's and its epic is still\nopen"
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
  test "serves a ChatGPT version of a skill as a zip, and says which have one", %{conn: conn} do
    conn = Map.put(conn, :host, "boards.example.test")
    resp = get(conn, "/api/skills/slipdock-work/chatgpt.zip")

    assert response_content_type(resp, :zip) =~ "application/zip"

    assert get_resp_header(resp, "content-disposition") == [
             ~s(attachment; filename="slipdock-work.zip")
           ]

    {:ok, [{path, md}]} = :zip.unzip(response(resp, 200), [:memory])
    assert to_string(path) == "slipdock-work/SKILL.md"
    # The connector address is the one the caller reached this server on.
    assert md =~ "http://boards.example.test/mcp"

    assert %{"skills" => skills} = conn |> get("/api/skills") |> json_response(200)
    zips = Map.new(skills, &{&1["name"], &1["chatgpt_zip"]})
    assert zips["slipdock-work"] == "/api/skills/slipdock-work/chatgpt.zip"
    assert zips["slipdock-loop"] == nil
  end

  @tag :anonymous
  test "the loop and missing skills have no ChatGPT version", %{conn: conn} do
    assert conn |> get("/api/skills/slipdock-loop/chatgpt.zip") |> json_response(404)
    assert conn |> get("/api/skills/nope/chatgpt.zip") |> json_response(404)
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
