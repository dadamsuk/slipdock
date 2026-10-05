defmodule SlipdockCLI.AdminTest do
  @moduledoc """
  `slipdock admin unlimited`: what it sends, and that the people list says
  who is unlimited.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias SlipdockCLI.{Admin, FakeServer}

  setup do
    home = Path.join(System.tmp_dir!(), "slipdock-admin-#{System.unique_integer([:positive])}")
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

  @users ~s({"users":[{"id":7,"email":"sam@example.com"}]})

  defp user(unlimited),
    do:
      ~s({"user":{"id":7,"email":"sam@example.com","unlimited":#{unlimited},) <>
        ~s("cards":{"used":3,"limited?":false}}})

  test "on sends unlimited: true for that person, and the answer says so" do
    serve([{200, @users}, {200, user(true)}])

    output = capture_io(fn -> Admin.run("admin", ["unlimited", "Sam@example.com", "on"], []) end)

    assert_received {:request, "GET", "/api/admin/users", _}
    assert_received {:request, "PATCH", "/api/admin/users/7", body}
    assert body == ~s({"unlimited":true})
    assert output =~ "sam@example.com"
    assert output =~ "[unlimited]"
  end

  test "off sends unlimited: false, and the flag is gone from the answer" do
    serve([{200, @users}, {200, user(false)}])

    output = capture_io(fn -> Admin.run("admin", ["unlimited", "sam@example.com", "off"], []) end)

    assert_received {:request, "PATCH", "/api/admin/users/7", body}
    assert body == ~s({"unlimited":false})
    refute output =~ "unlimited"
  end
end
