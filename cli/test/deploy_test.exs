defmodule SlipdockCLI.DeployTest do
  @moduledoc """
  `slipdock deploy` (#1134) against a fake server and real git checkouts:
  what it asks for, what it sends (the commits since the last deploy, a
  rollback, a shallow clone deepened), that `run` passes the command's exit
  code through and records how it ended, and that a dry run records nothing.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias SlipdockCLI.{Deploy, FakeServer}

  setup do
    root = Path.join(System.tmp_dir!(), "slipdock-deploy-#{System.unique_integer([:positive])}")
    repo = Path.join(root, "repo")
    File.mkdir_p!(repo)

    saved =
      Map.new(
        ~w(HOME SLIPDOCK_URL SLIPDOCK_TOKEN SLIPDOCK_DEPLOY_TOKEN),
        &{&1, System.get_env(&1)}
      )

    System.put_env("HOME", root)
    System.put_env("SLIPDOCK_DEPLOY_TOKEN", "sdd_test")
    System.delete_env("SLIPDOCK_TOKEN")

    on_exit(fn ->
      Enum.each(saved, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)

      File.rm_rf!(root)
    end)

    git!(repo, ["init", "-q", "-b", "main"])
    %{root: root, repo: repo}
  end

  defp git!(dir, args) do
    {out, 0} =
      System.cmd(
        "git",
        ["-C", dir, "-c", "user.name=T", "-c", "user.email=t@example.com" | args],
        stderr_to_stdout: true
      )

    String.trim(out)
  end

  defp commit!(repo, message) do
    File.write!(Path.join(repo, "f.txt"), message <> "\n", [:append])
    git!(repo, ["add", "."])
    git!(repo, ["commit", "-q", "-m", message])
    git!(repo, ["rev-parse", "HEAD"])
  end

  defp serve(responses), do: System.put_env("SLIPDOCK_URL", FakeServer.start(responses))

  defp last(sha), do: {200, JSON.encode!(%{"sha" => sha, "card_ref_pattern" => nil})}

  defp created(id \\ 7, sha \\ "abc1234"),
    do:
      {201,
       JSON.encode!(%{
         "deployment" => %{"id" => id, "sha" => sha, "environment" => "production"}
       })}

  defp finished(status),
    do:
      {200, JSON.encode!(%{"deployment" => %{"id" => 7, "status" => status, "sha" => "abc1234"}})}

  test "a missing token is an error that says what to set", %{repo: repo} do
    System.delete_env("SLIPDOCK_DEPLOY_TOKEN")
    assert {:error, message} = Deploy.record_start(dir: repo)
    assert message =~ "missing SLIPDOCK_DEPLOY_TOKEN"
    assert message =~ "slipdock deploy token"
  end

  test "the first deploy sends HEAD alone, with the deploy token", %{repo: repo} do
    commit!(repo, "first (#11)")
    head = commit!(repo, "second, for #12")
    serve([last(nil), created()])

    assert {:ok, plan} = Deploy.record_start(dir: repo, env: "staging", tag: "v1")
    assert plan["deployment"]["id"] == 7

    assert_received {:request, "GET", "/api/deployments/last?environment=staging", _}
    assert_received {:headers, "GET", _, %{"authorization" => "Bearer sdd_test"}}
    assert_received {:request, "POST", "/api/deployments", body}
    body = JSON.decode!(body)
    assert body["sha"] == head
    assert body["environment"] == "staging"
    assert body["tag"] == "v1"
    assert body["source"] == "cli"
    refute body["rollback"]
    assert [%{"sha" => ^head, "message" => "second, for #12"}] = body["commits"]
  end

  test "later deploys send the commits since the last one", %{repo: repo} do
    prev = commit!(repo, "base")
    a = commit!(repo, "feat: a (#21)\n\nbody mentions #22")
    b = commit!(repo, "fix: b")
    serve([last(prev), created()])

    assert {:ok, _} = Deploy.record_start(dir: repo)
    assert_received {:request, "POST", "/api/deployments", body}
    body = JSON.decode!(body)
    assert body["previous_sha"] == prev
    assert Enum.map(body["commits"], & &1["sha"]) == [b, a]
    assert Enum.at(body["commits"], 1)["message"] =~ "body mentions #22"
    assert Enum.at(body["commits"], 1)["committed_at"] =~ ~r/^\d{4}-\d\d-\d\dT/
  end

  test "deploying something behind the last deploy is a rollback", %{repo: repo} do
    old = commit!(repo, "old")
    newer = commit!(repo, "newer")
    git!(repo, ["checkout", "-q", old])
    serve([last(newer), created()])

    out = capture_io(:stderr, fn -> assert {:ok, _} = Deploy.record_start(dir: repo) end)
    assert_received {:request, "POST", "/api/deployments", body}
    body = JSON.decode!(body)
    assert body["rollback"] == true
    assert body["commits"] == []
    assert body["previous_sha"] == newer
    assert out == ""

    assert {:ok, plan} = Deploy.plan([dir: repo], old, %{"sha" => newer})
    assert plan["rollback"]
    assert plan["range"] =~ "rollback"
  end

  test "a dry run checks the token, shows the range and cards, and records nothing", %{repo: repo} do
    prev = commit!(repo, "base")
    commit!(repo, "feat: thing (#31) and #32")
    serve([last(prev)])

    out =
      capture_io(fn ->
        assert {0, nil} = Deploy.deploy_run([dir: repo, dry_run: true], ["sh", "-c", "exit 9"])
      end)

    assert out =~ "range: #{String.slice(prev, 0, 7)}.."
    assert out =~ "1 commit"
    assert out =~ "cards: #31 #32"
    assert out =~ "recorded nothing and ran nothing"
    assert_received {:request, "GET", "/api/deployments/last" <> _, _}
    refute_received {:request, "POST", _, _}
  end

  test "a dry run uses the board's own card pattern", %{repo: repo} do
    prev = commit!(repo, "base")
    commit!(repo, "PROJ-41: done (#99)")
    serve([{200, JSON.encode!(%{"sha" => prev, "card_ref_pattern" => "PROJ-(\\d+)"})}])

    out = capture_io(fn -> Deploy.deploy_run([dir: repo, dry_run: true], ["true"]) end)
    assert out =~ "cards: #41\n"
  end

  test "run passes a failing command's exit code through and records failed", %{repo: repo} do
    commit!(repo, "x")
    serve([last(nil), created(), finished("failed")])

    capture_io(:stderr, fn ->
      assert {3, %{"status" => "failed"}} = Deploy.deploy_run([dir: repo], ["sh", "-c", "exit 3"])
    end)

    assert_received {:request, "POST", "/api/deployments", _}
    assert_received {:request, "PATCH", "/api/deployments/7", body}
    assert JSON.decode!(body) == %{"status" => "failed"}
  end

  test "run records succeeded when the command does, and its output comes through", %{repo: repo} do
    commit!(repo, "x")
    serve([last(nil), created(), finished("succeeded")])

    out =
      capture_io(fn ->
        capture_io(:stderr, fn ->
          assert {0, %{"status" => "succeeded"}} =
                   Deploy.deploy_run([dir: repo], ["echo deployed now"])
        end)
      end)

    assert out =~ "deployed now"
    assert_received {:request, "PATCH", "/api/deployments/7", body}
    assert JSON.decode!(body) == %{"status" => "succeeded"}
  end

  test "a server that refuses still lets the deploy run", %{repo: repo} do
    commit!(repo, "x")

    serve([
      {403,
       JSON.encode!(%{"error" => "delivery_metrics_off", "message" => "delivery metrics are off"})}
    ])

    err =
      capture_io(:stderr, fn ->
        assert {5, nil} = Deploy.deploy_run([dir: repo], ["sh", "-c", "exit 5"])
      end)

    assert err =~ "warning: deploy not recorded: delivery metrics are off"
    refute_received {:request, "POST", _, _}
  end

  test "an unknown command exits 127", %{repo: repo} do
    err =
      capture_io(:stderr, fn ->
        assert Deploy.run_command(["no-such-cmd-xyz"], dir: repo) == 127
      end)

    assert err =~ "command not found"
  end

  test "a shallow clone is deepened to reach the last deploy", %{root: root, repo: repo} do
    prev = commit!(repo, "one")
    commit!(repo, "two")
    head = commit!(repo, "three")
    clone = Path.join(root, "shallow")
    git!(root, ["clone", "-q", "--depth", "1", "file://" <> repo, clone])
    assert Deploy.shallow?(dir: clone)

    serve([last(prev), created()])
    assert {:ok, _} = Deploy.record_start(dir: clone)
    assert_received {:request, "POST", "/api/deployments", body}
    assert length(JSON.decode!(body)["commits"]) == 2
    assert JSON.decode!(body)["sha"] == head
  end

  test "a shallow clone that can't reach the last deploy says how to fix it", %{
    root: root,
    repo: repo
  } do
    commit!(repo, "one")
    clone = Path.join(root, "shallow")
    git!(root, ["clone", "-q", "--depth", "1", "file://" <> repo, clone])
    # A sha the origin never had: deepening and unshallowing can't find it.
    missing = String.duplicate("e", 40)

    serve([last(missing)])
    assert {:error, message} = Deploy.record_start(dir: clone)
    assert message =~ "fetch-depth: 0"
    refute_received {:request, "POST", _, _}
  end

  test "finish sends the status for the id" do
    serve([finished("succeeded")])
    assert {:ok, %{"status" => "succeeded"}} = Deploy.record_finish("7", "succeeded")
    assert_received {:request, "PATCH", "/api/deployments/7", body}
    assert JSON.decode!(body) == %{"status" => "succeeded"}
    assert_received {:headers, "PATCH", _, %{"authorization" => "Bearer sdd_test"}}
  end

  test "`deploy token` uses the API token and prints the new one", %{root: _} do
    System.put_env("SLIPDOCK_TOKEN", "api-token")
    serve([{200, JSON.encode!(%{"token" => "sdd_new", "delivery_metrics" => false})}])

    {out, err} =
      with_io(:stderr, fn -> capture_io(fn -> Deploy.run("deploy", ["token", "ship"], []) end) end)

    assert out == "sdd_new\n"
    assert err =~ "shown once"
    assert err =~ "--delivery-metrics"
    assert_received {:request, "POST", "/api/boards/ship/deploy-token", _}
    assert_received {:headers, "POST", _, %{"authorization" => "Bearer api-token"}}
  end

  test "parses `deploy run … -- cmd --flag` leaving the command's flags alone" do
    {opts, args, []} =
      OptionParser.parse(["deploy", "run", "--env", "prod", "--", "./d.sh", "--force"],
        strict: SlipdockCLI.switches()
      )

    assert opts[:env] == "prod"
    assert args == ["deploy", "run", "./d.sh", "--force"]
  end

  test "incident-of links a card to a deploy, and --clear unlinks" do
    System.put_env("SLIPDOCK_TOKEN", "api-token")

    serve([
      {200, JSON.encode!(%{"card" => 5, "incident_of" => 9})},
      {200, JSON.encode!(%{"card" => 5, "incident_of" => nil})}
    ])

    assert capture_io(fn -> Deploy.run("incident-of", ["5", "9"], []) end) =~
             "card #5 caused by deploy #9"

    assert_received {:request, "POST", "/api/cards/5/incident-of", body}
    assert JSON.decode!(body) == %{"deployment" => "9"}

    assert capture_io(fn -> Deploy.run("incident-of", ["5"], clear: true) end) =~
             "no longer names a deploy"

    assert_received {:request, "DELETE", "/api/cards/5/incident-of", _}
  end

  test "set-board sends the incident settings" do
    System.put_env("SLIPDOCK_TOKEN", "api-token")
    serve([{200, ~s({"board":{"id":3,"name":"Docs"}})}])

    {opts, _, []} =
      OptionParser.parse(
        [
          "set-board",
          "x",
          "--incident-tag",
          "sev",
          "--hotfix-hours",
          "6",
          "--card-ref-pattern",
          "J-(\\d+)"
        ],
        strict: SlipdockCLI.switches()
      )

    capture_io(fn -> SlipdockCLI.Boards.run("set-board", ["docs"], opts) end)
    assert_received {:request, "PATCH", "/api/boards/docs", body}

    assert JSON.decode!(body) == %{
             "incident_tag" => "sev",
             "hotfix_window_hours" => 6,
             "card_ref_pattern" => "J-(\\d+)"
           }
  end

  test "deploy setup posts the answers and prints the text; --prompt only asks" do
    System.put_env("SLIPDOCK_TOKEN", "api-token")

    serve([
      {200, JSON.encode!(%{"text" => "Track deployments … sdd_abc", "prompt" => "P"})},
      {200, JSON.encode!(%{"text" => "T", "prompt" => "Make this repository record its deploys"})}
    ])

    {out, err} =
      with_io(:stderr, fn ->
        capture_io(fn ->
          Deploy.run("deploy", ["setup", "ship"], ci: "gitlab", env: "prod,staging")
        end)
      end)

    assert out =~ "Track deployments … sdd_abc"
    assert err =~ "--prompt"
    assert_received {:request, "POST", "/api/boards/ship/deployments/setup", body}
    assert JSON.decode!(body) == %{"ci" => "gitlab", "environments" => "prod,staging"}

    out = capture_io(fn -> Deploy.run("deploy", ["setup", "ship"], prompt: true) end)
    assert out =~ "Make this repository record its deploys"
    assert_received {:request, "GET", "/api/boards/ship/deployments/setup", _}
    refute_received {:request, "POST", _, _}
  end
end
