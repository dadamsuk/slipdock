defmodule Slipdock.Repo.Migrations.RecordWhoInvitedWhom do
  use Ecto.Migration

  def change do
    alter table(:users) do
      # An account that exists because somebody shared something with that
      # address, rather than because its owner asked for one. Worth recording:
      # the admin list can tell the two apart, and on a server people pay for,
      # abuse is traceable to whoever did the inviting.
      add :invited_by_id, references(:users, on_delete: :nilify_all)
      add :invited_at, :utc_datetime
    end

    create index(:users, [:invited_by_id])
  end
end
