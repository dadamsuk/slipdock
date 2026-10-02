defmodule Slipdock.Repo.Migrations.CreateSettings do
  use Ecto.Migration

  # One row, id 1, holding what used to live in `config :slipdock, :signups`
  # and the `SLIPDOCK_SMTP_*` environment variables — so a browser can change
  # it. `Slipdock.Settings` keeps the singleton honest; SQLite will not take an
  # ALTER TABLE ADD CONSTRAINT after the fact, so the invariant is in the code
  # rather than in a check constraint here.
  def change do
    create table(:settings) do
      # Who may start an account: open, allowlist, approval, closed.
      add :signup_mode, :string, null: false, default: "closed"
      # How many non-archived cards a free account's own boards may hold.
      # Null means no limit, which is what a self-hosted install wants.
      add :free_card_limit, :integer
      # Who shows up in pickers and prompts: "instance" (everyone here, as it
      # was before) or "shared_only" (people you share something with).
      add :user_directory, :string, null: false, default: "instance"
      # Whether sharing something with an unknown address creates an account
      # for it. On, that address becomes a real user subject to the card limit.
      add :invites_create_accounts, :boolean, null: false, default: true
      # Where approval notices and lock-out warnings go.
      add :admin_email, :string
      # Set once, by the setup wizard. Non-null means the wizard is gone and
      # no sign-in can claim this server any more.
      add :setup_completed_at, :utc_datetime
      # A one-time token, logged at first boot, that /setup demands. Cleared
      # when setup completes.
      add :setup_token, :string

      # Mail. Held in the clear, like the OpenRouter keys in ai_keys.json: the
      # database file is already the most sensitive thing on the disk. Never
      # rendered back to a browser.
      add :smtp_host, :string
      add :smtp_port, :integer
      add :smtp_username, :string
      add :smtp_password, :string
      add :smtp_from_name, :string
      add :smtp_from_email, :string
      # "always", "never" or "if_available", matching gen_smtp.
      add :smtp_tls, :string, null: false, default: "if_available"
      add :smtp_verified_at, :utc_datetime

      # Whether sign-in codes may be written to a file when mail is not
      # working. Null means "decide from whether SMTP is configured", which is
      # the sensible default in both directions.
      add :login_fallback_enabled, :boolean

      timestamps(type: :utc_datetime)
    end

    # Addresses and domains that may register under the "allowlist" mode.
    # `example.com` means anybody there, exactly as SLIPDOCK_SIGNUP_ALLOW did.
    create table(:signup_allowlist_entries) do
      add :entry, :string, null: false
      # Set when an address from this entry actually signs up, so an admin can
      # see which lines are doing anything.
      add :last_used_at, :utc_datetime
      add :added_by_id, references(:users, on_delete: :nilify_all)

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:signup_allowlist_entries, [:entry])
  end
end
