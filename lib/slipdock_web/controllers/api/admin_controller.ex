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
        # The guardrails, which apply on every install, and the trial clock.
        # Each is a number and a switch; a switch that is off means no limit.
        limits: %{
          boards: %{enabled: settings.board_limit_enabled, limit: settings.board_limit},
          items: %{enabled: settings.item_limit_enabled, limit: settings.item_limit},
          storage: %{
            enabled: settings.storage_limit_enabled,
            limit_mb: settings.storage_limit_mb
          },
          trial: %{enabled: settings.trial_enabled, days: settings.trial_days}
        },
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
        # Off (key nil) unless an admin filled one in; host nil means the US cloud.
        analytics: %{
          posthog_key: settings.posthog_key,
          posthog_host: settings.posthog_host
        },
        # Whose AI settings search, indexing and scheduled automations run on:
        # `system_user` is the admin chosen here (nil for none), `source` and
        # `using` what is actually in effect — see `Slipdock.AI.Keys.system_source/0`.
        ai: ai_json(settings),
        # Meeting capture: off unless turned on, and where it shows when on.
        meetings: %{
          enabled: settings.meetings_enabled,
          visibility: settings.meetings_visibility,
          hideable: settings.meetings_hideable,
          accepts: %{
            transcripts: settings.meetings_accept_transcripts,
            audio: settings.meetings_accept_audio,
            findings: settings.meetings_accept_findings
          },
          limits: Slipdock.Meetings.Usage.limits(),
          audio_retention: settings.meetings_audio_retention,
          reading: %{
            model: settings.meetings_reading_model,
            second: settings.meetings_second_reading,
            second_model: settings.meetings_second_model
          }
        },
        pending_signups: Accounts.count_pending_signups()
      }
    })
  end

  def update_settings(conn, params) do
    # Not the admin address and not the SMTP details. Both have flows that
    # prove something first — a code to the new address, a test message that
    # arrived — and letting a PATCH skip those would undo the point of them.
    with {:ok, params} <- ai_system_user(params),
         {:ok, _} <- Settings.update(Map.take(params, Slipdock.Settings.Instance.policy_fields())) do
      settings(conn, %{})
    end
  end

  # The server's AI is named by email, the way a person would; stored by id.
  # Empty or "none" clears the choice.
  defp ai_system_user(%{"ai_system_user" => email} = params) do
    params = Map.delete(params, "ai_system_user")

    cond do
      email in ["", "none", "-", nil] ->
        {:ok, Map.put(params, "ai_system_user_id", nil)}

      user = is_binary(email) && Accounts.get_user_by_email(email) ->
        {:ok, Map.put(params, "ai_system_user_id", user.id)}

      true ->
        {:error, :bad_request, "ai_system_user: no account here uses #{inspect(email)}"}
    end
  end

  defp ai_system_user(params), do: {:ok, params}

  defp ai_json(settings) do
    %{source: source, user: user} = Slipdock.AI.Keys.system_source()
    chosen = settings.ai_system_user_id && Accounts.get_user(settings.ai_system_user_id)

    %{
      system_user: chosen && chosen.email,
      source: source,
      using: user && user.email
    }
  end

  @doc "Meeting capture this month: the server's totals and the heaviest users."
  def meetings_usage(conn, _params) do
    json(conn, %{usage: Slipdock.Meetings.Usage.server_month()})
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
    users = Accounts.list_users()
    usage = Quota.usage(Enum.map(users, & &1.id))
    json(conn, %{users: Enum.map(users, &user_json(&1, usage[&1.id]))})
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
            message: Slipdock.Accounts.last_admin_message(user),
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
    case Accounts.get_signup_request(SlipdockWeb.Params.id(id)) do
      nil -> {:error, :not_found, "signup request"}
      request -> decide(conn, request, decision)
    end
  end

  defp decide(conn, request, decision) do
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

  # What makes one account not free. No billing here: a date, set by whoever
  # took the money. `none` clears it and puts them back on the free tier.
  defp apply_user_change(user, %{"paid_until" => until}),
    do: Accounts.update_standing(user, %{"paid_until" => blank_to_nil(until)})

  # Off the free tier for good, for somebody named rather than somebody who
  # paid. The guardrails still apply.
  defp apply_user_change(user, %{"unlimited" => unlimited}) when is_boolean(unlimited),
    do: Accounts.update_standing(user, %{"unlimited" => unlimited})

  defp apply_user_change(_user, _params),
    do: {:error, :bad_request, "pass admin, disabled, card_limit, paid_until or unlimited"}

  defp blank_to_nil(value) when value in ["", "none", "-", nil], do: nil
  defp blank_to_nil(value), do: value

  defp fetch_user(id) do
    case Accounts.get_user(id) do
      nil -> {:error, :not_found, "user"}
      user -> {:ok, user}
    end
  end

  defp user_json(user, usage \\ nil) do
    %{
      id: user.id,
      email: user.email,
      name: user.name,
      admin: user.admin,
      disabled: user.disabled_at != nil,
      invited: user.invited_at != nil,
      last_signed_in_at: user.last_signed_in_at,
      paid_until: user.paid_until,
      unlimited: user.unlimited,
      # `cards` is the item count — cards, pages and files — and keeps its name
      # because callers match on it. `limits` is every dimension and the trial.
      cards: if(usage, do: Quota.report(user, usage).items, else: Quota.status(user)),
      limits: if(usage, do: Quota.report(user, usage), else: Quota.report(user))
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
