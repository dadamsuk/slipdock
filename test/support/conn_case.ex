defmodule SlipdockWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use SlipdockWeb.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint SlipdockWeb.Endpoint

      use SlipdockWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import SlipdockWeb.ConnCase
    end
  end

  setup tags do
    Slipdock.DataCase.setup_sandbox(tags)
    user = Slipdock.Fixtures.user_fixture()
    conn = Phoenix.ConnTest.build_conn()

    conn =
      if tags[:anonymous] do
        conn
      else
        # Signed in for LiveView requests and carrying an API token for /api.
        {token, _} = Slipdock.Accounts.create_api_token(user, "test")
        conn |> log_in_user(user) |> Plug.Conn.put_req_header("authorization", "Bearer " <> token)
      end

    {:ok, conn: conn, user: user}
  end

  @doc """
  A conn whose LiveViews mount as if on a phone held upright.

  The width reaches the server in the socket's connect params (see
  `SlipdockWeb.ViewportHook`), so a test that wants the phone's rendering has
  to say so before it connects.
  """
  def phone(conn, width \\ 390) do
    Phoenix.LiveViewTest.put_connect_params(conn, %{"viewport_width" => width})
  end

  @doc "Signs the user in on the conn (a session token in the session cookie)."
  def log_in_user(conn, user) do
    token = Slipdock.Accounts.generate_session_token(user)
    conn |> Phoenix.ConnTest.init_test_session(%{}) |> Plug.Conn.put_session(:user_token, token)
  end

  @doc "A conn signed in (and API-authenticated) as `user`."
  def conn_as(user) do
    {token, _} = Slipdock.Accounts.create_api_token(user, "test")

    Phoenix.ConnTest.build_conn()
    |> log_in_user(user)
    |> Plug.Conn.put_req_header("authorization", "Bearer " <> token)
  end
end
