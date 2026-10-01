defmodule Slipdock.Repo.Migrations.CreateDeviceAuthorizations do
  use Ecto.Migration

  def change do
    create table(:device_authorizations) do
      # Hashed, exactly as magic-link and API tokens are: what the client
      # polls with never touches the database in the clear.
      add :device_code, :binary, null: false
      # Short, human-typed, single use.
      add :user_code, :string, null: false
      # What the resulting token should be scoped to.
      add :scope, :string, null: false, default: "write"
      add :scope_boards, {:array, :integer}, null: false, default: []
      # What the client said it is, and where it asked from — shown on the
      # approval screen, because approving blind is approving anything.
      add :client_label, :string
      add :client_ip, :string
      add :client_agent, :string
      add :expires_at, :utc_datetime, null: false
      add :approved_at, :utc_datetime
      add :denied_at, :utc_datetime
      # Set when approved: who approved it, and so who the token belongs to.
      add :user_id, references(:users, on_delete: :delete_all)

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:device_authorizations, [:device_code])
    create unique_index(:device_authorizations, [:user_code])
    create index(:device_authorizations, [:expires_at])
  end
end
