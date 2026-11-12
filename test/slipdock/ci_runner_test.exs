defmodule Slipdock.CiRunnerTest do
  @moduledoc """
  Where the workflows run (#2829). Every job reads the repository variable
  CI_RUNNER: unset, GitHub's runners; set, the self-hosted runners with that
  label, which a private repository doesn't pay for. Those runners share one
  machine, so no job publishes a fixed port or leaves files in /tmp for the
  next job to find, and the deploy uses the machine's own tailnet node rather
  than installing Tailscale over it.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)
  @workflows ~w(ci.yml release.yml ghcr-cleanup.yml)
  @runs_on "${{ vars.CI_RUNNER || 'ubuntu-latest' }}"

  defp workflow(file) do
    {:ok, yaml} = YamlElixir.read_from_file(Path.join(@root, ".github/workflows/#{file}"))
    yaml
  end

  defp jobs(file), do: workflow(file)["jobs"]
  defp step(job, key, value), do: Enum.find(job["steps"], &(&1[key] == value))
  defp step_at(job, key, value), do: Enum.find_index(job["steps"], &(&1[key] == value))

  # A workflow's lines that aren't comments.
  defp code_lines(file) do
    Path.join(@root, ".github/workflows/#{file}")
    |> File.read!()
    |> String.split("\n")
    |> Enum.reject(&(String.trim_leading(&1) |> String.starts_with?("#")))
  end

  test "every job runs on CI_RUNNER's runners, or GitHub's when it is unset" do
    for file <- @workflows, {name, job} <- jobs(file), not Map.has_key?(job, "uses") do
      expected = if {file, name} == {"ci.yml", "daemon"}, do: "${{ matrix.os }}", else: @runs_on
      assert job["runs-on"] == expected, "#{file}: #{name} runs on #{inspect(job["runs-on"])}"
    end
  end

  test "a newer push to a pull request cancels its older run, never a push to main's" do
    ci = workflow("ci.yml")

    assert ci["concurrency"] == %{
             "group" =>
               "ci-${{ github.event.pull_request.number && format('pr-{0}', github.event.pull_request.number) || github.run_id }}",
             "cancel-in-progress" => true
           }

    # release.yml has no group of its own that a cancelling CI run could share.
    refute Map.has_key?(workflow("release.yml"), "concurrency")
  end

  test "the daemon's OS list is CI_RUNNER alone when set, the three OSes when not" do
    os = jobs("ci.yml")["daemon"]["strategy"]["matrix"]["os"]

    assert os ==
             ~s<${{ fromJSON(vars.CI_RUNNER && format('["{0}"]', vars.CI_RUNNER) || '["ubuntu-latest", "macos-latest", "windows-latest"]') }}>

    # The fallback is valid JSON naming the three OSes the daemon ships for.
    [_, fallback] = Regex.run(~r/\|\| '(\[[^']+\])'/, os)
    assert Jason.decode!(fallback) == ["ubuntu-latest", "macos-latest", "windows-latest"]
  end

  test "the Windows leg alone skips the executor tests, so a self-hosted Linux runs them" do
    env = step(jobs("ci.yml")["daemon"], "name", "Test")["env"]
    assert env["SLIPDOCK_EXECUTOR_TESTS"] == "${{ matrix.os != 'windows-latest' && '1' || '' }}"
  end

  test "no service publishes a fixed host port" do
    for file <- @workflows,
        {name, job} <- jobs(file),
        {service, spec} <- job["services"] || %{} do
      for port <- spec["ports"] || [] do
        refute to_string(port) =~ ":", "#{file}: #{name}'s #{service} publishes #{port}"
      end
    end
  end

  test "the suite finds Postgres on the port Docker gave it" do
    test_job = jobs("ci.yml")["test"]
    assert test_job["services"]["postgres"]["ports"] == [5432]

    assert step(test_job, "name", "Test")["env"]["TEST_DATABASE_URL"] ==
             "postgres://postgres:postgres@localhost:${{ job.services.postgres.ports['5432'] }}/slipdock_test"

    assert File.read!(Path.join(@root, "config/test.exs")) =~
             ~s[System.get_env("TEST_DATABASE_URL")]
  end

  test "no job keeps files in /tmp, which the jobs on one machine share" do
    for file <- @workflows, line <- code_lines(file) do
      refute line =~ ~r{(^|[\s"'=])/tmp\b}, "#{file}: #{String.trim(line)}"
    end
  end

  test "the digests go from the build job to the merge job through RUNNER_TEMP" do
    jobs = jobs("release.yml")
    build = Enum.join(code_lines("release.yml"), "\n")

    assert build =~ ~s(mkdir -p "$RUNNER_TEMP/digests")

    assert step(jobs["build"], "uses", "actions/upload-artifact@v4")["with"]["path"] ==
             "${{ runner.temp }}/digests/*"

    assert step(jobs["merge"], "uses", "actions/download-artifact@v4")["with"]["path"] ==
             "${{ runner.temp }}/digests"

    assert step(jobs["merge"], "name", "Stitch the architectures into one tag")[
             "working-directory"
           ] == "${{ runner.temp }}/digests"
  end

  test "the image build takes BuildKit's settings from BUILDKITD_CONFIG, and names no server" do
    buildx = step(jobs("release.yml")["build"], "uses", "docker/setup-buildx-action@v3")
    assert buildx["with"]["buildkitd-config-inline"] == "${{ vars.BUILDKITD_CONFIG }}"

    # The nameservers are the machine's, kept in the repository's settings,
    # never in this public file.
    refute Enum.any?(
             code_lines("release.yml"),
             &(&1 =~ ~r/nameservers|\b\d{1,3}(\.\d{1,3}){3}\b/)
           )
  end

  test "the image is built for amd64 alone, and the README says so" do
    include = jobs("release.yml")["build"]["strategy"]["matrix"]["include"]
    assert include == [%{"platform" => "linux/amd64"}]

    readme = File.read!(Path.join(@root, "README.md"))
    assert readme =~ "The image is built for `amd64`."
    refute readme =~ ~r/image is built for[^.]*arm64/
  end

  describe "the deploy" do
    defp deploy, do: jobs("release.yml")["deploy"]

    test "joins the tailnet by the action only on GitHub's runners" do
      assert step(deploy(), "uses", "tailscale/github-action@v4")["if"] ==
               "${{ !vars.CI_RUNNER }}"
    end

    test "on a self-hosted runner, checks the machine's own node reaches the server first" do
      reach = step(deploy(), "name", "Reach the server over this machine's tailnet")
      assert reach["if"] == "${{ vars.CI_RUNNER }}"
      assert reach["run"] == ~s(sudo -n tailscale ping -c 5 "$DEPLOY_HOST")
      assert reach["env"] == %{"DEPLOY_HOST" => "${{ secrets.DEPLOY_HOST }}"}

      assert step_at(deploy(), "name", "Reach the server over this machine's tailnet") <
               step_at(deploy(), "name", "Deploy")
    end

    test "deploys the same way on either runner, as LOCAL_DEPLOY_USER on a self-hosted one" do
      deploy_step = step(deploy(), "name", "Deploy")
      refute Map.has_key?(deploy_step, "if")

      assert deploy_step["env"]["DEPLOY_USER"] ==
               "${{ vars.CI_RUNNER && vars.LOCAL_DEPLOY_USER || vars.DEPLOY_USER }}"
    end
  end
end
