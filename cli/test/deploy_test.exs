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
        ~w(HOME SLIPDOCK_URL SLIPDOCK_TOKEN SLIPDOCK_DEPLOY_TOKEN SLIPDOCK_DEPLOY_NOTE),
        &{&1, System.get_env(&1)}
      )

    System.put_env("HOME", root)
    System.put_env("SLIPDOCK_DEPLOY_TOKEN", "sdd_test")
    System.delete_env("SLIPDOCK_TOKEN")
    System.delete_env("SLIPDOCK_DEPLOY_NOTE")

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

  describe "a note on the deploy (#1857)" do
    defp posted_note(repo, o) do
      serve([last(nil), created()])
      assert {:ok, _} = Deploy.record_start([dir: repo] ++ o)
      assert_received {:request, "POST", "/api/deployments", body}
      JSON.decode!(body)
    end

    test "--note is sent, trimmed", %{repo: repo} do
      commit!(repo, "one")
      body = posted_note(repo, note: "  suite: ran \n")
      assert body["note"] == "suite: ran"
    end

    test "$SLIPDOCK_DEPLOY_NOTE is sent when there is no --note, and --note wins", %{
      repo: repo
    } do
      commit!(repo, "one")
      System.put_env("SLIPDOCK_DEPLOY_NOTE", "suite: passed on PR #9 at abc1234, same tree")
      assert posted_note(repo, [])["note"] == "suite: passed on PR #9 at abc1234, same tree"
      assert posted_note(repo, note: "suite: ran")["note"] == "suite: ran"
    end

    test "no note, or a blank one, sends none", %{repo: repo} do
      commit!(repo, "one")
      refute Map.has_key?(posted_note(repo, []), "note")
      System.put_env("SLIPDOCK_DEPLOY_NOTE", "   ")
      refute Map.has_key?(posted_note(repo, []), "note")
    end

    test "`deploy last` shows the note" do
      serve([
        {200,
         JSON.encode!(%{
           "sha" => "abc1234",
           "deployment" => %{
             "sha" => "abc1234",
             "tag" => "sha-abc1234",
             "finished_at" => "2026-11-06T05:00:00Z",
             "note" => "suite: ran"
           }
         })}
      ])

      out = capture_io(fn -> Deploy.run("deploy", ["last"], []) end)
      assert out =~ "abc1234 (sha-abc1234)  production"
      assert out =~ " · suite: ran"
    end
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

  test "parses `deploy backfill --from-runs -` with stdin as the source" do
    {opts, args, []} =
      OptionParser.parse(["deploy", "backfill", "--from-runs", "-", "--env", "production"],
        strict: SlipdockCLI.switches()
      )

    assert opts[:from_runs] == "-"
    assert args == ["deploy", "backfill"]
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

  describe "backfill --from-tags" do
    defp dated_commit!(repo, message, date) do
      File.write!(Path.join(repo, "f.txt"), message <> "\n", [:append])
      git!(repo, ["add", "."])

      {_, 0} =
        System.cmd(
          "git",
          [
            "-C",
            repo,
            "-c",
            "user.name=T",
            "-c",
            "user.email=t@example.com",
            "commit",
            "-q",
            "-m",
            message
          ],
          env: [{"GIT_COMMITTER_DATE", date}, {"GIT_AUTHOR_DATE", date}]
        )

      git!(repo, ["rev-parse", "HEAD"])
    end

    defp posted do
      receive do
        {:request, "POST", "/api/deployments", body} -> [JSON.decode!(body) | posted()]
      after
        0 -> []
      end
    end

    test "each tag in date order, with the commits since the one before", %{repo: repo} do
      a = dated_commit!(repo, "one (#1)", "2026-01-01T10:00:00Z")
      git!(repo, ["tag", "v1.0.0"])
      b = dated_commit!(repo, "two (#2)", "2026-02-01T10:00:00Z")
      c = dated_commit!(repo, "three", "2026-03-01T10:00:00Z")
      git!(repo, ["tag", "v1.1.0"])
      dated_commit!(repo, "four", "2026-04-01T10:00:00Z")
      git!(repo, ["tag", "other-1"])

      serve([last(nil), created(1), created(2)])

      assert {:ok, %{recorded: 2, existing: 0}} =
               Deploy.backfill(dir: repo, from_tags: true, pattern: "v*")

      [first, second] = posted()
      assert first["tag"] == "v1.0.0"
      assert first["sha"] == a
      assert first["source"] == "backfill"
      assert first["status"] == "succeeded"
      assert first["started_at"] =~ "2026-01-01T10:00:00"
      assert Enum.map(first["commits"], & &1["sha"]) == [a]

      assert second["tag"] == "v1.1.0"
      assert second["previous_sha"] == a
      assert Enum.map(second["commits"], & &1["sha"]) == [c, b]
    end

    test "without a pattern every tag, and a second run is counted as already there", %{
      repo: repo
    } do
      dated_commit!(repo, "one", "2026-01-01T10:00:00Z")
      git!(repo, ["tag", "a"])
      dated_commit!(repo, "two", "2026-01-02T10:00:00Z")
      git!(repo, ["tag", "b"])

      existing = {200, JSON.encode!(%{"deployment" => %{"id" => 1}, "existing" => true})}
      serve([last(nil), existing, existing])
      assert {:ok, %{recorded: 0, existing: 2}} = Deploy.backfill(dir: repo, from_tags: true)

      out =
        capture_io(fn ->
          serve([last(nil), existing, created()])
          Deploy.run("deploy", ["backfill"], dir: repo, from_tags: true)
        end)

      assert out =~ "recorded 1 deploys to production from tags (1 already there)"
    end

    test "a dry run lists the tags and records nothing", %{repo: repo} do
      dated_commit!(repo, "one", "2026-01-01T10:00:00Z")
      git!(repo, ["tag", "v1"])
      serve([last(nil)])

      out =
        capture_io(fn ->
          Deploy.run("deploy", ["backfill"], dir: repo, from_tags: true, dry_run: true)
        end)

      assert out =~ "v1  "
      assert out =~ "1 commits"
      assert out =~ "would record 1 deploys"
      assert_received {:request, "GET", "/api/deployments/last" <> _, _}
      refute_received {:request, "POST", _, _}
    end

    test "a repo with no tags sends nothing", %{repo: repo} do
      commit!(repo, "untagged")
      serve([])
      assert {:ok, %{tags: []}} = Deploy.backfill(dir: repo, from_tags: true)

      assert capture_io(fn -> Deploy.run("deploy", ["backfill"], dir: repo, from_tags: true) end) =~
               ~s(no tags match "*": nothing to record)

      refute_received {:request, _, _, _}
    end
  end

  # #1669: history was rewritten, so the last recorded deploy's commit is no
  # longer in CI's checkout and `prev..HEAD` was an invalid range.
  describe "a last deploy whose commit left the history" do
    defp last_at(sha, finished_at),
      do:
        {200,
         JSON.encode!(%{
           "sha" => sha,
           "card_ref_pattern" => nil,
           "deployment" => %{"sha" => sha, "finished_at" => finished_at}
         })}

    @gone String.duplicate("d", 40)

    test "is recorded with the commits since the newest commit before it, and warns", %{
      repo: repo
    } do
      dated_commit!(repo, "old (#40)", "2026-11-01T10:00:00Z")

      twin =
        dated_commit!(repo, "rewritten twin of the last deploy (#41)", "2026-11-02T12:31:18Z")

      a = dated_commit!(repo, "feat: after (#42)", "2026-11-02T22:50:00Z")
      b = dated_commit!(repo, "Merge PR 6: card #43", "2026-11-03T15:06:00Z")
      serve([last_at(@gone, "2026-11-02T12:36:35.161090Z"), created()])

      assert {:ok, %{"warning" => err}} = Deploy.record_start(dir: repo)

      assert err =~ "the last deploy's commit ddddddd isn't in this checkout's history"
      assert err =~ "the commits since #{String.slice(twin, 0, 7)}"
      assert_received {:request, "POST", "/api/deployments", body}
      body = JSON.decode!(body)
      assert body["sha"] == b
      assert body["previous_sha"] == @gone
      refute body["rollback"]
      assert Enum.map(body["commits"], & &1["sha"]) == [b, a]
    end

    test "start prints the deploy's id and the warning, and doesn't fail", %{repo: repo} do
      dated_commit!(repo, "one", "2026-11-01T10:00:00Z")
      dated_commit!(repo, "two (#44)", "2026-11-03T10:00:00Z")
      serve([last_at(@gone, "2026-11-02T00:00:00Z"), created(9)])

      err =
        capture_io(:stderr, fn ->
          assert capture_io(fn -> Deploy.run("deploy", ["start"], dir: repo) end) == "9\n"
        end)

      assert err =~ "warning:"
      assert err =~ "range: "
      assert err =~ "cards: #44"
    end

    test "with nothing committed before it, is recorded with no commits", %{repo: repo} do
      head = dated_commit!(repo, "all new (#45)", "2026-11-03T10:00:00Z")
      serve([last_at(@gone, "2026-11-02T00:00:00Z"), created()])

      assert {:ok, %{"warning" => err}} = Deploy.record_start(dir: repo)
      assert err =~ "recording this deploy with no commits"
      assert_received {:request, "POST", "/api/deployments", body}
      body = JSON.decode!(body)
      assert body["sha"] == head
      assert body["commits"] == []
    end

    test "with no deploy time to go by, is recorded with no commits", %{repo: repo} do
      commit!(repo, "one")
      serve([last(@gone), created()])

      assert {:ok, %{"warning" => err}} = Deploy.record_start(dir: repo)
      assert err =~ "recording this deploy with no commits"
      assert_received {:request, "POST", "/api/deployments", body}
      assert JSON.decode!(body)["commits"] == []
    end

    test "the normal range still says nothing", %{repo: repo} do
      prev = commit!(repo, "base")
      a = commit!(repo, "feat: a (#46)")
      serve([last_at(prev, "2026-11-02T00:00:00Z"), created()])

      assert {:ok, plan} = Deploy.record_start(dir: repo)
      refute plan["warning"]
      assert_received {:request, "POST", "/api/deployments", body}
      assert Enum.map(JSON.decode!(body)["commits"], & &1["sha"]) == [a]
    end

    test "a --sha the checkout hasn't got is recorded with no commits", %{repo: repo} do
      prev = commit!(repo, "base")
      serve([last(prev), created()])

      assert {:ok, %{"warning" => err}} =
               Deploy.record_start(dir: repo, sha: String.duplicate("A", 40))

      assert err =~ "aaaaaaa isn't in this checkout's history"
      assert_received {:request, "POST", "/api/deployments", body}
      body = JSON.decode!(body)
      assert body["sha"] == String.duplicate("a", 40)
      assert body["commits"] == []
    end
  end

  describe "backfill --from-runs" do
    defp runs_file!(root, runs) do
      path = Path.join(root, "runs-#{System.unique_integer([:positive])}.json")
      File.write!(path, JSON.encode!(runs))
      path
    end

    defp gh_run(sha, created, updated, conclusion \\ "success"),
      do: %{
        "headSha" => sha,
        "createdAt" => created,
        "updatedAt" => updated,
        "conclusion" => conclusion
      }

    defp existing, do: {200, JSON.encode!(%{"deployment" => %{"id" => 1}, "existing" => true})}

    test "records each successful run since the last deploy, oldest first, with its commits", %{
      root: root,
      repo: repo
    } do
      dated_commit!(repo, "rewritten twin (#50)", "2026-11-02T12:31:00Z")
      a = dated_commit!(repo, "one (#51)", "2026-11-02T22:50:00Z")
      b = dated_commit!(repo, "two (#52)", "2026-11-02T23:00:00Z")
      c = dated_commit!(repo, "three (#53)", "2026-11-02T23:10:00Z")
      d = dated_commit!(repo, "four (#54)", "2026-11-02T23:20:00Z")

      runs = [
        # Newest first, as gh lists them.
        gh_run(d, "2026-11-02T23:21:00Z", "2026-11-02T23:26:00Z"),
        gh_run(c, "2026-11-02T23:11:00Z", "2026-11-02T23:16:00Z", "failure"),
        gh_run(b, "2026-11-02T23:01:00Z", "2026-11-02T23:06:00Z"),
        # A re-run of the same sha: one deploy.
        gh_run(a, "2026-11-02T22:58:00Z", "2026-11-02T23:04:00Z"),
        gh_run(a, "2026-11-02T22:51:00Z", "2026-11-02T22:56:00Z"),
        # Recorded already, before the last deploy finished: not sent.
        gh_run(@gone, "2026-11-02T12:31:00Z", "2026-11-02T12:36:00Z")
      ]

      serve([last_at(@gone, "2026-11-02T12:36:35.161090Z"), created(1), created(2), created(3)])

      err =
        capture_io(:stderr, fn ->
          assert {:ok, %{recorded: 3, existing: 0}} =
                   Deploy.backfill_runs(from_runs: runs_file!(root, runs), dir: repo)
        end)

      assert err =~ "warning: the last deploy's commit ddddddd"

      [first, second, third] = posted()
      assert {first["sha"], second["sha"], third["sha"]} == {a, b, d}
      assert Enum.all?([first, second, third], &(&1["source"] == "backfill"))
      assert Enum.all?([first, second, third], &(&1["status"] == "succeeded"))
      assert first["started_at"] == "2026-11-02T22:51:00Z"
      assert first["finished_at"] == "2026-11-02T22:56:00Z"
      assert first["previous_sha"] == @gone
      assert Enum.map(first["commits"], & &1["sha"]) == [a]
      assert second["previous_sha"] == a
      assert Enum.map(second["commits"], & &1["sha"]) == [b]
      # The failed run's commit goes out with the next deploy.
      assert third["previous_sha"] == b
      assert Enum.map(third["commits"], & &1["sha"]) == [d, c]
    end

    test "a second run adds nothing: what the server has is counted, not recorded twice", %{
      root: root,
      repo: repo
    } do
      prev = commit!(repo, "base")
      a = commit!(repo, "one (#55)")
      b = commit!(repo, "two (#56)")

      file =
        runs_file!(root, [
          gh_run(b, "2026-11-03T02:00:00Z", "2026-11-03T02:05:00Z"),
          gh_run(a, "2026-11-03T01:00:00Z", "2026-11-03T01:05:00Z")
        ])

      serve([last_at(prev, "2026-11-03T00:00:00Z"), existing(), created()])

      out =
        capture_io(fn -> Deploy.run("deploy", ["backfill"], from_runs: file, dir: repo) end)

      assert out =~ "recorded 1 deploys to production from CI runs (1 already there)"

      # Once the server's last deploy is the newest run, nothing is sent at all.
      serve([last_at(b, "2026-11-03T02:05:00Z")])

      assert capture_io(fn -> Deploy.run("deploy", ["backfill"], from_runs: file, dir: repo) end) =~
               "no successful runs since the last recorded deploy to production"

      assert_received {:request, "GET", "/api/deployments/last" <> _, _}
      assert length(posted()) == 2
      refute_received {:request, "POST", _, _}
    end

    test "reads the runs from stdin with -, and a dry run records nothing", %{repo: repo} do
      prev = commit!(repo, "base")
      a = commit!(repo, "one (#57)")

      json =
        JSON.encode!([
          %{"sha" => a, "finished_at" => "2026-11-03T01:05:00Z", "status" => "succeeded"}
        ])

      serve([last_at(prev, "2026-11-03T00:00:00Z")])

      out =
        capture_io(json, fn ->
          Deploy.run("deploy", ["backfill"], from_runs: "-", dir: repo, dry_run: true)
        end)

      assert out =~ "#{String.slice(a, 0, 7)}  2026-11-03T01:05:00Z  1 commits"
      assert out =~ "dry run: would record 1 deploys to production; recorded nothing"
      refute_received {:request, "POST", _, _}
    end

    test "a run from before a rewrite, not in the checkout, is recorded with no commits", %{
      root: root,
      repo: repo
    } do
      prev = commit!(repo, "base")
      serve([last_at(prev, "2026-11-03T00:00:00Z"), created()])
      file = runs_file!(root, [gh_run(@gone, "2026-11-03T01:00:00Z", "2026-11-03T01:05:00Z")])

      err =
        capture_io(:stderr, fn ->
          assert {:ok, %{recorded: 1}} = Deploy.backfill_runs(from_runs: file, dir: repo)
        end)

      assert err =~ "ddddddd isn't in this checkout's history"
      assert [%{"sha" => @gone, "commits" => []}] = posted()
    end

    test "a file that isn't there, or isn't a list of runs, is an error", %{root: root} do
      serve([])
      missing = Path.join(root, "nope.json")
      assert {:error, message} = Deploy.backfill_runs(from_runs: missing)
      assert message =~ "couldn't read #{missing}"

      bad = Path.join(root, "bad.json")
      File.write!(bad, ~s({"not": "a list"}))
      assert {:error, message} = Deploy.backfill_runs(from_runs: bad)
      assert message =~ "expected a JSON list of runs"
      refute_received {:request, _, _, _}
    end
  end
end
