defmodule SlipdockWeb.JobLogsDocsTest do
  @moduledoc """
  Job logs (#1869) as the docs tell it, end to end: a running job's live log
  is watched from the card, the Runners panel, the CLI and MCP; it expires
  per the board's two times unless kept; Keep this log writes a Pass page;
  and the after-job hook's pass log is opt-in. The README, the manual, the
  agent guide, the API guide and the packaged skill each say their part.
  """
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.DocsFacts, only: [assert_states: 2]

  @root Path.expand("../..", __DIR__)
  defp read(path), do: Slipdock.DocsText.read!(Path.join(@root, path))

  test "the README tells the whole story in one place" do
    readme = read("README.md")
    assert_states(readme, "**Watch a job as it runs, keep its log only if it matters.**")
    assert readme =~ "`slipdock job <id>\n  --follow`"
    assert readme =~ "MCP `job_log`"
    assert readme =~ "**Keep this log** (`slipdock job <id> --keep`)"
    assert readme =~ "`Pass <card> (<date>)` page in the card's folder"
  end

  test "the manual has watching, expiry, keeping and the opt-in pass log" do
    manual = read("docs/manual.md")
    assert manual =~ "**Watching a job.**"
    assert manual =~ "**Logs evaporate unless kept.**"
    assert_states(manual, "**Keep job logs for** (24 hours by default)")
    assert_states(manual, "**Keep failure logs for** (168 hours, 7 days)")
    # The opt-in pass-log hook example went with the shell runners (#2582):
    # Keep this log is the one way to keep a pass.
    refute manual =~ "pass log is **opt-in**"
    assert manual =~ "**Keep this log**"
  end

  test "the agent guide, the API guide and the skill name the commands" do
    agents = read("docs/agents.md")
    assert agents =~ "`slipdock job <id> --follow`"
    assert agents =~ "`keep_job_log`"
    refute agents =~ "The pass log is opt-in"
    assert agents =~ "unless kept: `slipdock job <id> --keep`"

    guide = SlipdockWeb.APIGuide.markdown()
    assert guide =~ "GET /api/jobs/:id/log?from=N"
    assert guide =~ "POST /api/jobs/:id/keep"
    assert guide =~ "failure_log_hours"

    skill = read("priv/skills/slipdock/SKILL.md")
    assert skill =~ "slipdock job <id> --follow"
    assert skill =~ "slipdock job <id> --keep"
    assert skill =~ "--job-log-hours"
  end
end
