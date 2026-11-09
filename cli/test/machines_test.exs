defmodule SlipdockCLI.MachinesTest do
  @moduledoc "`slipdock machines` / `machine …` (#2570): what each sends, and what it shows."
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias SlipdockCLI.{FakeServer, Machines}

  setup do
    home = Path.join(System.tmp_dir!(), "slipdock-machines-#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    saved = Map.new(~w(HOME SLIPDOCK_URL SLIPDOCK_TOKEN KANBAN_TOKEN), &{&1, System.get_env(&1)})
    System.put_env("HOME", home)
    System.put_env("SLIPDOCK_TOKEN", "test-token")
    Enum.each(~w(SLIPDOCK_URL KANBAN_TOKEN), &System.delete_env/1)

    on_exit(fn ->
      Enum.each(saved, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)

      File.rm_rf!(home)
    end)

    :ok
  end

  defp serve(responses), do: System.put_env("SLIPDOCK_URL", FakeServer.start(responses))

  @machine %{
    "id" => 4,
    "name" => "build-box",
    "hostname" => "build-box",
    "os" => "linux",
    "arch" => "amd64",
    "fingerprint" => "SHA256:abc",
    "boards" => [3, 9],
    "state" => "enrolled",
    "enrolled_via" => "device_code",
    "enrolled_at" => "2026-11-09T02:00:00Z",
    "last_seen_at" => nil,
    "revoked_at" => nil
  }

  test "machines lists the account's machines" do
    serve([{200, JSON.encode!(%{"machines" => [@machine]})}])
    out = capture_io(fn -> Machines.run("machines", [], []) end)

    assert_received {:request, "GET", "/api/machines", _}
    assert out =~ ~r/#4\s+build-box\s+linux amd64\s+enrolled\s+3,9\s+never/
  end

  test "no machines says how to enrol one" do
    serve([{200, JSON.encode!(%{"machines" => []})}])
    assert capture_io(fn -> Machines.run("machine", ["ls"], []) end) =~ "slipdock-runner init"
  end

  test "machine show prints the machine in full" do
    serve([{200, JSON.encode!(%{"machine" => @machine})}])
    out = capture_io(fn -> Machines.run("machine", ["show", "4"], []) end)

    assert_received {:request, "GET", "/api/machines/4", _}
    assert out =~ "Machine #4 build-box"
    assert out =~ "Fingerprint: SHA256:abc"
    assert out =~ "by device_code"
    refute out =~ "Revoked:"
  end

  test "machine revoke deletes it and says the key is dead" do
    revoked = Map.merge(@machine, %{"state" => "revoked", "revoked_at" => "2026-11-09T03:00:00Z"})
    serve([{200, JSON.encode!(%{"machine" => revoked})}])
    out = capture_io(fn -> Machines.run("machine", ["revoke", "4"], []) end)

    assert_received {:request, "DELETE", "/api/machines/4", _}
    assert out =~ "revoked machine #4 build-box: its key no longer works"
  end

  test "machine enrol-key sends the boards and label, and prints the init line once" do
    serve([
      {201, JSON.encode!(%{"enrolment_key" => "sde_xyz", "valid_hours" => 24, "boards" => [3]})}
    ])

    out =
      capture_io(fn -> Machines.run("machine", ["enrol-key", "slipdock", "7"], label: "ci") end)

    assert_received {:request, "POST", "/api/machines/enrolment-keys", body}
    assert JSON.decode!(body) == %{"boards" => ["slipdock", "7"], "label" => "ci"}
    assert out =~ "slipdock-runner init --key sde_xyz"
    assert out =~ "24 hours"
  end

  test "machine enrolment shows the machine to check before approving" do
    enrolment = %{
      "hostname" => "build-box",
      "os" => "linux",
      "arch" => "arm64",
      "fingerprint" => "SHA256:abc",
      "client_ip" => "192.0.2.1",
      "state" => "pending"
    }

    serve([{200, JSON.encode!(%{"enrolment" => enrolment})}])
    out = capture_io(fn -> Machines.run("machine", ["enrolment", "BCDF-GHJK"], []) end)

    assert_received {:request, "GET", "/api/machines/enrolment?user_code=BCDF-GHJK", _}
    assert out =~ "Machine asking to enrol: build-box"
    assert out =~ "Fingerprint: SHA256:abc"
    assert out =~ "linux arm64"
    assert out =~ "slipdock machine approve"
  end

  test "machine approve sends the code and boards; refuse sends the code" do
    serve([
      {200, JSON.encode!(%{"enrolment" => %{"hostname" => "build-box", "state" => "approved"}})},
      {200, JSON.encode!(%{"enrolment" => %{"hostname" => "build-box", "state" => "refused"}})}
    ])

    out = capture_io(fn -> Machines.run("machine", ["approve", "BCDF", "slipdock", "4"], []) end)
    assert_received {:request, "POST", "/api/machines/enrolment/approve", body}
    assert JSON.decode!(body) == %{"user_code" => "BCDF", "boards" => ["slipdock", "4"]}
    assert out =~ "approved build-box"

    out = capture_io(fn -> Machines.run("machine", ["refuse", "BCDF"], []) end)
    assert_received {:request, "POST", "/api/machines/enrolment/refuse", body}
    assert JSON.decode!(body) == %{"user_code" => "BCDF"}
    assert out =~ "refused build-box"
  end

  describe "a machine's runners (#2572)" do
    test "add-runner sends the board, pool and typed config from the switches" do
      serve([
        {201,
         JSON.encode!(%{
           "runner" => %{"id" => 9, "name" => "build-box build", "config_version" => 1}
         })}
      ])

      out =
        capture_io(fn ->
          Machines.run("machine", ["add-runner", "4", "slipdock"],
            pool: "build",
            dir: "/srv/src/app",
            timeout_minutes: 30,
            permission_mode: "acceptEdits",
            executor: "me",
            before_hook: "fetch",
            worktree: false
          )
        end)

      assert_received {:request, "POST", "/api/machines/4/runners", body}

      assert JSON.decode!(body) == %{
               "board" => "slipdock",
               "pool" => "build",
               "config" => %{
                 "directory" => "/srv/src/app",
                 "timeout_minutes" => 30,
                 "permission_mode" => "acceptEdits",
                 "executor" => "me",
                 "before_hook" => "fetch",
                 "worktree" => "off"
               }
             }

      assert out =~ "added runner #9 build-box build (v1)"
    end

    test "add-runner needs a pool and a directory" do
      assert {:error, "usage: " <> _} = Machines.plan(["add-runner", "4", "b"], pool: "x")
      assert {:error, "usage: " <> _} = Machines.plan(["add-runner", "4", "b"], dir: "/x")
    end

    test "set-runner sends only what is given" do
      serve([
        {200, JSON.encode!(%{"runner" => %{"id" => 9, "name" => "b", "config_version" => 3}})}
      ])

      out =
        capture_io(fn ->
          Machines.run("machine", ["set-runner", "4", "9"], model: "sonnet", worktree: true)
        end)

      assert_received {:request, "PATCH", "/api/machines/4/runners/9", body}
      assert JSON.decode!(body) == %{"config" => %{"model" => "sonnet", "worktree" => "on"}}
      assert out =~ "runner #9 b is now v3"
    end

    test "pause-runner, resume-runner, rm-runner and update" do
      serve([
        {200, JSON.encode!(%{"runner" => %{"name" => "b", "paused" => true}})},
        {200, JSON.encode!(%{"runner" => %{"name" => "b", "paused" => false}})},
        {200, JSON.encode!(%{"removed" => %{"name" => "b"}})},
        {200, JSON.encode!(%{"machine" => %{"name" => "build-box"}})}
      ])

      out = capture_io(fn -> Machines.run("machine", ["pause-runner", "4", "b"], []) end)
      assert_received {:request, "POST", "/api/machines/4/runners/b/pause", _}
      assert out =~ "paused b: it takes no job until resumed"

      out = capture_io(fn -> Machines.run("machine", ["resume-runner", "4", "b"], []) end)
      assert_received {:request, "POST", "/api/machines/4/runners/b/resume", _}
      assert out =~ "b takes jobs again"

      out = capture_io(fn -> Machines.run("machine", ["rm-runner", "4", "b"], []) end)
      assert_received {:request, "DELETE", "/api/machines/4/runners/b", _}
      assert out =~ "removed b"

      out = capture_io(fn -> Machines.run("machine", ["update", "4"], []) end)
      assert_received {:request, "POST", "/api/machines/4/update", _}
      assert out =~ "asked build-box to update now"
    end

    test "show prints the ceiling, the runners, a refusal with its limit, and the log" do
      machine =
        Map.merge(@machine, %{
          "ceiling" => %{
            "roots" => ["/srv/src"],
            "agents" => ["claude"],
            "max_permission_mode" => "acceptEdits",
            "max_timeout_minutes" => 60,
            "executors" => ["user"]
          },
          "runners" => [
            %{
              "id" => 9,
              "name" => "builder",
              "pool" => "build",
              "config" => %{
                "agent" => "claude",
                "directory" => "/srv/src/app",
                "permission_mode" => "acceptEdits",
                "executor" => "user"
              },
              "config_version" => 2,
              "accepted_version" => 1,
              "rejected_version" => 2,
              "rejection" => "timeout over the ceiling",
              "outside_ceiling" => ["timeout 240 minutes is over 60"],
              "paused" => false
            },
            %{
              "id" => 10,
              "name" => "idle",
              "pool" => "x",
              "config" => %{},
              "config_version" => 1,
              "accepted_version" => 1,
              "paused" => true
            }
          ],
          "changes" => [
            %{
              "at" => "2026-11-09T04:00:00Z",
              "runner" => "builder",
              "version" => 2,
              "outcome" => "rejected",
              "reason" => "timeout over the ceiling"
            }
          ]
        })

      serve([{200, JSON.encode!(%{"machine" => machine})}])
      out = capture_io(fn -> Machines.run("machine", ["show", "4"], []) end)

      assert out =~ "Max timeout: 60 minutes"

      assert out =~
               ~r/#9\s+builder\s+build\s+claude\s+\/srv\/src\/app\s+acceptEdits\s+user\s+rejected v2/

      assert out =~ ~r/#10\s+idle.*paused/
      assert out =~ "builder: v2 refused: timeout over the ceiling"
      assert out =~ "outside the ceiling: timeout 240 minutes is over 60"
      assert out =~ "builder v2 rejected: timeout over the ceiling"
    end

    test "machines lists the ones serving your boards after your own" do
      shared = Map.merge(@machine, %{"id" => 5, "name" => "their-box"})
      serve([{200, JSON.encode!(%{"machines" => [@machine], "shared" => [shared]})}])
      out = capture_io(fn -> Machines.run("machines", [], []) end)

      assert out =~ "Serving your boards"
      assert out =~ ~r/#5\s+their-box/
    end
  end

  test "anything else is the usage: no board, no code, an unknown verb" do
    for args <- [
          ["enrol-key"],
          ["approve", "BCDF"],
          ["approve"],
          ["refuse"],
          ["enrolment"],
          ["show"],
          ["frobnicate"],
          []
        ] do
      assert {:error, "usage: slipdock machines" <> _} = Machines.plan(args, []), inspect(args)
    end

    assert {:ok, :post, _, %{"boards" => ["a"]} = body, _} =
             Machines.plan(["enrol-key", "a"], [])

    refute Map.has_key?(body, "label")
  end
end
