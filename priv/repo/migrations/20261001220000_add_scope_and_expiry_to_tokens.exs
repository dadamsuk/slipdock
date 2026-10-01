defmodule Slipdock.Repo.Migrations.AddScopeAndExpiryToTokens do
  use Ecto.Migration

  def change do
    alter table(:users_tokens) do
      # What an API token may do. "write" is the default because every token
      # that existed before this migration could already do anything.
      add :scope, :string, null: false, default: "write"
      # Board ids the token is limited to; empty means the whole account.
      add :scope_boards, {:array, :integer}, null: false, default: []
      # Optional for hand-made tokens; the device flow will default it.
      add :expires_at, :utc_datetime
      add :last_used_ip, :string
    end

    create index(:users_tokens, [:expires_at])
  end
end
