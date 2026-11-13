defmodule SlipdockWeb.API.SkillsTest do
  @moduledoc """
  The agent instructions this app serves. They need no token, for the same
  reason the guide needs none: they say how to call the API, not what is on it.
  """
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.DocsFacts, only: [assert_states: 2]

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

  # A part of slipdock-loop that only some passes read (#3004): a file under
  # its `references/`, served beside its `SKILL.md`.
  defp loop_reference(conn, file) do
    conn
    |> get("/api/skills/slipdock-loop/references/#{file}")
    |> json_response(200)
    |> Map.fetch!("content")
  end

  @tag :anonymous
  test "slipdock-loop takes a job from a pool's queue when it is given one", %{conn: conn} do
    assert %{"content" => body} =
             conn |> get("/api/skills/slipdock-loop") |> json_response(200)

    picking = loop_reference(conn, "picking.md")

    assert_states(picking, "## 2b. A job first, when you are given a pool")
    assert picking =~ "slipdock claim-job <board> --pool <pool>"
    # The running log doubles as the heartbeat, and the job ends with the card.
    assert picking =~ "slipdock job-progress <job> --message"
    assert picking =~ "slipdock finish-job <job> --status done"
    # No job means stop, unless told to fall back; an older server is no reason to fail.
    assert_states(picking, "only if the\n  invocation says to fall back")
    assert picking =~ "one older than runners"
    # The pass that has to choose its card is sent there (#3004).
    assert_states(
      body,
      "the invocation names a pool to take a job from | `references/picking.md`"
    )

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
    assert_states(body, ~s("Don't comment on the card at all"))
    assert body =~ "with no `--message`"

    assert_states(
      Slipdock.Runners.Setup.instructions(%{
        "scenario" => "loop",
        "verbosity" => "nothing",
        "instructions" => ""
      }),
      "Don't comment on the card at all"
    )

    # Run by hand, the skill still does all of it.
    assert_states(body, "Run by hand, with nothing said, do all of it")
  end

  @tag :anonymous
  test "slipdock-loop watches the CI build after every push", %{conn: conn} do
    assert %{"content" => body} =
             conn |> get("/api/skills/slipdock-loop") |> json_response(200)

    picking = loop_reference(conn, "picking.md")
    build = loop_reference(conn, "build.md")

    # Before picking: a red default branch becomes a card on top of To Do.
    assert picking =~ "## 2a. Check CI before you pick"
    assert picking =~ "gh run list --branch <default-branch> --limit 1"
    assert picking =~ ~s(CI failing on <branch>)

    # A pass that died mid-watch resumes the watch rather than the work.
    assert picking =~ "last comment is `Build started`"

    # ...including on an epic's sub-board, not just the top level.
    assert picking =~
             "slipdock cards <sub-board-id> --column \"In Progress\" --assignee me --open"

    # Closing out: announce the build, watch it quietly, report either way.
    assert body =~ "gh run list --commit <full-sha>"
    assert build =~ "gh run watch <run-id> --exit-status --interval 10 > /dev/null"
    refute build =~ "--interval 30"
    refute body =~ "--interval 30"

    # Headless (`claude -p`) passes exit when the turn ends, so the watch can't
    # be left in the background to report back later. The step says so itself,
    # and sends the pass to the watch (#3004).
    assert_states(body, "in the foreground, never in the background with the turn ended")
    assert_states(body, "`references/build.md` has the watch")
    assert build =~ "**Run it in the foreground**"
    assert_states(build, "Never run the watch in\n   the background")
    refute build =~ "background and wait to be notified"
    refute body =~ "background and wait to be notified"
    assert build =~ "**Passed:** `Build passed:"
    assert build =~ "**Failed:** `Build failed:"
    assert build =~ "After **two** failed fix attempts"
    assert body =~ "CI: passed"
    assert_states(body, "**Never close a top-level card on a red build.**")
    refute body =~ "**Never close a card on a red build.**"

    # The version `skills check` compares moved off the copy without any of it.
    refute Skills.get("slipdock-loop").sha == "04da54775b80ab49"
  end

  @tag :anonymous
  test "slipdock-loop waits for the build only when the top-level card closes", %{conn: conn} do
    assert %{"content" => body} =
             conn |> get("/api/skills/slipdock-loop") |> json_response(200)

    build = loop_reference(conn, "build.md")
    subcards = loop_reference(conn, "subcards.md")

    # A subcard closes on `Build started`; only the epic (or a lone card) waits.
    assert_states(body, "4. **Wait for the build — for the pass's top-level card only**")
    assert_states(body, "A subcard does not wait: its `Build started` comment is enough.")
    assert_states(build, "4. **Wait for the build — for the pass's top-level card only.**")
    assert build =~ "**A subcard** does not wait."

    assert build =~
             "started — <workflow> #<run-id> <run url> (checked before the\n     epic closes)"

    assert_states(build, "waits for the build of the last push")

    # Between subcards: one look at the latest build, and a red one comes first.
    assert_states(body, "| The card has subcards (an epic) | `references/subcards.md`")

    assert_states(
      subcards,
      "**before\nclaiming the next subcard, look at the latest build on the branch**"
    )

    assert subcards =~ "gh run list --branch <branch> --limit 1"
    # The fix goes on a new subcard: the board refuses reopening a done one (#1850, #1853).
    assert subcards =~ ~s(slipdock add <sub-board> "Build failed: #<id> <title>")

    for text <- [body, build, subcards],
        do: refute(text =~ "`slipdock undone <id>`")

    # The epic closes only on a green build of its last push.
    assert_states(subcards, "the build\nof the last push is green")

    # A red build from a dead pass's subcard is fixed under its epic, not on a new top-level card.
    assert_states(
      loop_reference(conn, "picking.md"),
      "If the commit is a closed subcard's and its epic is still\nopen"
    )
  end

  @tag :anonymous
  test "slipdock-loop leaves the full suite to CI and files flaky tests", %{conn: conn} do
    assert %{"content" => body} =
             conn |> get("/api/skills/slipdock-loop") |> json_response(200)

    # Where CI runs the whole suite, only the tests the change touches run
    # locally; without CI the whole suite still runs before the push.
    assert_states(body, "don't run the\n   whole suite here as well")
    assert body =~ "`mix test --stale`"
    assert_states(body, "With no CI, run the whole suite.")
    refute body =~ "Run the project's test suite if the card touched code"

    # A failure that doesn't come back is a card, not a reason to rerun.
    assert_states(body, "do not rerun the suite until it is\n   green, add a card for it")

    # The wrap-up example says where the full run happened.
    assert_states(body, "Tests: mix test --stale — 38 passed, 0 failed; full suite in CI")
  end

  @tag :anonymous
  test "slipdock-loop raises the alarm when its token dies, rather than stalling", %{conn: conn} do
    assert %{"content" => body} =
             conn |> get("/api/skills/slipdock-loop") |> json_response(200)

    # The token is checked every pass, not once per session.
    refute body =~ "## Preflight, once per session"
    assert_states(body, "`whoami` runs at the start of **every** pass")

    # A dead token mid-card is loud: no retries, no self-auth, an alert, a stopped loop.
    assert_states(
      body,
      "If the token is dead, follow **When the token dies** in `references/stops.md`"
    )

    stops = loop_reference(conn, "stops.md")
    assert stops =~ "## When the token dies"
    assert stops =~ "never run `slipdock auth`\n   yourself"
    assert stops =~ "start the pass report with `SLIPDOCK AUTH FAILED`"
    assert stops =~ "ScheduleWakeup with `stop: true`"
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

  @tag :anonymous
  test "the skills ask for comments in readable Markdown, sent over stdin", %{conn: conn} do
    skill = fn name ->
      conn |> get("/api/skills/#{name}") |> json_response(200) |> Map.fetch!("content")
    end

    loop = skill.("slipdock-loop")
    assert loop =~ "### How a comment reads"
    assert loop =~ "never one dense paragraph"
    # The claim and the running log keep their line breaks: stdin, not words.
    assert loop =~ "slipdock comment <id> --body - <<'EOF'\n**Picked up.**"

    assert loop_reference(conn, "picking.md") =~
             "slipdock job-progress <job> --message - <<'EOF'"

    refute loop =~ "slipdock comment <id> Picked up. <what you read it as"
    # The wrap-up is a list, not a run of label lines.
    assert loop =~ "**Done.**\n\n   - What was done:"
    assert loop =~ "   - Commit: `abc1234` (master)"

    assert_states(skill.("slipdock-work"), "**Comments are Markdown, and are skimmed.**")
    assert skill.("slipdock") =~ "slipdock comment <id> --body - <<'EOF'"
  end

  @tag :anonymous
  test "slipdock-loop re-reads the card before pushing and its comments after", %{conn: conn} do
    skill = fn name ->
      conn |> get("/api/skills/#{name}") |> json_response(200) |> Map.fetch!("content")
    end

    loop = skill.("slipdock-loop")
    # Between checking the work and the commit: the brief as it is now.
    [check, rest] = String.split(loop, "2. **Commit**", parts: 2)
    assert check =~ "**Then re-read the card, before committing.**"
    assert_states(check, "compare the\n   description with what you read in step 3")
    # After `Build started`, and again after a build wait, before closing.
    [started, _] = String.split(rest, "4. **Wait for the build", parts: 2)
    assert_states(started, "**Then read the comments once more.**")
    assert started =~ "once more just before step 5"
    assert_states(loop, "- **Re-read the card before the push, and its comments after it.**")

    assert_states(
      skill.("slipdock-work"),
      "- **Re-read the card before you push, and its comments after.**"
    )
  end

  @tag :anonymous
  test "a finished card's handoff is what is left for the person, or blank", %{conn: conn} do
    skill = fn name ->
      conn |> get("/api/skills/#{name}") |> json_response(200) |> Map.fetch!("content")
    end

    loop = skill.("slipdock-loop")
    # The last part of the wrap-up, before the job is finished.
    [wrap, _] = String.split(loop, "7. **The job**, if the card came from one", parts: 2)
    assert wrap =~ "Last, **the handoff**"

    assert_states(
      wrap,
      "slipdock handoff <id> --next \"Reinstall the CLI once the deploy is out\" --body - <<'EOF'"
    )

    assert wrap =~ "the handoff stays blank"
    assert wrap =~ "handoff <id> --clear` (over MCP, `leave_handoff` with `clear: true`)"
    refute loop =~ "A finished card needs none."
    assert_states(loop, "never close\n  one with a stale handoff on it")

    work = skill.("slipdock-work")
    assert_states(work, "On a **finished** card the handoff is for the person")
    assert work =~ "`slipdock handoff <id> --clear` one left from earlier"
  end
end
