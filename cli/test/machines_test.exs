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
