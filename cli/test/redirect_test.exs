defmodule SlipdockCLI.RedirectTest do
  @moduledoc """
  How `SlipdockCLI.HTTP` follows redirects: only to the origin the request
  went to (or from http to https on the same host), with the method and body
  each status calls for, and never more than five times. A redirect to
  another host comes back as an error, and that host is never asked.
  """
  # Sync: sets HOME and the SLIPDOCK_* variables, which are one for the VM.
  use ExUnit.Case, async: false

  alias SlipdockCLI.{FakeServer, HTTP}

  setup do
    home = Path.join(System.tmp_dir!(), "slipdock-redirect-#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    saved = Map.new(~w(HOME SLIPDOCK_URL SLIPDOCK_TOKEN KANBAN_TOKEN), &{&1, System.get_env(&1)})
    System.put_env("HOME", home)
    System.put_env("SLIPDOCK_TOKEN", "test-token")
    System.delete_env("KANBAN_TOKEN")

    on_exit(fn ->
      Enum.each(saved, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)

      File.rm_rf!(home)
    end)

    %{home: home}
  end

  # The same machine under another name: a different host to the client.
  defp other_host(url), do: String.replace(url, "127.0.0.1", "localhost")

  defp serve(responses), do: System.put_env("SLIPDOCK_URL", FakeServer.start(responses))

  describe "a redirect to another host" do
    test "is not followed, and that host is never asked" do
      other = other_host(FakeServer.start([{200, ~s({"ok":true})}]))
      serve([{302, "", [{"location", other <> "/elsewhere"}]}])

      assert {:error, 302, %{"error" => error}} = HTTP.get("/boards")
      assert error =~ "another host"
      assert error =~ "localhost"

      assert_received {:headers, "GET", "/api/boards", %{"authorization" => "Bearer test-token"}}
      refute_receive {:request, _, "/elsewhere", _}, 300
    end

    test "is not followed for a POST or a download either", %{home: home} do
      other = other_host(FakeServer.start([{200, "{}"}, {200, "{}"}]))

      serve([
        {307, "", [{"location", other <> "/elsewhere"}]},
        {302, "", [{"location", other <> "/elsewhere"}]}
      ])

      assert {:error, 307, %{"error" => _}} = HTTP.post("/cards", %{"title" => "x"})

      dest = Path.join(home, "file.bin")
      assert {:error, 302, %{"error" => _}} = HTTP.download("/attachments/1/file", dest)
      refute File.exists?(dest)

      refute_receive {:request, _, "/elsewhere", _}, 300
    end

    test "on another port of the same host is not followed" do
      other = FakeServer.start([{200, "{}"}])
      serve([{301, "", [{"location", other <> "/elsewhere"}]}])

      assert {:error, 301, _} = HTTP.get("/boards")
      refute_receive {:request, _, "/elsewhere", _}, 300
    end
  end

  describe "a redirect to the same origin" do
    test "is followed, with the token" do
      serve([
        {302, "", [{"location", "/api/boards/2"}]},
        {200, ~s({"id":2})}
      ])

      assert {:ok, %{"id" => 2}} = HTTP.get("/boards")
      assert_received {:request, "GET", "/api/boards", _}

      assert_received {:headers, "GET", "/api/boards/2",
                       %{"authorization" => "Bearer test-token"}}
    end

    test "an absolute location on the same origin is followed" do
      {:ok, own} = Agent.start_link(fn -> nil end)

      url =
        FakeServer.start([
          fn _, _, _ -> {302, "", [{"location", Agent.get(own, & &1) <> "/api/boards/3"}]} end,
          {200, ~s({"id":3})}
        ])

      Agent.update(own, fn _ -> url end)
      System.put_env("SLIPDOCK_URL", url)

      assert {:ok, %{"id" => 3}} = HTTP.get("/boards")

      assert_received {:headers, "GET", "/api/boards/3",
                       %{"authorization" => "Bearer test-token"}}
    end

    test "a 303 after a POST becomes a GET without the body" do
      serve([
        {303, "", [{"location", "/api/cards/9"}]},
        {200, ~s({"id":9})}
      ])

      assert {:ok, %{"id" => 9}} = HTTP.post("/cards", %{"title" => "x"})
      assert_received {:request, "POST", "/api/cards", ~s({"title":"x"})}
      assert_received {:request, "GET", "/api/cards/9", ""}
    end

    for status <- [301, 302] do
      test "a #{status} after a POST becomes a GET without the body" do
        serve([
          {unquote(status), "", [{"location", "/api/cards/9"}]},
          {200, ~s({"id":9})}
        ])

        assert {:ok, %{"id" => 9}} = HTTP.post("/cards", %{"title" => "x"})
        assert_received {:request, "POST", "/api/cards", _}
        assert_received {:request, "GET", "/api/cards/9", ""}
      end
    end

    test "a 308 repeats the method and the body" do
      serve([
        {308, "", [{"location", "/api/cards/new"}]},
        {200, ~s({"id":9})}
      ])

      assert {:ok, %{"id" => 9}} = HTTP.post("/cards", %{"title" => "x"})
      assert_received {:request, "POST", "/api/cards", _}
      assert_received {:request, "POST", "/api/cards/new", ~s({"title":"x"})}
    end

    test "a 301 after a PATCH keeps the method and the body" do
      serve([
        {301, "", [{"location", "/api/cards/10"}]},
        {200, ~s({"id":10})}
      ])

      assert {:ok, %{"id" => 10}} = HTTP.patch("/cards/9", %{"title" => "y"})
      assert_received {:request, "PATCH", "/api/cards/9", _}
      assert_received {:request, "PATCH", "/api/cards/10", ~s({"title":"y"})}
    end

    test "a 307 repeats the method and the body" do
      serve([
        {307, "", [{"location", "/api/cards/new"}]},
        {200, ~s({"id":9})}
      ])

      assert {:ok, %{"id" => 9}} = HTTP.post("/cards", %{"title" => "x"})
      assert_received {:request, "POST", "/api/cards", _}
      assert_received {:request, "POST", "/api/cards/new", ~s({"title":"x"})}
    end

    test "a download is followed and saved", %{home: home} do
      serve([
        {302, "", [{"location", "/api/files/1"}]},
        {200, "the bytes"}
      ])

      dest = Path.join(home, "file.bin")
      assert :ok = HTTP.download("/attachments/1/file", dest)
      assert File.read!(dest) == "the bytes"
      assert_received {:headers, "GET", "/api/files/1", %{"authorization" => "Bearer test-token"}}
    end

    test "stops after five redirects" do
      loop = {302, "", [{"location", "/api/again"}]}
      serve(List.duplicate(loop, 6))

      assert {:error, 302, _} = HTTP.get("/boards")
      for _ <- 1..6, do: assert_received({:request, "GET", _, _})
      refute_receive {:request, _, _, _}, 100
    end
  end

  describe "same_origin?/2" do
    test "the same scheme, host and port" do
      assert HTTP.same_origin?("https://example.com/api/a", "https://example.com/b")
      assert HTTP.same_origin?("https://example.com/a", "https://EXAMPLE.com/b")
      refute HTTP.same_origin?("https://example.com/a", "https://example.com:8443/b")
      refute HTTP.same_origin?("https://example.com/a", "https://other.example.com/b")
    end

    test "http may move to https on the same host, never back" do
      assert HTTP.same_origin?("http://example.com/a", "https://example.com/b")
      refute HTTP.same_origin?("https://example.com/a", "http://example.com/b")
      refute HTTP.same_origin?("http://example.com/a", "https://other.example.com/b")
    end
  end
end
