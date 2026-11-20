defmodule SlipdockCLI.PoolGrantsTest do
  @moduledoc """
  `slipdock pool-grants <board>` and `slipdock pool-grant <board> <pool>
  [EMAIL] [--off]` (#3492): what they send and print. The server's side is
  in `test/slipdock_web/controllers/api/pool_grants_test.exs`.
  """
  # Sync: sets HOME and the SLIPDOCK_* variables, one environment per VM.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias SlipdockCLI.{FakeServer, Runners}

  @vars ~w(HOME CLAUDECODE SLIPDOCK_JOB_ID SLIPDOCK_URL SLIPDOCK_TOKEN KANBAN_TOKEN)

  setup do
    home = Path.join(System.tmp_dir!(), "slipdock-pools-#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    saved = Map.new(@vars, &{&1, System.get_env(&1)})
    Enum.each(@vars, &System.delete_env/1)
    System.put_env("HOME", home)
    System.put_env("SLIPDOCK_TOKEN", "test-token")

    on_exit(fn ->
      Enum.each(saved, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)

      File.rm_rf!(home)
    end)
  end

  @grant %{
    "id" => 9,
    "pool" => "dev",
    "user" => %{"id" => 2, "email" => "pat@example.com", "name" => "Pat"},
    "granted_by" => "owner@example.com"
  }

  defp serve(responses), do: System.put_env("SLIPDOCK_URL", FakeServer.start(responses))

  test "the --off switch parses" do
    {opts, ["pool-grant", "ops", "dev", "pat@example.com"], []} =
      OptionParser.parse(["pool-grant", "ops", "dev", "pat@example.com", "--off"],
        strict: SlipdockCLI.switches()
      )

    assert opts[:off] == true
  end

  test "pool-grant with an email grants the pool, and says so" do
    serve([{201, JSON.encode!(%{"pool_grant" => @grant})}])

    out = capture_io(fn -> Runners.run("pool-grant", ["ops", "dev", "pat@example.com"], []) end)

    assert_received {:request, "POST", "/api/boards/ops/pool-grants", sent}
    assert JSON.decode!(sent) == %{"pool" => "dev", "email" => "pat@example.com"}
    assert out == "pat@example.com takes pool dev's jobs now\n"
  end

  test "--off takes it back" do
    revoked = %{"revoked" => %{"pool" => "dev", "email" => "pat@example.com"}}
    serve([{200, JSON.encode!(revoked)}])

    out =
      capture_io(fn ->
        Runners.run("pool-grant", ["ops", "dev", "pat@example.com"], off: true)
      end)

    assert_received {:request, "DELETE", "/api/boards/ops/pool-grants?" <> query, _}
    assert URI.decode_query(query) == %{"pool" => "dev", "email" => "pat@example.com"}
    assert out == "pat@example.com no longer takes pool dev's jobs\n"
  end

  test "pool-grant with no email lists the pool's grants; pool-grants lists every pool's" do
    serve([
      {200, JSON.encode!(%{"pool_grants" => [@grant]})},
      {200, JSON.encode!(%{"pool_grants" => []})}
    ])

    out = capture_io(fn -> Runners.run("pool-grant", ["ops", "dev"], []) end)
    assert_received {:request, "GET", "/api/boards/ops/pool-grants?pool=dev", _}
    assert out == "dev  pat@example.com  (granted by owner@example.com)\n"

    out = capture_io(fn -> Runners.run("pool-grants", ["ops"], []) end)
    assert_received {:request, "GET", "/api/boards/ops/pool-grants", _}
    assert out =~ "no pool grants: only the board's owner"
  end
end
