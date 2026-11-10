defmodule SlipdockWeb.RequestLogTest do
  # Not async: the test raises Logger's level, which is global, to
  # production's `:info` (`config/prod.exs`), where the request log is.
  use SlipdockWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  alias SlipdockWeb.RequestLog

  doctest RequestLog

  @secret "s3cr3t-Zq8wXy71"

  setup do
    previous = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous) end)
  end

  defp logged(fun), do: capture_log([level: :info], fun)

  defp request(conn, method, path) do
    logged(fn ->
      try do
        dispatch(conn, @endpoint, method, path, nil)
      rescue
        _ -> :raised
      end
    end)
  end

  describe "a credential in the path" do
    for {method, path, shown} <- [
          {:get, "/login/#{@secret}", "GET /login/[FILTERED]"},
          {:post, "/login/#{@secret}", "POST /login/[FILTERED]"},
          {:get, "/p/#{@secret}", "GET /p/[FILTERED]"},
          {:get, "/w/#{@secret}", "GET /w/[FILTERED]"},
          {:get, "/w/#{@secret}/files/12/a.png", "GET /w/[FILTERED]/files/12/a.png"},
          {:post, "/api/upload/#{@secret}", "POST /api/upload/[FILTERED]"},
          {:get, "/api/download/#{@secret}", "GET /api/download/[FILTERED]"}
        ] do
      test "#{shown} is logged without it", %{conn: conn} do
        log = request(conn, unquote(method), unquote(path))

        assert log =~ unquote(shown)
        refute log =~ @secret
      end
    end
  end

  test "any other path is logged as it came, with its answer", %{conn: conn} do
    log = request(conn, :get, "/login?next=%2Fboards")

    assert log =~ "GET /login\n"
    assert log =~ ~r/Sent \d{3} in \d+/
    refute log =~ "[FILTERED]"
  end

  test "an unfiltered path is written as it came, not rebuilt", %{conn: conn} do
    assert request(conn, :get, "/boards//3/") =~ "GET /boards//3/\n"
  end

  test "the sign-in page's own paths are not filtered", %{conn: conn} do
    assert request(conn, :post, "/login/passkey/options") =~ "POST /login/passkey/options"
  end

  test "Phoenix's own request line is off, so the path is written once", %{conn: conn} do
    log = request(conn, :get, "/boards")
    assert length(String.split(log, "GET /boards")) == 2
  end

  test "parameters named for a secret or a token are filtered" do
    filtered =
      Phoenix.Logger.filter_values(%{"secret" => @secret, "token" => @secret, "q" => "x"})

    assert filtered == %{"secret" => "[FILTERED]", "token" => "[FILTERED]", "q" => "x"}
  end

  describe "path/1" do
    test "keeps a path that only starts like a filtered one" do
      assert RequestLog.path(%{request_path: "/pages", path_info: ["pages"]}) == "/pages"
      assert RequestLog.path(%{request_path: "/p", path_info: ["p"]}) == "/p"

      assert RequestLog.path(%{request_path: "/api/upload", path_info: ["api", "upload"]}) ==
               "/api/upload"
    end

    test "filters only the credential segment" do
      assert RequestLog.path(%{request_path: "/upload/x", path_info: ["upload", "x"]}) ==
               "/upload/x"

      assert RequestLog.path(%{
               request_path: "/api/download/x/y",
               path_info: ["api", "download", "x", "y"]
             }) == "/api/download/[FILTERED]/y"
    end
  end
end
