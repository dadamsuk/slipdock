defmodule SlipdockWeb.Plugs.Setup do
  @moduledoc """
  The two halves of the gate around the first-run setup wizard.

  `redirect_to_setup/2` sends anybody who arrives at an unclaimed server to
  `/setup`, so a fresh install cannot look broken.

  `require_unclaimed/2` guards `/setup` itself and **404s** once setup is
  finished rather than redirecting. That is deliberate: a redirect, or a
  "already set up" page, tells a stranger that this software is running here and
  that there is an administrative corner to go looking for. A 404 says nothing.

  ## Why the wizard needs a token at all

  Setup has to be reachable by somebody who has no account — there is nobody to
  authenticate yet. On a server only you can reach, that is fine. On a public
  one it is a race: whoever finds `/setup` first becomes the admin of your
  instance. So the first boot mints a token, logs it, and the wizard will not
  proceed without it (see `Slipdock.Settings.ensure_setup_token/0`). The token
  is in the log and nowhere else.

  ## Why it is logged again on every request

  A boot message is easy to miss and easier to lose: it scrolls out of
  `journalctl`, a container restart buries it, and a reset database mints a new
  token nobody saw. That left the one person entitled to claim the server
  staring at a page asking for a token they could not find. So every request
  for the wizard logs the token again, minting one if the row has none.

  This discloses nothing new. The token still goes only to the log, and a
  stranger who requests `/setup` cannot read what their request wrote. What it
  does cost is log volume: anyone who can reach an unclaimed server can make it
  write a line per request. That lasts only until the server is claimed, and
  `SLIPDOCK_ADMIN_EMAIL` skips the wizard altogether.
  """
  import Plug.Conn
  import Phoenix.Controller

  alias Slipdock.Settings

  @setup_path "/setup"

  @behaviour Plug

  @impl Plug
  def init(which) when which in [:redirect_to_setup, :require_unclaimed], do: which

  @impl Plug
  def call(conn, :redirect_to_setup), do: redirect_to_setup(conn, [])
  def call(conn, :require_unclaimed), do: require_unclaimed(conn, [])

  def redirect_to_setup(conn, _opts) do
    if Settings.setup_complete?() or String.starts_with?(conn.request_path, @setup_path) or
         exempt?(conn) do
      conn
    else
      conn |> redirect(to: @setup_path) |> halt()
    end
  end

  def require_unclaimed(conn, _opts) do
    if Settings.setup_complete?() do
      conn
      |> put_status(:not_found)
      |> put_view(html: SlipdockWeb.ErrorHTML)
      |> render(:"404")
      |> halt()
    else
      announce_token()
      conn
    end
  end

  # `ensure_setup_token/0` hands back the token the server already has and only
  # writes when there is none, so this is a read on all but the first request.
  defp announce_token do
    require Logger

    case Settings.ensure_setup_token() do
      nil ->
        :ok

      token ->
        Logger.info("""
        Setup token for this server: #{token}

            #{Settings.setup_url(token)}

        Logged on every request for /setup while the server is unclaimed.
        """)
    end
  end

  # Signing in is *not* exempt. On a server nobody has set up there is nobody to
  # sign in as, and the wizard is the only way one gets claimed — two doors that
  # can both claim a server is worse than either on its own.
  defp exempt?(%{request_path: path}) do
    String.starts_with?(path, "/assets") or path in ["/favicon.ico", "/robots.txt"]
  end
end
