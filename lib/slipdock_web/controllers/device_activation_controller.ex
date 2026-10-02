defmodule SlipdockWeb.DeviceActivationController do
  @moduledoc """
  `/activate` — where a person approves an agent's request to sign in.

  Two rules this page exists to keep.

  **The decision is a POST with CSRF.** Never a GET. A link that approves
  itself when opened is the vulnerability the device flow exists to prevent,
  so `verification_uri_complete` may pre-fill the code and must not submit it.

  **Approving blind is approving anything.** The screen names what asked, what
  it would be allowed to do, where it asked from and when — so the decision is
  an informed one rather than a reflex.
  """
  use SlipdockWeb, :controller

  alias Slipdock.Accounts
  alias Slipdock.Accounts.DeviceAuthorization
  alias Slipdock.RateLimit

  # A user code is eight characters, which is short enough to grind at if
  # nobody is counting. Approving someone else's pending request only ever
  # mints a token for *your* account, so the prize is confusion rather than
  # access — but a limit costs nothing and closes the grinding anyway.
  @lookups_per_hour 30

  plug :require_signed_in

  def show(conn, params) do
    code = params["user_code"]

    case {code, lookup_allowed?(conn)} do
      {nil, _} ->
        render(conn, :show, user_code: nil, request: nil, page_title: "Approve a device")

      {_code, false} ->
        conn
        |> put_flash(:error, "Too many codes tried. Wait a while before trying another.")
        |> render(:show, user_code: nil, request: nil, page_title: "Approve a device")

      {code, true} ->
        render(conn, :show,
          user_code: code,
          request: Accounts.device_authorization_by_user_code(code),
          page_title: "Approve a device"
        )
    end
  end

  defp lookup_allowed?(conn) do
    key = "device:lookup:#{conn.assigns.current_user.id}"
    RateLimit.hit(key, @lookups_per_hour, 3_600_000) == :ok
  end

  def decide(conn, %{"user_code" => code} = params) do
    case Accounts.device_authorization_by_user_code(code) do
      nil ->
        conn
        |> put_flash(:error, "That code isn't valid any more. Ask the agent for a fresh one.")
        |> redirect(to: ~p"/activate")

      request ->
        decide(conn, request, params["decision"])
    end
  end

  def decide(conn, _params), do: redirect(conn, to: ~p"/activate")

  defp decide(conn, request, "approve") do
    case Accounts.approve_device_authorization(request, conn.assigns.current_user) do
      {:ok, _} ->
        conn
        |> put_flash(:info, "Approved. The agent should be signed in within a few seconds.")
        |> redirect(to: ~p"/account/tokens")

      {:error, :expired} ->
        conn
        |> put_flash(
          :error,
          "That request expired while you were deciding. Ask for a fresh code."
        )
        |> redirect(to: ~p"/activate")
    end
  end

  defp decide(conn, request, _denied) do
    {:ok, _} = Accounts.deny_device_authorization(request)

    conn
    |> put_flash(:info, "Refused. The agent has been told.")
    |> redirect(to: ~p"/activate")
  end

  # The page is a decision only its owner can make, so there is nothing here
  # for a signed-out visitor but the sign-in page.
  defp require_signed_in(conn, _opts) do
    if conn.assigns[:current_user] do
      conn
    else
      conn
      |> put_flash(:error, "Sign in first, then enter the code the agent showed you.")
      |> redirect(to: ~p"/login")
      |> halt()
    end
  end

  @doc false
  def display_code(code), do: DeviceAuthorization.display_code(code)
end
