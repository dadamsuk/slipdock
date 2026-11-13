defmodule Slipdock.DeployExampleInStepTest do
  @moduledoc """
  Slipdock records its own deploys (#1134), and its release workflow is
  where the GitHub Actions worked example comes from: the lines that make it
  work — full history, Erlang, the CLI from the server, the token from a
  secret, the URL from a variable, start before and finish after — are in
  both, and in what the setup wizard writes for GitHub.
  """
  use ExUnit.Case, async: true

  @release File.read!(".github/workflows/release.yml")
  @example File.read!("priv/deploy/examples/github-actions.yml")

  @shared [
    "fetch-depth: 0",
    "erlef/setup-beam@v1",
    ~s(otp-version: "27"),
    ~s(curl -fsSL "$SLIPDOCK_URL/cli/slipdock.escript" -o "$RUNNER_TEMP/slipdock"),
    ~s(echo "$RUNNER_TEMP" >> "$GITHUB_PATH"),
    "SLIPDOCK_URL: ${{ vars.SLIPDOCK_URL }}",
    "SLIPDOCK_DEPLOY_TOKEN: ${{ secrets.SLIPDOCK_DEPLOY_TOKEN }}",
    "slipdock deploy start --env production --tag \"$TAG\"",
    "slipdock deploy finish --id",
    "job.status == 'success' && 'succeeded' || 'failed'",
    # A failed release says where (#2820).
    "  record-failure:\n",
    "slipdock deploy failed --env production --stage",
    "SLIPDOCK_DEPLOY_RUN_URL: ${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}"
  ]

  for line <- @shared do
    test "release.yml and the example both have: #{line}" do
      assert @release =~ unquote(line)
      assert @example =~ unquote(line)
    end
  end

  test "the deploy job records its deploy, and finishes it only once it was started" do
    [_, deploy] = String.split(@release, "\n  deploy:\n", parts: 2)
    assert deploy =~ "id: record"
    assert deploy =~ "if: always() && steps.record.outputs.id != ''"

    # Started before the deploy step, finished after the health check.
    {start, _} = :binary.match(deploy, "Record the deploy started")
    {run, _} = :binary.match(deploy, "name: Deploy\n")
    {healthy, _} = :binary.match(deploy, "Wait for the server to be healthy")
    {finish, _} = :binary.match(deploy, "Record how the deploy ended")
    assert start < run and run < healthy and healthy < finish
  end

  # #2820: the failure job runs only on a failure (or a cancelled job, #3009), of a push, after the jobs
  # on the way to the deploy; and every step of it may fail without failing
  # anything else.
  for {name, text} <- [{"release.yml", @release}, {"the example", @example}] do
    test "#{name}'s record-failure job runs on a failure and can't fail anything" do
      {:ok, yaml} = YamlElixir.read_from_string(unquote(text))
      job = yaml["jobs"]["record-failure"]
      # A cancelled job counts as failed; a run a person cancels doesn't (#3009).
      assert job["if"] =~
               ~r/^\$\{\{ !cancelled\(\) && \(contains\(needs\.\*\.result, 'failure'\) \|\| contains\(needs\.\*\.result, 'cancelled'\)\) && \(*github.event_name == 'push'/

      assert "deploy" in List.wrap(job["needs"])
      assert job["environment"] == "production"
      assert Enum.all?(job["steps"], &(&1["continue-on-error"] == true))
    end
  end

  test "release.yml's record-failure needs every job on the way to production" do
    {:ok, yaml} = YamlElixir.read_from_string(@release)
    jobs = yaml["jobs"]

    assert Enum.sort(jobs["record-failure"]["needs"]) ==
             Enum.sort(~w(suite test cli-build cli-sign build merge deploy))

    assert jobs["record-failure"]["if"] =~
             "(github.ref == 'refs/heads/main' || startsWith(github.ref, 'refs/tags/v'))"

    # And a dispatched release of main (#2837).
    assert jobs["record-failure"]["if"] =~
             "(github.event_name == 'workflow_dispatch' && github.ref == 'refs/heads/main')"

    # The deploy job says whether it was the deploy or the health check.
    deploy = jobs["deploy"]
    assert deploy["outputs"]["failed-stage"] == "${{ steps.failed-stage.outputs.stage }}"
    assert Enum.find(deploy["steps"], &(&1["id"] == "failed-stage"))["if"] == "failure()"
    assert Enum.any?(deploy["steps"], &(&1["id"] == "health"))

    [record] =
      Enum.filter(jobs["record-failure"]["steps"], &(&1["name"] == "Record the failed deploy"))

    assert record["run"] =~ "stage=$(.github/scripts/failed-stage.sh)"

    for {var, need} <- [
          {"CLI_BUILD", "cli-build"},
          {"CLI_SIGN", "cli-sign"},
          {"BUILD", "build"},
          {"TEST", "test"},
          {"MERGE", "merge"},
          {"DEPLOY", "deploy"}
        ] do
      assert record["env"][var] == "${{ needs.#{need}.result }}"
    end

    assert record["env"]["DEPLOY_STAGE"] == "${{ needs.deploy.outputs.failed-stage }}"

    # The deploy job's own record carries the run, so the failure marks it.
    [start] = Enum.filter(deploy["steps"], &(&1["id"] == "record"))
    assert start["env"]["SLIPDOCK_DEPLOY_RUN_URL"] == record["env"]["SLIPDOCK_DEPLOY_RUN_URL"]
  end

  describe "failed-stage.sh" do
    defp stage(env) do
      {out, 0} =
        System.cmd("sh", [".github/scripts/failed-stage.sh"],
          env: Enum.map(env, fn {k, v} -> {k, v} end),
          stderr_to_stdout: true
        )

      String.trim(out)
    end

    @main %{
      "CLI_BUILD" => "skipped",
      "CLI_SIGN" => "skipped",
      "BUILD" => "success",
      "TEST" => "success",
      "MERGE" => "success",
      "DEPLOY" => "success",
      "DEPLOY_STAGE" => ""
    }

    test "nothing when the deploy went out, or nothing on its path failed" do
      assert stage(@main) == ""
      assert stage(%{@main | "DEPLOY" => "skipped", "MERGE" => "skipped"}) == ""
    end

    test "the stage of what failed" do
      # #2809: both image builds failed, so merge and deploy never ran.
      assert stage(%{@main | "BUILD" => "failure", "MERGE" => "skipped", "DEPLOY" => "skipped"}) ==
               "build"

      assert stage(%{
               @main
               | "CLI_SIGN" => "failure",
                 "BUILD" => "skipped",
                 "DEPLOY" => "skipped"
             }) ==
               "build"

      assert stage(%{@main | "TEST" => "failure", "MERGE" => "skipped", "DEPLOY" => "skipped"}) ==
               "test"

      assert stage(%{@main | "MERGE" => "failure", "DEPLOY" => "skipped"}) == "merge"
      assert stage(%{@main | "DEPLOY" => "failure"}) == "deploy"
      assert stage(%{@main | "DEPLOY" => "failure", "DEPLOY_STAGE" => "health"}) == "health"
      assert stage(%{@main | "DEPLOY" => "failure", "DEPLOY_STAGE" => "deploy"}) == "deploy"
    end

    test "a cancelled job is a failure at its stage (#3009)" do
      # 43474584941: the macOS daemon job never got a runner, so test ended cancelled.
      assert stage(%{@main | "TEST" => "cancelled", "MERGE" => "skipped", "DEPLOY" => "skipped"}) ==
               "test"

      assert stage(%{@main | "BUILD" => "cancelled", "MERGE" => "skipped", "DEPLOY" => "skipped"}) ==
               "build"

      assert stage(%{@main | "DEPLOY" => "cancelled", "DEPLOY_STAGE" => "health"}) == "health"
      assert stage(%{@main | "MERGE" => "cancelled", "DEPLOY" => "skipped"}) == "merge"
    end

    test "a build failure comes before the test failure beside it" do
      assert stage(%{@main | "BUILD" => "failure", "TEST" => "failure", "DEPLOY" => "skipped"}) ==
               "build"
    end
  end

  test "the wizard's GitHub step installs the CLI the same way" do
    snippet = Slipdock.Deployments.Setup.snippet("github", "production")
    assert snippet =~ "fetch-depth: 0"
    assert snippet =~ "erlef/setup-beam@v1"

    assert snippet =~
             ~s(curl -fsSL "$SLIPDOCK_URL/cli/slipdock.escript" -o "$RUNNER_TEMP/slipdock")
  end
end
