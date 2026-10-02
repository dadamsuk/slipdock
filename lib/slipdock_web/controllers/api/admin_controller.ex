defmodule SlipdockWeb.API.AdminController do
  @moduledoc """
  Administering the server from a terminal: the admin area's settings, people
  and signup queue, for whoever runs this thing from somewhere else.

  Behind `require_api_admin/2`, which wants both an admin account **and** a
  token deliberately made with the `admin` scope — see there for why.

  The refusals are the same ones the browser enforces, because they are in
  `Slipdock.Accounts` rather than in the LiveView: the last admin cannot be
  demoted or disabled here either.
  """
  use SlipdockWeb, :controller

  alias Slipdock.{Accounts, Build, Quota, Settings}

  action_fallback SlipdockWeb.API.FallbackController

  def settings(conn, _params) do
    settings = Settings.get()

    json(conn, %{
      # Which build is answering. The first thing worth knowing when a server
      # is behaving unexpectedly is whether it is the build you deployed.
      build: Build.info(),
      settings: %{
        setup_completed_at: settings.setup_completed_at,
        admin_email: settings.admin_email,
        signup_mode: settings.signup_mode,
        free_card_limit: settings.free_card_limit,
        user_directory: settings.user_directory,
        invites_create_accounts: settings.invites_create_accounts,
        allowlist: Enum.map(Settings.list_allowlist(), & &1.entry),
        smtp: %{
          configured: Settings.smtp_configured?(),
          host: settings.smtp_host,
          port: settings.smtp_port,
          from: settings.smtp_from_email,
          last_verified_at: settings.smtp_verified_at
        },
        login_fallback: %{
          enabled: Settings.login_fallback_enabled?(),
          path: if(Settings.login_fallback_enabled?(), do: Accounts.fallback_path())
        },
        pending_signups: Accounts.count_pending_signups()
      }
    })
  end

  @settable ~w(signup_mode free_card_limit user_directory invites_create_accounts
               login_fallback_enabled)

  def update_settings(conn, params) do
    # Not the admin address and not the SMTP details. Both have flows that
    # prove something first — a code to the new address, a test message that
    # arrived — and letting a PATCH skip those would undo the point of them.
    with {:ok, _} <- Settings.update(Map.take(params, @settable)) do
      settings(conn, %{})
    end
  end

  def allow(conn, %{"entry" => entry}) do
    with {:ok, _} <- Settings.add_allowlist_entry(entry, conn.assigns.current_user) do
      settings(conn, %{})
    end
  end

  def disallow(conn, %{"entry" => entry}) do
    normalised = Slipdock.Settings.AllowlistEntry.normalise(entry)

    case Enum.find(Settings.list_allowlist(), &(&1.entry == normalised)) do
      nil -> {:error, :not_found, "allowlist entry"}
      found -> with {:ok, _} <- Settings.remove_allowlist_entry(found), do: settings(conn, %{})
    end
  end

  def users(conn, _params) do
    json(conn, %{users: Enum.map(Accounts.list_users(), &user_json/1)})
  end

  def update_user(conn, %{"id" => id} = params) do
    with {:ok, user} <- fetch_user(id) do
      case apply_user_change(user, params) do
        {:ok, user} ->
          json(conn, %{user: user_json(user)})

        {:error, :last_admin} ->
          conn
          |> put_status(:conflict)
          |> json(%{
            error: "last_admin",
            message:
              "#{user.email} is the only admin. Make somebody else an admin first, or " <>
                "there would be nobody left who can administer this server.",
            retryable: false
          })

        other ->
          other
      end
    end
  end

  def signups(conn, _params) do
    json(conn, %{requests: Enum.map(Accounts.list_signup_requests(), &request_json/1)})
  end

  def decide_signup(conn, %{"id" => id, "decision" => decision}) do
    request = Accounts.get_signup_request!(id)

    case decision do
      "approve" ->
        with {:ok, user} <-
               Accounts.approve_signup(request, conn.assigns.current_user, &url(~p"/login/#{&1}")) do
          json(conn, %{approved: user_json(user)})
        end

      "reject" ->
        with {:ok, request} <- Accounts.reject_signup(request, conn.assigns.current_user) do
          json(conn, %{rejected: request_json(request)})
        end

      _ ->
        {:error, :bad_request, ~s(decision must be "approve" or "reject")}
    end
  end

  ## Internals

  defp apply_user_change(user, %{"admin" => true}), do: Accounts.promote(user)
  defp apply_user_change(user, %{"admin" => false}), do: Accounts.demote(user)
  defp apply_user_change(user, %{"disabled" => true}), do: Accounts.disable(user)
  defp apply_user_change(user, %{"disabled" => false}), do: Accounts.enable(user)

  defp apply_user_change(user, %{"card_limit" => limit}),
    do: Accounts.update_standing(user, %{"card_limit_override" => limit})

  defp apply_user_change(_user, _params),
    do: {:error, :bad_request, "pass admin, disabled or card_limit"}

  defp fetch_user(id) do
    case Accounts.get_user(id) do
      nil -> {:error, :not_found, "user"}
      user -> {:ok, user}
    end
  end

  defp user_json(user) do
    %{
      id: user.id,
      email: user.email,
      name: user.name,
      admin: user.admin,
      disabled: user.disabled_at != nil,
      invited: user.invited_at != nil,
      last_signed_in_at: user.last_signed_in_at,
      cards: Quota.status(user)
    }
  end

  defp request_json(request) do
    %{
      id: request.id,
      email: request.email,
      note: request.note,
      status: request.status,
      asked_at: request.inserted_at
    }
  end
end
