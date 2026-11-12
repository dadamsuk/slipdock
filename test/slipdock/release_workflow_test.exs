defmodule Slipdock.ReleaseWorkflowTest do
  @moduledoc """
  The deploy job in .github/workflows/release.yml. These are the lines whose
  loss would not show until it mattered: a deploy reachable from a pull
  request, one that cancels another mid-restart, one of a tag that moves, or
  one whose suite a newer push could cancel (#2832).
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

  # OPS-2, with a dispatched release of main admitted (#2837).
  @released "((github.event_name == 'push' && (github.ref == 'refs/heads/main' || startsWith(github.ref, 'refs/tags/v'))) || (github.event_name == 'workflow_dispatch' && github.ref == 'refs/heads/main'))"
  @not_batched_push "!(github.event_name == 'push' && github.ref == 'refs/heads/main' && vars.RELEASE_MODE == 'batched')"

  test "deploys only pushes to main or v* tags and dispatched releases of main, after the suite and the image" do
    job = deploy_job()

    assert has?(job, "needs: [suite, test, merge]")

    # merge succeeds only on a passed suite, or one the gate skipped (#1857).
    assert has?(
             job,
             "if: ${{ !cancelled() && needs.merge.result == 'success' && #{@released} }}"
           )
  end

  describe "batched releases (#2837)" do
    defp jobs do
      {:ok, yaml} = YamlElixir.read_from_string(@release)
      yaml["jobs"]
    end

    test "a push to main on a batched board runs none of the jobs a release starts with" do
      jobs = jobs()
      assert jobs["suite"]["if"] == "${{ #{@not_batched_push} }}"
      assert jobs["test"]["if"] == "${{ !cancelled() && #{@not_batched_push} }}"
      assert jobs["build"]["if"] =~ "${{ !cancelled() && #{@not_batched_push} && "

      # The tag-only jobs never run for a push to main, batched or not.
      for name <- ~w(cli-build daemon-build) do
        assert jobs[name]["if"] =~ "startsWith(github.ref, 'refs/tags/v')", name
      end

      # Every job that doesn't start one waits on one that does.
      roots = for {name, job} <- jobs, job["needs"] in [nil, []], do: name
      assert Enum.sort(roots) == ~w(cli-build daemon-build suite)
    end

    test "a failed dispatched release is recorded as a push's is" do
      assert jobs()["record-failure"]["if"] == "${{ failure() && #{@released} }}"
    end

    test "a batched push has a group of its own, so it never replaces a waiting release" do
      {:ok, yaml} = YamlElixir.read_from_string(@release)
      group = yaml["concurrency"]["group"]

      assert group ==
               "${{ github.event_name == 'push' && github.ref == 'refs/heads/main' && vars.RELEASE_MODE == 'batched' && format('release-skipped-{0}', github.run_id) || format('release-{0}', github.ref) }}"

      assert yaml["concurrency"]["cancel-in-progress"] == false
      assert Map.has_key?(yaml["on"], "workflow_dispatch")
    end

    test "the backfill counts no batched push as a deploy" do
      job = Enum.join(deploy_job(), "\n")
      assert job =~ "--json headSha,createdAt,updatedAt,conclusion,event |"
      assert job =~ ~S{jq '[.[] | select(env.RELEASE_MODE != "batched" or .event != "push")]' |}
      assert job =~ "RELEASE_MODE: ${{ vars.RELEASE_MODE }}"
    end
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
    # LOCAL_DEPLOY_USER on a self-hosted runner, which deploys as the
    # machine's own tailnet node (#2829).
    assert has?(
             job,
             "DEPLOY_USER: ${{ vars.CI_RUNNER && vars.LOCAL_DEPLOY_USER || vars.DEPLOY_USER }}"
           )

    assert has?(job, "HEALTH_URL: ${{ secrets.DEPLOY_HEALTH_URL }}")
    refute Enum.any?(job, &(&1 =~ ~r/ts\.net|BEGIN OPENSSH|ssh-ed25519/))
  end

  # OPS-2: the suite a deploy waits for is ci.yml, called from here (#2832).
  describe "the suite it calls" do
    defp yaml(text) do
      {:ok, yaml} = YamlElixir.read_from_string(text)
      yaml
    end

    test "is never cancelled: only a pull request's run cancels, in a group a release can't share" do
      concurrency = yaml(@ci)["concurrency"]
      assert concurrency["cancel-in-progress"] == "${{ github.event_name == 'pull_request' }}"
      assert concurrency["group"] =~ "|| github.run_id }}"
    end

    test "is called for every push and tag, so the static checks run on main and the release" do
      test_job = yaml(@release)["jobs"]["test"]
      assert test_job["uses"] == "./.github/workflows/ci.yml"
      assert test_job["if"] == "${{ !cancelled() && #{@not_batched_push} }}"

      # Skipped in ci.yml only on events a release never is.
      assert yaml(@ci)["jobs"]["static"]["if"] ==
               "github.event_name != 'pull_request' && github.event_name != 'schedule'"
    end

    test "passes only when every job in it passed or was skipped, so merge and deploy wait on it" do
      passed = yaml(@ci)["jobs"]["passed"]
      assert passed["if"] == "always()"
      assert yaml(@release)["jobs"]["merge"]["if"] =~ "needs.test.result == 'success'"
      assert "merge" in yaml(@release)["jobs"]["deploy"]["needs"]
    end
  end

  test "fails unless the server is healthy on the deployed commit" do
    job = Enum.join(deploy_job(), "\n")
    assert job =~ ~s(select(.status == "ok"\) | .sha)
    assert job =~ ~s(= "$GITHUB_SHA")
    assert job =~ "exit 1"
  end
end
