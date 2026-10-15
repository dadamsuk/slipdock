defmodule SlipdockCLI.PasskeysTest do
  @moduledoc "`slipdock passkeys`: listing and removing your own passkeys (#828)."
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias SlipdockCLI.{Auth, FakeServer}

  setup do
    home = Path.join(System.tmp_dir!(), "slipdock-passkeys-#{System.unique_integer([:positive])}")
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
  end

  defp serve(responses), do: System.put_env("SLIPDOCK_URL", FakeServer.start(responses))

  @two ~s({"passkeys":[{"id":3,"name":"Laptop","created_at":"2026-10-01T09:00:00Z","last_used_at":"2026-10-14T08:00:00Z"},{"id":4,"name":"Phone","created_at":"2026-10-02T09:00:00Z","last_used_at":null}]})

  test "lists them with when each was added and last used" do
    serve([{200, @two}])
    out = capture_io(fn -> Auth.run("passkeys", [], []) end)

    assert_received {:request, "GET", "/api/me/passkeys", _}
    assert out =~ "LAST USED"
    assert out =~ ~r/3\s+Laptop\s+2026-10-01\s+2026-10-14/
    assert out =~ ~r/4\s+Phone\s+2026-10-02\s+never/
  end

  test "none says where to add one" do
    serve([{200, ~s({"passkeys":[]})}])
    assert capture_io(fn -> Auth.run("passkeys", [], []) end) =~ "add one in a browser"
  end

  test "--json passes the answer through" do
    serve([{200, @two}])
    json = capture_io(fn -> Auth.run("passkeys", [], json: true) end)
    assert %{"passkeys" => [%{"id" => 3}, %{"id" => 4}]} = JSON.decode!(json)
  end

  test "remove deletes by id and shows what is left" do
    serve([{200, ~s({"passkeys":[{"id":4,"name":"Phone","created_at":"2026-10-02T09:00:00Z"}]})}])
    out = capture_io(fn -> Auth.run("passkeys", ["remove", "3"], []) end)

    assert_received {:request, "DELETE", "/api/me/passkeys/3", _}
    assert out =~ "removed passkey 3"
    assert out =~ "Phone"
  end

  test "rm is the same, and the id is sent escaped" do
    serve([{200, ~s({"passkeys":[]})}])
    out = capture_io(fn -> Auth.run("passkeys", ["rm", "3/x"], []) end)

    assert_received {:request, "DELETE", "/api/me/passkeys/3%2Fx", _}
    assert out =~ "no passkeys"
  end
end
