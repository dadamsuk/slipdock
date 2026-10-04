defmodule Slipdock.Settings.Instance do
  @moduledoc """
  The one settings row: who may register here, what a free account may do, who
  can see whom, and how mail goes out.

  Everything on it used to be an environment variable read at boot, which is
  why none of it could be changed from a browser. It is data now;
  `Slipdock.Settings` is how you read and write it, and the environment only
  seeds it (see `Slipdock.Settings.seed/0`).

  The SMTP password is stored as it was given. The database file already holds
  every card and comment on the server, and the OpenRouter keys next to it in
  `ai_keys.json` are in the clear too, so encrypting this one column would buy
  nothing but a key to lose. It is never sent back to a browser — see
  `Slipdock.Settings.to_form_params/1`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @signup_modes [:open, :allowlist, :approval, :closed]
  @directories [:instance, :shared_only]
  @tls_modes [:always, :never, :if_available]

  schema "settings" do
    field :signup_mode, Ecto.Enum, values: @signup_modes, default: :closed
    field :free_card_limit, :integer

    # The guardrails. Unlike `free_card_limit`, which is the free tier's
    # allowance and blank on a self-hosted install, these are on everywhere
    # with the same generous defaults — a self-hosted server nobody pays for
    # still wants a ceiling, if only to notice a runaway script. Each is a
    # number and a switch, so turning one off does not lose the number.
    field :board_limit, :integer, default: 1_000
    field :board_limit_enabled, :boolean, default: true
    field :item_limit, :integer, default: 250_000
    field :item_limit_enabled, :boolean, default: true
    field :storage_limit_mb, :integer, default: 10_240
    field :storage_limit_enabled, :boolean, default: true

    # How long a free account may go on adding things, counted from the day it
    # was made. Off by default: a self-hosted install has nobody to bill and
    # must not expire. Independent of the counts above — an account can have no
    # card limit at all and still be on a month's trial, or have both.
    field :trial_days, :integer, default: 30
    field :trial_enabled, :boolean, default: false

    field :user_directory, Ecto.Enum, values: @directories, default: :instance
    field :invites_create_accounts, :boolean, default: true
    field :admin_email, :string
    field :setup_completed_at, :utc_datetime
    field :setup_token, :string

    field :smtp_host, :string
    field :smtp_port, :integer
    field :smtp_username, :string
    field :smtp_password, :string
    field :smtp_from_name, :string
    field :smtp_from_email, :string
    field :smtp_tls, Ecto.Enum, values: @tls_modes, default: :if_available
    field :smtp_verified_at, :utc_datetime

    field :login_fallback_enabled, :boolean

    # Terms and a privacy notice, for a server run for other people. Empty on a
    # self-hosted one, where there is nobody to have terms with.
    field :terms_url, :string
    field :privacy_url, :string
    field :terms_version, :string

    timestamps(type: :utc_datetime)
  end

  @doc "The registration modes, in the order the admin UI should offer them."
  def signup_modes, do: @signup_modes

  @doc "What `user_directory` may be."
  def directories, do: @directories

  @doc "What `smtp_tls` may be."
  def tls_modes, do: @tls_modes

  @doc """
  How each mode reads to a person choosing one. The admin UI and the setup
  wizard both show these, so the wording lives here rather than in two
  templates that can drift apart.
  """
  def describe(:open),
    do:
      {"Anyone can register",
       "Any address that can reach this server can make an account. Right behind " <>
         "Tailscale or a VPN; dangerous on the open internet."}

  def describe(:allowlist),
    do:
      {"Only addresses I list",
       "You keep a list of addresses and domains. Everyone else is turned away " <>
         "without being told why."}

  def describe(:approval),
    do:
      {"I approve each request",
       "People ask for an account and you say yes or no. Needs working email, " <>
         "or nobody will know a request is waiting."}

  def describe(:closed),
    do:
      {"Nobody can register",
       "Accounts exist only because you created them by sharing a board or a " <>
         "card with someone."}

  # Who may sign up and how much they get: plain values an admin sets
  # directly, through the admin page or `PATCH /api/admin/settings`.
  @policy_fields ~w(signup_mode free_card_limit user_directory invites_create_accounts
                    login_fallback_enabled board_limit board_limit_enabled item_limit
                    item_limit_enabled storage_limit_mb storage_limit_enabled
                    trial_days trial_enabled)a

  # The admin address and the SMTP details each have a flow that proves
  # something first (a code to the new address, a test message that arrived),
  # and the legal links live on their own page.
  @fields @policy_fields ++
            ~w(admin_email smtp_host smtp_port smtp_username smtp_password
               smtp_from_name smtp_from_email smtp_tls terms_url privacy_url
               terms_version)a

  @doc "The settings an admin may change directly, as the strings a request carries."
  def policy_fields, do: Enum.map(@policy_fields, &Atom.to_string/1)

  @doc """
  Validates a change to the settings. Blank strings become nil rather than
  empty values, because a cleared form field means "unset", and an SMTP host of
  `""` would otherwise read as configured.
  """
  def changeset(instance, attrs) do
    instance
    |> cast(attrs, @fields)
    |> blank_to_nil([
      :terms_url,
      :privacy_url,
      :terms_version,
      :admin_email,
      :smtp_host,
      :smtp_username,
      :smtp_password,
      :smtp_from_name,
      :smtp_from_email
    ])
    |> validate_number(:free_card_limit, greater_than: 0)
    |> validate_number(:board_limit, greater_than: 0)
    |> validate_number(:item_limit, greater_than: 0)
    |> validate_number(:storage_limit_mb, greater_than: 0)
    |> validate_number(:trial_days, greater_than: 0)
    |> require_number_when_enabled()
    |> validate_number(:smtp_port, greater_than: 0, less_than: 65_536)
    |> Slipdock.Email.validate(:admin_email)
    |> Slipdock.Email.validate(:smtp_from_email)
    |> validate_web_url(:terms_url)
    |> validate_web_url(:privacy_url)
    |> require_sender_with_host()
    |> require_mail_for_approval()
    |> clear_verification_when_mail_changes()
  end

  # These are links on the public sign-in page, so anything but a plain web
  # address — `javascript:` above all — is refused rather than rendered.
  defp validate_web_url(changeset, field) do
    validate_change(changeset, field, fn _, url ->
      case URI.parse(url) do
        %URI{scheme: scheme, host: host}
        when scheme in ["http", "https"] and is_binary(host) and host != "" ->
          []

        _ ->
          [{field, "must be an http:// or https:// address"}]
      end
    end)
  end

  @doc """
  Marks setup as finished: the admin's address, and the stamp that makes the
  wizard unreachable. Also drops the setup token, which has done its job.
  """
  def complete_setup_changeset(instance, attrs) do
    instance
    |> changeset(attrs)
    |> validate_required([:admin_email])
    |> put_change(:setup_completed_at, DateTime.utc_now() |> DateTime.truncate(:second))
    |> put_change(:setup_token, nil)
  end

  @doc "Records that a test message actually reached the SMTP server."
  def verified_changeset(instance) do
    change(instance, smtp_verified_at: DateTime.utc_now() |> DateTime.truncate(:second))
  end

  @limits [
    {:board_limit_enabled, :board_limit},
    {:item_limit_enabled, :item_limit},
    {:storage_limit_enabled, :storage_limit_mb},
    {:trial_enabled, :trial_days}
  ]

  @doc "The guardrails, as `{switch, number}` pairs, in the order the UI shows them."
  def limit_fields, do: @limits

  # A limit switched on with no number is a limit of nothing: every write would
  # be refused. Refuse the setting instead.
  defp require_number_when_enabled(changeset) do
    Enum.reduce(@limits, changeset, fn {switch, number}, acc ->
      if get_field(acc, switch) and is_nil(get_field(acc, number)) do
        add_error(acc, number, "is needed when this limit is switched on")
      else
        acc
      end
    end)
  end

  # Approval mode without mail is a queue nobody looks at: somebody asks, an
  # admin is never told, and the request sits there until the person gives up.
  # Better to refuse the setting than to accept it and quietly not work.
  defp require_mail_for_approval(changeset) do
    if get_field(changeset, :signup_mode) == :approval and
         get_field(changeset, :smtp_host) in [nil, ""] do
      add_error(
        changeset,
        :signup_mode,
        "needs a mail server: nobody would be told that somebody is waiting"
      )
    else
      changeset
    end
  end

  # A host with no from-address would send mail that most servers reject, and
  # the failure would look like "SMTP is broken" rather than "fill this in".
  defp require_sender_with_host(changeset) do
    if get_field(changeset, :smtp_host) do
      validate_required(changeset, [:smtp_from_email],
        message: "is needed when you send mail through a server"
      )
    else
      changeset
    end
  end

  # Any change to how mail is sent invalidates the last successful test send,
  # so the admin UI asks for another one before it will save.
  @mail_fields ~w(smtp_host smtp_port smtp_username smtp_password smtp_tls
                  smtp_from_email smtp_from_name)a

  defp clear_verification_when_mail_changes(changeset) do
    if Enum.any?(@mail_fields, &changed?(changeset, &1)) do
      put_change(changeset, :smtp_verified_at, nil)
    else
      changeset
    end
  end

  defp blank_to_nil(changeset, fields) do
    Enum.reduce(fields, changeset, fn field, acc ->
      case get_change(acc, field) do
        value when is_binary(value) ->
          case String.trim(value) do
            "" -> put_change(acc, field, nil)
            trimmed -> put_change(acc, field, trimmed)
          end

        _ ->
          acc
      end
    end)
  end
end
