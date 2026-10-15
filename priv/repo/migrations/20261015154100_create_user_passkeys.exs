defmodule Slipdock.Repo.Migrations.CreateUserPasskeys do
  use Ecto.Migration

  # Passkeys (#828): a WebAuthn credential a person can sign in with instead
  # of an emailed link. The credential id is the authenticator's handle for
  # it and is unique across the server; the public key is the COSE key the
  # authenticator handed over when it was added.
  def change do
    create table(:user_passkeys) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :credential_id, :binary, null: false
      add :public_key, :binary, null: false
      add :sign_count, :bigint, null: false, default: 0
      add :name, :string, null: false
      add :aaguid, :binary
      add :last_used_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:user_passkeys, [:credential_id])
    create index(:user_passkeys, [:user_id])

    # Challenges that have been answered. The challenge itself rides in the
    # session cookie between the two halves of a ceremony, and a cookie can
    # be kept and sent again; this is what makes each one good for one use.
    # Rows are worthless once the challenge has expired and are swept then.
    create table(:passkey_spent_challenges, primary_key: false) do
      add :digest, :binary, primary_key: true
      add :expires_at, :utc_datetime, null: false
    end

    create index(:passkey_spent_challenges, [:expires_at])
  end
end
