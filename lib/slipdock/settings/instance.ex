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
  @meeting_visibilities [:used_only, :every_board]

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

    # Product analytics. Nothing PostHog-related reaches a browser until both a
    # key and a host are filled in — see `Slipdock.Settings.posthog/0`.
    # `posthog_respect_dnt` decides whether a visitor who asks not to be tracked
    # is left out; on by default, and threaded through to the client.
    field :posthog_key, :string
    field :posthog_host, :string
    field :posthog_respect_dnt, :boolean, default: true

    # Meeting capture (see `Slipdock.Meetings`): off until an admin turns it
    # on, and then either shown only on boards that have had a capture
    # (`:used_only`, with one entry in the board's menu everywhere else) or
    # on every board. `meetings_hideable` lets each person put it out of sight.
    field :meetings_enabled, :boolean, default: false
    field :meetings_visibility, Ecto.Enum, values: @meeting_visibilities, default: :used_only
    field :meetings_hideable, :boolean, default: true
    # What a capture may be sent, each switched on or off for the server.
    field :meetings_accept_transcripts, :boolean, default: true
    field :meetings_accept_audio, :boolean, default: true
    field :meetings_accept_findings, :boolean, default: true
    # Which models read a meeting: nil reads with the person's own model;
    # the second reading is the same model again, another, or none.
    field :meetings_reading_model, :string
    field :meetings_second_reading, :string, default: "same"
    field :meetings_second_model, :string
    # What one person may use of meeting capture in a month (see
    # `Slipdock.Meetings.Usage`). A number and a switch each, like the
    # guardrails; the longest meeting and the largest file are always on.
    field :meetings_transcription_minutes, :integer, default: 600
    field :meetings_transcription_minutes_enabled, :boolean, default: true
    field :meetings_audio_storage_mb, :integer, default: 2048
    field :meetings_audio_storage_mb_enabled, :boolean, default: true
    field :meetings_transcript_captures, :integer, default: 200
    field :meetings_transcript_captures_enabled, :boolean, default: true
    field :meetings_longest_minutes, :integer, default: 240
    field :meetings_max_file_mb, :integer, default: 500
    field :meetings_audio_retention, :string, default: "30_days"
    # Who turns a recording into words (see `Slipdock.Meetings.Transcriber`).
    field :meetings_transcription, :string, default: "none"
    field :meetings_transcription_model, :string, default: "openai/whisper-large-v3"
    field :meetings_transcription_url, :string
    field :meetings_transcription_max_mb, :integer, default: 25
    # How voices are separated and attributed (see `Slipdock.Meetings.Speakers`).
    field :meetings_diarisation, :string, default: "labels"
    field :meetings_diarisation_url, :string
    field :meetings_dialogue_inference, :boolean, default: true
    # The audio-capable model unclear passages are re-listened to with
    # (see `Slipdock.Meetings.Relisten`); nil leaves re-listening off.
    field :meetings_relisten_model, :string

    # Whose AI settings unattended work runs on: the search indexer, every
    # search query, scheduled automations. An admin, because those settings
    # receive every board's content — see `Slipdock.AI.Keys.system_settings/0`.
    # Nil leaves it to the environment and the single-admin fallback.
    belongs_to :ai_system_user, Slipdock.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @doc "The registration modes, in the order the admin UI should offer them."
  def signup_modes, do: @signup_modes

  @doc "What `user_directory` may be."
  def directories, do: @directories

  @doc "What `smtp_tls` may be."
  def tls_modes, do: @tls_modes

  @doc "What `meetings_visibility` may be."
  def meeting_visibilities, do: @meeting_visibilities

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

  # Who may sign up, how much they get, and whether pages report to PostHog:
  # plain values an admin sets directly, through the admin page or `PATCH /api/admin/settings`.
  @policy_fields ~w(signup_mode free_card_limit user_directory invites_create_accounts
                    login_fallback_enabled board_limit board_limit_enabled item_limit
                    item_limit_enabled storage_limit_mb storage_limit_enabled
                    trial_days trial_enabled posthog_key posthog_host
                    posthog_respect_dnt ai_system_user_id meetings_enabled
                    meetings_visibility meetings_hideable meetings_accept_transcripts
                    meetings_accept_audio meetings_accept_findings meetings_reading_model
                    meetings_second_reading meetings_second_model
                    meetings_transcription_minutes meetings_transcription_minutes_enabled
                    meetings_audio_storage_mb meetings_audio_storage_mb_enabled
                    meetings_transcript_captures meetings_transcript_captures_enabled
                    meetings_longest_minutes meetings_max_file_mb meetings_audio_retention
                    meetings_transcription meetings_transcription_model
                    meetings_transcription_url meetings_transcription_max_mb
                    meetings_diarisation meetings_diarisation_url meetings_dialogue_inference
                    meetings_relisten_model)a

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
      :smtp_from_email,
      :posthog_key,
      :posthog_host,
      :meetings_reading_model,
      :meetings_second_model,
      :meetings_transcription_model,
      :meetings_transcription_url,
      :meetings_diarisation_url,
      :meetings_relisten_model
    ])
    |> validate_inclusion(:meetings_transcription, ~w(none provider endpoint))
    |> validate_inclusion(:meetings_diarisation, ~w(labels endpoint))
    |> validate_web_url(:meetings_diarisation_url)
    |> then(fn cs ->
      if get_field(cs, :meetings_diarisation) == "endpoint" and
           get_field(cs, :meetings_diarisation_url) in [nil, ""],
         do:
           add_error(cs, :meetings_diarisation_url, "is needed to separate voices on an endpoint"),
         else: cs
    end)
    |> validate_number(:meetings_transcription_max_mb, greater_than: 0)
    |> validate_web_url(:meetings_transcription_url)
    |> then(fn cs ->
      if get_field(cs, :meetings_transcription) == "endpoint" and
           get_field(cs, :meetings_transcription_url) in [nil, ""],
         do: add_error(cs, :meetings_transcription_url, "is needed to transcribe on an endpoint"),
         else: cs
    end)
    |> validate_number(:meetings_transcription_minutes, greater_than_or_equal_to: 0)
    |> validate_number(:meetings_audio_storage_mb, greater_than_or_equal_to: 0)
    |> validate_number(:meetings_transcript_captures, greater_than_or_equal_to: 0)
    |> validate_number(:meetings_longest_minutes, greater_than: 0)
    |> validate_number(:meetings_max_file_mb, greater_than: 0)
    |> validate_inclusion(:meetings_audio_retention, ~w(until_committed 30_days 90_days))
    |> validate_inclusion(:meetings_second_reading, ~w(same model off),
      message: "is same, model or off"
    )
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
    |> validate_web_url(:posthog_host)
    |> validate_format(:posthog_key, ~r/\A[A-Za-z0-9_-]+\z/,
      message: "should be a PostHog project key, like phc_..."
    )
    |> require_sender_with_host()
    |> require_mail_for_approval()
    |> validate_ai_system_user()
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

  # Every board's content goes through these settings, so only an admin's will
  # do: anyone else could point their account at a server of their own and
  # receive the lot. Not checked again here when the person is later demoted —
  # `Slipdock.AI.Keys` ignores the choice then, rather than this row refusing
  # to save something else.
  defp validate_ai_system_user(changeset) do
    validate_change(changeset, :ai_system_user_id, fn field, id ->
      case Slipdock.Repo.get(Slipdock.Accounts.User, id) do
        %{admin: true, disabled_at: nil} -> []
        %{admin: true} -> [{field, "is disabled"}]
        %{} -> [{field, "must be an admin: every board's content goes through their settings"}]
        nil -> [{field, "is not an account here"}]
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
