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
    "job.status == 'success' && 'succeeded' || 'failed'"
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

  test "the wizard's GitHub step installs the CLI the same way" do
    snippet = Slipdock.Deployments.Setup.snippet("github", "production")
    assert snippet =~ "fetch-depth: 0"
    assert snippet =~ "erlef/setup-beam@v1"

    assert snippet =~
             ~s(curl -fsSL "$SLIPDOCK_URL/cli/slipdock.escript" -o "$RUNNER_TEMP/slipdock")
  end
end
