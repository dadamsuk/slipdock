defmodule Slipdock.DeploymentHardeningTest do
  @moduledoc """
  The pieces of deployment hardening that live in the app rather than in a
  shell script or a unit file: arguments from the container's entrypoint, the
  private directory Agentic Login writes to, and the `Secure` session cookie.
  """
  # Sync: sets OS environment variables (System.put_env), one set per node.
  use SlipdockWeb.ConnCase, async: false

  alias Slipdock.{Accounts, Release}

  describe "Release.env_args/0" do
    setup do
      on_exit(fn ->
        for name <- ~w(SLIPDOCK_ARGC SLIPDOCK_ARG_1 SLIPDOCK_ARG_2), do: System.delete_env(name)
      end)
    end

    test "reads the arguments the entrypoint exported, in order and verbatim" do
      System.put_env("SLIPDOCK_ARGC", "2")
      System.put_env("SLIPDOCK_ARG_1", ~s(a"b@example.com))
      System.put_env("SLIPDOCK_ARG_2", ~S"#{System.halt()}")

      assert Release.env_args() == [~s(a"b@example.com), ~S"#{System.halt()}"]
    end

    test "is empty when there are none" do
      assert Release.env_args() == []
      System.put_env("SLIPDOCK_ARGC", "0")
      assert Release.env_args() == []
    end
  end

  describe "Agentic Login's directory" do
    test "is created private to the server's account when it does not exist" do
      previous = Application.get_env(:slipdock, :agentic_login_dir)
      dir = Path.join(System.tmp_dir!(), "slipdock-test-#{System.unique_integer([:positive])}")
      Application.put_env(:slipdock, :agentic_login_dir, dir)

      on_exit(fn ->
        Application.put_env(:slipdock, :agentic_login_dir, previous)
        File.rm_rf!(dir)
      end)

      assert {:ok, path} = Accounts.write_agentic_login("agent@example.com", & &1)
      assert Path.dirname(path) == dir
      assert File.stat!(dir).mode |> Bitwise.band(0o777) == 0o700
      assert File.stat!(path).mode |> Bitwise.band(0o777) == 0o600
    end

    test "defaults to a directory of its own, not the bare temp dir" do
      previous = Application.get_env(:slipdock, :agentic_login_dir)
      Application.delete_env(:slipdock, :agentic_login_dir)
      on_exit(fn -> Application.put_env(:slipdock, :agentic_login_dir, previous) end)

      assert Accounts.agentic_login_dir() ==
               Path.join(System.tmp_dir!(), "slipdock-agentic-login")
    end
  end

  describe "the session cookie" do
    defp with_scheme(scheme) do
      endpoint = SlipdockWeb.Endpoint
      previous = Application.get_env(:slipdock, endpoint)
      url = Keyword.put(previous[:url] || [], :scheme, scheme)
      Application.put_env(:slipdock, endpoint, Keyword.put(previous, :url, url))
      endpoint.config_change([{endpoint, Application.get_env(:slipdock, endpoint)}], [])

      on_exit(fn ->
        Application.put_env(:slipdock, endpoint, previous)
        endpoint.config_change([{endpoint, previous}], [])
      end)
    end

    defp session_cookie(conn) do
      conn
      |> get(~p"/login")
      |> Plug.Conn.get_resp_header("set-cookie")
      |> Enum.find(&String.starts_with?(&1, "_slipdock_key="))
    end

    test "is Secure when the server's address is https", %{conn: conn} do
      with_scheme("https")
      assert session_cookie(conn) =~ "; secure"
    end

    test "is not when it is plain http, or it would never come back", %{conn: conn} do
      with_scheme("http")
      refute session_cookie(conn) =~ "; secure"
    end
  end
end
