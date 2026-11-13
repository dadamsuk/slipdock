defmodule SlipdockCLI.HTTPTest do
  @moduledoc """
  What goes over the wire: arguments that cannot rewrite the path they are
  put in, JSON null both ways, and the device-flow poll that waits as long
  as the server asks it to.
  """
  # Sync: sets HOME and the SLIPDOCK_* variables, which are one environment
  # for the whole VM.
  use ExUnit.Case, async: false

  alias SlipdockCLI.{FakeServer, HTTP}

  setup do
    home = Path.join(System.tmp_dir!(), "slipdock-http-#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)

    saved =
      Map.new(
        ~w(HOME USERPROFILE SLIPDOCK_URL SLIPDOCK_TOKEN KANBAN_TOKEN),
        &{&1, System.get_env(&1)}
      )

    System.put_env("HOME", home)
    Enum.each(~w(SLIPDOCK_URL SLIPDOCK_TOKEN KANBAN_TOKEN), &System.delete_env/1)

    on_exit(fn ->
      Enum.each(saved, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)

      File.rm_rf!(home)
    end)

    %{home: home}
  end

  defp serve(responses), do: System.put_env("SLIPDOCK_URL", FakeServer.start(responses))

  describe "encoding" do
    test "a path segment cannot add segments, a query or a fragment" do
      assert HTTP.seg("12/../../admin/users") == "12%2F..%2F..%2Fadmin%2Fusers"
      assert HTTP.seg("a b?c#d") == "a%20b%3Fc%23d"
      assert HTTP.seg(42) == "42"
    end

    test "the query leaves out unset options, and says nothing when all are" do
      assert HTTP.encode_query([]) == ""
      assert HTTP.encode_query(limit: nil) == ""
      assert HTTP.encode_query(q: "a&b=c d", limit: nil, n: 3) == "?q=a%26b%3Dc+d&n=3"
    end

    test "what the server receives is what the CLI meant" do
      serve([{200, "{}"}])
      assert {:ok, %{}} = HTTP.get("/boards/#{HTTP.seg("Road map/2")}/cards", q: "x&y")
      assert_received {:request, "GET", "/api/boards/Road%20map%2F2/cards?q=x%26y", ""}
    end
  end

  describe "a download" do
    setup do
      System.put_env("SLIPDOCK_TOKEN", "t")
      :ok
    end

    test "a refusal is the error a request would give, and writes no file", %{home: home} do
      serve([{404, ~s({"error":"not found"})}])
      dest = Path.join(home, "missing.bin")

      assert {:error, 404, %{"error" => "not found"}} = HTTP.download("/attachments/9", dest)
      refute File.exists?(dest)
    end

    test "a 2xx that isn't streamed is written from its body", %{home: home} do
      serve([{201, "data"}])
      dest = Path.join(home, "file.bin")

      assert :ok = HTTP.download("/attachments/9", dest)
      assert File.read!(dest) == "data"
    end

    test "the last 2xx is still written from its body", %{home: home} do
      serve([{299, "edge"}])
      dest = Path.join(home, "edge.bin")

      assert :ok = HTTP.download("/attachments/9", dest)
      assert File.read!(dest) == "edge"
    end

    test "a status just outside 2xx is an error", %{home: home} do
      serve([{300, "{}"}])
      dest = Path.join(home, "moved.bin")

      assert {:error, 300, %{}} = HTTP.download("/attachments/9", dest)
      refute File.exists?(dest)
    end
  end

  describe "a request's status" do
    test "the last 2xx is still a success, and the first 3xx is an error" do
      serve([{299, ~s({"ok":true})}, {300, ~s({"error":"choices"})}])

      assert {:ok, %{"ok" => true}} = HTTP.get("/cards/1")
      assert {:error, 300, %{"error" => "choices"}} = HTTP.get("/cards/1")
    end
  end

  describe "somewhere local" do
    test "a URL with an empty host is local, so plain http to it is not refused" do
      assert HTTP.local_host?("")
      assert HTTP.local_host?("[]")
      refute HTTP.insecure?("http:///api")
    end

    test "localhost in any case is local, and a public name is not" do
      assert HTTP.local_host?("LocalHost")
      refute HTTP.local_host?("boards.example")
      refute HTTP.local_host?(nil)
    end
  end

  describe "home, on Windows too" do
    test "with no HOME, the config goes under USERPROFILE, not the current folder", %{home: home} do
      System.delete_env("HOME")
      System.put_env("USERPROFILE", home)

      assert HTTP.home() == home

      assert HTTP.save_url("https://boards.example/") ==
               Path.join([home, ".config", "slipdock", "url"])

      assert File.read!(Path.join([home, ".config", "slipdock", "url"])) ==
               "https://boards.example\n"

      assert HTTP.base_url() == "https://boards.example"
      refute File.exists?(".config/slipdock/url")
    end

    test "an empty HOME counts as none", %{home: home} do
      System.put_env("HOME", "")
      System.put_env("USERPROFILE", home)
      assert HTTP.home() == home
    end

    test "HOME wins when both are set", %{home: home} do
      System.put_env("USERPROFILE", Path.join(home, "elsewhere"))
      assert HTTP.home() == home
    end
  end

  describe "null" do
    test "nil goes out as JSON null, not the string \"nil\"" do
      assert HTTP.encode(%{"due" => nil, "tags" => [nil]}) =~ ~s("due":null)
      refute HTTP.encode(%{"due" => nil}) =~ "nil"

      serve([{200, "{}"}])
      HTTP.patch("/cards/1", %{"due_date" => nil})
      assert_received {:request, "PATCH", "/api/cards/1", ~s({"due_date":null})}
    end

    test "JSON null comes back as nil, an empty body as an empty map" do
      serve([{200, ~s({"card":{"due_date":null}})}, {204, ""}, {502, "Bad Gateway"}])
      assert {:ok, %{"card" => %{"due_date" => nil}}} = HTTP.get("/cards/1")
      assert {:ok, %{}} = HTTP.delete("/cards/1")
      assert {:error, 502, %{"raw" => "Bad Gateway"}} = HTTP.get("/cards/1")
    end
  end

  describe "device flow" do
    defp waits do
      parent = self()
      fn ms -> send(parent, {:slept, ms}) end
    end

    test "keeps asking while pending, and backs off when told to slow down" do
      serve([
        {400, ~s({"error":"authorization_pending"})},
        {400, ~s({"error":"slow_down"})},
        {200, ~s({"token":"sd_abc"})}
      ])

      started = %{"device_code" => "dev-1", "expires_in" => 600}
      assert {:ok, "sd_abc"} = SlipdockCLI.await_device_approval(started, 5, waits())

      assert_received {:slept, 5000}
      assert_received {:slept, 5000}
      assert_received {:slept, 10_000}
      assert_received {:request, "POST", "/api/auth/device/token", ~s({"device_code":"dev-1"})}
    end

    test "a refusal or an expired code ends the wait with a reason" do
      serve([{400, ~s({"error":"access_denied"})}, {400, ~s({"error":"expired_token"})}])
      started = %{"device_code" => "dev-2"}

      assert {:error, "the request was refused"} =
               SlipdockCLI.await_device_approval(started, 1, waits())

      assert {:error, "the code expired" <> _} =
               SlipdockCLI.await_device_approval(started, 1, waits())
    end

    test "stops asking once the code has run out, without another request" do
      started = %{"device_code" => "dev-3", "expires_in" => -1}

      assert {:error, "the code expired" <> _} =
               SlipdockCLI.await_device_approval(started, 1, waits())

      refute_received {:request, _, _, _}
    end
  end
end
