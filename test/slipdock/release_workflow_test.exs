defmodule Slipdock.ReleaseWorkflowTest do
  @moduledoc """
  The deploy job in .github/workflows/release.yml. These are the lines whose
  loss would not show until it mattered: a deploy reachable from a pull
  request, one that cancels another mid-restart, or one of a tag that moves.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)
  @release File.read!(Path.join(@root, ".github/workflows/release.yml"))
  @ci File.read!(Path.join(@root, ".github/workflows/ci.yml"))

  # Comments stripped, so something mentioned only in a comment does not count.
  defp lines(text),
    do:
      text
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))

  # The deploy job's own lines: from `deploy:` to the end of the file, where
  # it sits.
  defp deploy_job do
    [_, job] = String.split(@release, "\n  deploy:\n", parts: 2)
    lines(job)
  end

  defp has?(lines, line), do: line in lines

  test "nothing in either workflow runs on pull_request_target" do
    refute Enum.any?(lines(@release) ++ lines(@ci), &(&1 =~ "pull_request_target"))
  end

  test "the release workflow is not triggered by pull requests at all" do
    refute Enum.any?(lines(@release), &(&1 =~ ~r/^pull_request/))
  end

  test "deploys only pushes to main or v* tags, after the suite and the image" do
    job = deploy_job()

    assert has?(job, "needs: [test, merge]")

    assert has?(
             job,
             "if: github.event_name == 'push' && (github.ref == 'refs/heads/main' || startsWith(github.ref, 'refs/tags/v'))"
           )
  end

  test "through the production environment, with only the token it needs" do
    job = deploy_job()
    assert has?(job, "environment: production")
    assert has?(job, "id-token: write")
    assert has?(job, "contents: read")
    refute Enum.any?(job, &(&1 =~ "packages: write"))
  end

  test "never overlaps another deploy and never cancels one" do
    job = deploy_job()
    assert has?(job, "group: production-deploy")
    assert has?(job, "cancel-in-progress: false")
  end

  test "joins the tailnet as an ephemeral tag:ci node by workload identity" do
    job = deploy_job()
    assert has?(job, "- uses: tailscale/github-action@v4")
    assert has?(job, "oauth-client-id: ${{ secrets.TS_OAUTH_CLIENT_ID }}")
    assert has?(job, "audience: ${{ secrets.TS_AUDIENCE }}")
    assert has?(job, "tags: tag:ci")
    # No long-lived Tailscale secret: federation only.
    refute Enum.any?(job, &(&1 =~ ~r/oauth-secret|authkey/))
  end

  test "deploys the pinned tag the merge job picked, never latest" do
    job = deploy_job()
    assert has?(lines(@release), "deploy-tag: ${{ steps.pin.outputs.tag }}")
    assert has?(job, "TAG: ${{ needs.merge.outputs.deploy-tag }}")

    refute Enum.any?(job, &(&1 =~ ~r/:latest|"latest"/))
  end

  test "runs deploy.sh as root over Tailscale SSH, with no SSH key to keep" do
    job = deploy_job()

    assert has?(
             job,
             ~s(sudo tailscale ssh "$DEPLOY_USER@$DEPLOY_HOST" sudo -n /opt/deploy/deploy.sh "$TAG")
           )

    refute Enum.any?(job, &(&1 =~ ~r/DEPLOY_SSH|known_hosts|StrictHostKeyChecking=no/))
  end

  test "checks the tag with the same pattern deploy.sh does, before the remote shell sees it" do
    [_, workflow_pattern] = Regex.run(~r/grep -Eqx '([^']+)' <<< "\$TAG"/, @release)
    script = File.read!(Path.join(@root, "deploy/deploy.sh"))
    [_, script_pattern] = Regex.run(~r/grep -Eqx '([^']+)'/, script)

    assert workflow_pattern == script_pattern
  end

  test "the server's name and user come from settings, not the file" do
    job = deploy_job()
    assert has?(job, "DEPLOY_HOST: ${{ secrets.DEPLOY_HOST }}")
    assert has?(job, "DEPLOY_USER: ${{ vars.DEPLOY_USER }}")
    assert has?(job, "HEALTH_URL: ${{ secrets.DEPLOY_HEALTH_URL }}")
    refute Enum.any?(job, &(&1 =~ ~r/ts\.net|BEGIN OPENSSH|ssh-ed25519/))
  end

  test "fails unless the server is healthy on the deployed commit" do
    job = Enum.join(deploy_job(), "\n")
    assert job =~ ~s(select(.status == "ok"\) | .sha)
    assert job =~ ~s(= "$GITHUB_SHA")
    assert job =~ "exit 1"
  end
end
