defmodule Slipdock.Settings do
  @moduledoc """
  This server's own settings: who may register, what a free account may do, who
  can see whom, and how mail is sent. One row (see
  `Slipdock.Settings.Instance`), read through here.

  ## Why this exists

  All of it used to be environment: `config :slipdock, :signups` decided who
  could sign up, and `config/runtime.exs` read `SLIPDOCK_SMTP_*` once at boot
  and baked it into `Slipdock.Mailer`. Nothing could be changed without a
  redeploy, there was no admin, and the only way an instance could be claimed
  was the first sign-in on an empty database — which meant the second person
  could never get in.

  ## Environment seeds it, then loses

  `seed/0` writes the row once, from the environment, the first time the server
  starts. After that the database is the only authority: changing
  `SLIPDOCK_SIGNUP_ALLOW` on an instance that has already been set up does
  nothing at all. That is deliberate (a browser has to be able to win) and is
  the one thing about this module worth saying out loud in the docs.

  ## Before setup

  With no row at all — a fresh install — `get/0` answers with defaults taken
  from `config :slipdock, :settings`, so the application has something coherent
  to read while the setup wizard is still waiting to be filled in. Nothing is
  written until somebody saves something.

  ## Caching

  `get/0` is called often enough (every quota check, every people picker) to be
  worth a query every time, so the row is cached in `:persistent_term` and
  erased on every write. The test environment turns the cache off
  (`config :slipdock, :settings_cache, false`), because a row cached inside one
  test's sandbox transaction would outlive the rollback and leak into the next.
  """

  import Ecto.Query, warn: false

  require Logger

  alias Slipdock.Repo
  alias Slipdock.Settings.{AllowlistEntry, Instance}

  # The singleton's id. One row, always this one.
  @id 1
  @cache_key {__MODULE__, :instance}

  @doc """
  This server's settings. Never nil: before setup there is no row, and the
  defaults from `config :slipdock, :settings` stand in for one.
  """
  @spec get() :: Instance.t()
  def get do
    if cache_enabled?() do
      case :persistent_term.get(@cache_key, :miss) do
        :miss ->
          instance = load()
          :persistent_term.put(@cache_key, instance)
          instance

        instance ->
          instance
      end
    else
      load()
    end
  end

  @doc """
  Whether the settings table exists yet.

  Outside a release, migrations are *not* run at boot (see
  `Slipdock.Application.skip_migrations?/0`) — `mix ecto.migrate` does it. So on
  a brand-new database the application starts before this table exists, and
  anything that reads it at boot has to ask first or the server will not start
  at all.
  """
  @spec ready?() :: boolean()
  def ready? do
    case Repo.query("SELECT to_regclass('settings')", []) do
      {:ok, %{rows: [[nil]]}} -> false
      {:ok, %{rows: [[_oid]]}} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  @doc "Forgets the cached row. Called after every write, and by tests."
  def clear_cache, do: :persistent_term.erase(@cache_key)

  @doc """
  Changes the settings, creating the row if this is the first write. Returns
  `{:ok, instance}` or `{:error, changeset}`.
  """
  @spec update(map()) :: {:ok, Instance.t()} | {:error, Ecto.Changeset.t()}
  def update(attrs) do
    stored()
    |> Kernel.||(%Instance{id: @id})
    |> Instance.changeset(attrs)
    |> Repo.insert_or_update()
    |> tap_clear_cache()
  end

  @doc """
  Finishes setup: stores everything the wizard collected and stamps
  `setup_completed_at`, after which the wizard is gone for good and no sign-in
  can claim this server.
  """
  @spec complete_setup(map()) :: {:ok, Instance.t()} | {:error, Ecto.Changeset.t()}
  def complete_setup(attrs) do
    stored()
    |> Kernel.||(%Instance{id: @id})
    |> Instance.complete_setup_changeset(attrs)
    |> Repo.insert_or_update()
    |> tap_clear_cache()
  end

  @doc "A changeset for a settings form."
  def change(attrs \\ %{}), do: Instance.changeset(get(), attrs)

  @doc "Whether the setup wizard has been completed, and so is unreachable."
  @spec setup_complete?() :: boolean()
  def setup_complete?, do: get().setup_completed_at != nil

  @doc "Who may register here: `:open`, `:allowlist`, `:approval` or `:closed`."
  @spec signup_mode() :: atom()
  def signup_mode, do: get().signup_mode

  @doc """
  The free tier's allowance: how many things one person's own boards may hold —
  cards, wiki pages and uploaded files together — or nil for no limit, which is
  what a self-hosted install wants and gets by default.

  The column is still called `free_card_limit` because the CLI flag, the JSON
  API field and a year of saved settings all use that name. What it counts is
  `Slipdock.Quota`'s business, and it counts everything now.
  """
  @spec free_card_limit() :: pos_integer() | nil
  def free_card_limit, do: get().free_card_limit

  @doc """
  The guardrail on how many boards one person may own, or nil when the switch
  is off. Unlike the free tier's allowance this applies on every install.
  """
  @spec board_limit() :: pos_integer() | nil
  def board_limit, do: enabled_limit(:board_limit_enabled, :board_limit)

  @doc "The guardrail on cards, pages and files together, or nil when switched off."
  @spec item_limit() :: pos_integer() | nil
  def item_limit, do: enabled_limit(:item_limit_enabled, :item_limit)

  @doc "The guardrail on uploaded bytes, or nil when switched off."
  @spec storage_limit_bytes() :: pos_integer() | nil
  def storage_limit_bytes do
    case enabled_limit(:storage_limit_enabled, :storage_limit_mb) do
      nil -> nil
      mb -> mb * 1024 * 1024
    end
  end

  @doc """
  How many days a free account may go on adding things, or nil when the trial
  is switched off — which is the default, and what a self-hosted install wants.

  Independent of the counts: an account can have no card limit at all and still
  be on a month's trial, or have both.
  """
  @spec trial_days() :: pos_integer() | nil
  def trial_days, do: enabled_limit(:trial_enabled, :trial_days)

  @doc "The stored megabytes, for a form that shows what was typed."
  @spec storage_limit_mb() :: pos_integer() | nil
  def storage_limit_mb, do: get().storage_limit_mb

  defp enabled_limit(switch, number) do
    settings = get()
    if Map.get(settings, switch), do: Map.get(settings, number)
  end

  @doc "Who appears in people pickers and model prompts: `:instance` or `:shared_only`."
  @spec user_directory() :: :instance | :shared_only
  def user_directory, do: get().user_directory

  @doc """
  Whether sharing something with an address that has no account here creates
  one. On the hosted instance this is how people arrive; most self-hosters turn
  it off and share only with colleagues who already have accounts.
  """
  @spec invites_create_accounts?() :: boolean()
  def invites_create_accounts?, do: get().invites_create_accounts

  @doc "Whether mail can actually be sent — a host is the whole of it."
  @spec smtp_configured?() :: boolean()
  def smtp_configured?, do: smtp_configured?(get())
  def smtp_configured?(%Instance{smtp_host: host}), do: is_binary(host) and host != ""

  @doc """
  Whether sign-in codes may be written to a file when mail cannot carry them.

  The honest default: on while no SMTP is configured, because otherwise a fresh
  install has no way in at all; off once mail works, because anyone who can
  read that file can sign in as anybody. An explicit `false` in the settings
  wins, and `config :slipdock, :login_fallback, false` beats even that — which
  is how the hosted instance keeps it off for good.
  """
  @spec login_fallback_enabled?() :: boolean()
  def login_fallback_enabled? do
    cond do
      Application.get_env(:slipdock, :login_fallback) == false -> false
      is_boolean(get().login_fallback_enabled) -> get().login_fallback_enabled
      true -> not smtp_configured?()
    end
  end

  @doc """
  Whether this server has terms somebody has to agree to.

  Only true once an admin has set both a link and a version. A self-hosted
  instance has neither, and then nothing about terms appears anywhere — there
  is nobody to have terms with.
  """
  @spec terms?() :: boolean()
  def terms? do
    settings = get()
    present?(settings.terms_url) and present?(settings.terms_version)
  end

  @doc "The version of the terms currently in force, or nil."
  def terms_version, do: get().terms_version

  @doc "Records that a test message really did reach the SMTP server."
  def mark_smtp_verified do
    case stored() do
      nil -> {:error, :not_configured}
      instance -> instance |> Instance.verified_changeset() |> Repo.update() |> tap_clear_cache()
    end
  end

  @doc """
  The settings as form values, with the SMTP password left out. A blank
  password field means "leave it alone" when the form comes back, so the stored
  secret never travels to a browser and back.
  """
  def to_form_params(%Instance{} = instance) do
    instance
    |> Map.from_struct()
    |> Map.drop([:__meta__, :id, :smtp_password, :setup_token, :inserted_at, :updated_at])
    |> Map.new(fn {k, v} -> {Atom.to_string(k), v} end)
  end

  @doc "Whether a password is stored, without saying what it is."
  def smtp_password_set?, do: is_binary(get().smtp_password) and get().smtp_password != ""

  ## The setup token

  @doc """
  The one-time token `/setup` demands, minted and logged on first boot so that
  whoever reaches an unclaimed instance first cannot simply claim it. Returns
  the existing token if there already is one — it is minted once, not per boot,
  or a restart would invalidate a token somebody is halfway through using.
  """
  @spec ensure_setup_token() :: String.t() | nil
  def ensure_setup_token do
    cond do
      setup_complete?() ->
        nil

      token = get().setup_token ->
        token

      true ->
        token = Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)

        stored()
        |> Kernel.||(%Instance{id: @id})
        |> Ecto.Changeset.change(setup_token: token)
        |> Repo.insert_or_update()
        |> tap_clear_cache()

        token
    end
  end

  @doc """
  Whether `token` is the setup token. False once setup is complete, whatever
  is passed, and false for a blank token so a missing parameter cannot match a
  missing value.
  """
  @spec valid_setup_token?(String.t() | nil) :: boolean()
  def valid_setup_token?(token) when is_binary(token) and token != "" do
    case get().setup_token do
      stored when is_binary(stored) and stored != "" ->
        not setup_complete?() and Plug.Crypto.secure_compare(stored, token)

      _ ->
        false
    end
  end

  def valid_setup_token?(_), do: false

  @doc """
  Where to send somebody to set this server up. Logged on first boot, and the
  only place the token is ever shown.
  """
  @spec setup_url(String.t()) :: String.t()
  def setup_url(token) do
    # Borrowed rather than duplicated: the automation runner already works out
    # this server's externally reachable URL for the links it puts in emails.
    "#{Slipdock.Automations.Runner.base_url()}/setup?token=#{URI.encode_www_form(token)}"
  end

  ## The allowlist

  @doc "Every allowlist entry, newest last."
  def list_allowlist do
    AllowlistEntry
    |> order_by([e], asc: e.entry)
    |> preload(:added_by)
    |> Repo.all()
  end

  @doc """
  Adds an address or a domain to the allowlist. `example.com` means anybody
  there, exactly as `SLIPDOCK_SIGNUP_ALLOW` meant it. Adding the same entry
  twice is not an error.
  """
  def add_allowlist_entry(entry, added_by \\ nil) do
    attrs = %{"entry" => entry, "added_by_id" => added_by && added_by.id}

    %AllowlistEntry{}
    |> AllowlistEntry.changeset(attrs)
    |> Repo.insert(on_conflict: :nothing, conflict_target: :entry)
  end

  def remove_allowlist_entry(%AllowlistEntry{} = entry), do: Repo.delete(entry)

  def remove_allowlist_entry(id) when is_integer(id) or is_binary(id) do
    case Repo.get(AllowlistEntry, id) do
      nil -> {:error, :not_found}
      entry -> Repo.delete(entry)
    end
  end

  @doc """
  Whether `email` matches the allowlist — as the whole address, or as its
  domain. Also stamps the matching entry's `last_used_at`, so an admin can see
  which lines are earning their place.
  """
  @spec allowlisted?(String.t()) :: boolean()
  def allowlisted?(email) when is_binary(email) do
    email = AllowlistEntry.normalise(email)
    domain = email |> String.split("@") |> List.last()

    case Repo.one(
           from(e in AllowlistEntry, where: e.entry in ^Enum.uniq([email, domain]), limit: 1)
         ) do
      nil ->
        false

      entry ->
        Repo.update_all(from(e in AllowlistEntry, where: e.id == ^entry.id),
          set: [last_used_at: DateTime.utc_now() |> DateTime.truncate(:second)]
        )

        true
    end
  end

  def allowlisted?(_), do: false

  ## Seeding from the environment

  @doc """
  Writes the row for the first time, from the environment, and never touches it
  again. Called on boot (see `Slipdock.Application`).

  Three jobs:

    * carry the old `SLIPDOCK_OPEN_SIGNUP` / `SLIPDOCK_SIGNUP_ALLOW` /
      `SLIPDOCK_SMTP_*` configuration into the row, so an upgrade keeps
      behaving as it did;
    * accept `SLIPDOCK_ADMIN_EMAIL` so a container can be configured with no
      browser and never see the wizard;
    * mark an instance that already has users as set up, because such a server
      was claimed long before this table existed and must not be offered to
      whoever reaches `/setup` next.
  """
  @spec seed() :: :ok
  def seed do
    if stored() do
      :ok
    else
      attrs = seed_attrs()

      case Repo.insert(Instance.changeset(%Instance{id: @id}, attrs)) do
        {:ok, _} ->
          clear_cache()
          seed_allowlist()
          maybe_claim_existing_instance(attrs)
          :ok

        {:error, changeset} ->
          Logger.error(
            "Could not seed settings from the environment: #{inspect(changeset.errors)}"
          )

          :ok
      end
    end
  end

  defp seed_attrs do
    legacy = Application.get_env(:slipdock, :signups, [])
    configured = Application.get_env(:slipdock, :settings, [])
    smtp = Application.get_env(:slipdock, :seed_smtp, [])

    mode =
      cond do
        configured[:signup_mode] -> configured[:signup_mode]
        legacy[:open] == true -> :open
        present?(legacy[:allow]) -> :allowlist
        true -> :closed
      end

    %{
      "signup_mode" => mode,
      "free_card_limit" => configured[:free_card_limit],
      "user_directory" => configured[:user_directory] || :instance
      # Left out entirely when unconfigured, so the schema's own defaults (the
      # guardrails, switched on) stand rather than being seeded over with nil.
    }
    |> Map.merge(configured_limits(configured))
    |> Map.merge(%{
      "invites_create_accounts" =>
        if(is_boolean(configured[:invites_create_accounts]),
          do: configured[:invites_create_accounts],
          else: true
        ),
      "admin_email" => configured[:admin_email],
      "smtp_host" => smtp[:host],
      "smtp_port" => smtp[:port],
      "smtp_username" => smtp[:username],
      "smtp_password" => smtp[:password],
      "smtp_from_name" => smtp[:from_name],
      "smtp_from_email" => smtp[:from_email],
      "smtp_tls" => smtp[:tls] || :if_available
    })
  end

  # The guardrails as seed attributes, each left out unless the environment
  # actually said something about it.
  defp configured_limits(configured) do
    %{
      "board_limit" => configured[:board_limit],
      "board_limit_enabled" => configured[:board_limit_enabled],
      "item_limit" => configured[:item_limit],
      "item_limit_enabled" => configured[:item_limit_enabled],
      "storage_limit_mb" => configured[:storage_limit_mb],
      "storage_limit_enabled" => configured[:storage_limit_enabled],
      "trial_days" => configured[:trial_days],
      "trial_enabled" => configured[:trial_enabled]
    }
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp seed_allowlist do
    for entry <- Application.get_env(:slipdock, :signups, [])[:allow] || [] do
      add_allowlist_entry(entry)
    end
  end

  # An instance that already has users, or that was handed an admin address in
  # the environment, is claimed: the wizard would be a land grab, not a setup.
  defp maybe_claim_existing_instance(attrs) do
    cond do
      is_binary(attrs["admin_email"]) ->
        complete_setup(%{"admin_email" => attrs["admin_email"]})
        make_admin(attrs["admin_email"])

        Logger.info(
          "Settings seeded from the environment; setup marked complete and " <>
            "#{attrs["admin_email"]} is the admin."
        )

      Repo.aggregate(Slipdock.Accounts.User, :count) > 0 ->
        email = oldest_user_email()
        complete_setup(%{"admin_email" => email})
        if Slipdock.Accounts.list_admins() == [], do: make_admin(email)

        Logger.info(
          "This server already had users, so setup is marked complete and /setup " <>
            "is closed. The oldest account is the admin."
        )

      true ->
        :ok
    end
  end

  # Naming an admin address is not the same as there being an account for it.
  # Without this, `SLIPDOCK_ADMIN_EMAIL` closed the wizard, left registration
  # closed and created nobody — so the address it named was refused at the
  # sign-in page ("not allowed to sign up here") and the server had no way in
  # at all. The command-line setup (`Slipdock.Release.setup/1`) always did
  # this; seeding from the environment did not.
  defp make_admin(email) do
    with {:ok, user} <- Slipdock.Accounts.get_or_create_user_by_email(email) do
      Slipdock.Accounts.promote(user)
    end
  end

  defp oldest_user_email do
    Repo.one(from(u in Slipdock.Accounts.User, order_by: [asc: u.id], limit: 1, select: u.email))
  end

  ## Internals

  defp load do
    stored() || defaults()
  end

  defp stored, do: Repo.get(Instance, @id)

  # What the application reads before anything has been saved. Deliberately
  # built from config rather than from the schema's defaults, so the test
  # environment (and a container's environment) can describe a coherent server
  # without writing a row first.
  defp defaults do
    configured = Application.get_env(:slipdock, :settings, [])
    legacy = Application.get_env(:slipdock, :signups, [])

    mode =
      cond do
        configured[:signup_mode] -> configured[:signup_mode]
        legacy[:open] == true -> :open
        true -> :closed
      end

    %Instance{
      id: @id,
      signup_mode: mode,
      free_card_limit: configured[:free_card_limit],
      user_directory: configured[:user_directory] || :instance,
      invites_create_accounts:
        if(is_boolean(configured[:invites_create_accounts]),
          do: configured[:invites_create_accounts],
          else: true
        ),
      admin_email: configured[:admin_email],
      setup_completed_at: if(configured[:setup_completed], do: ~U[2000-01-01 00:00:00Z]),
      smtp_tls: :if_available
    }
    |> struct(
      configured_limits(configured)
      |> Map.new(fn {k, v} -> {String.to_existing_atom(k), v} end)
    )
  end

  defp tap_clear_cache({:ok, _} = result) do
    clear_cache()
    result
  end

  defp tap_clear_cache(other), do: other

  defp cache_enabled?, do: Application.get_env(:slipdock, :settings_cache, true) != false

  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?([]), do: false
  defp present?(_), do: true
end
