defmodule Slipdock.Repo.Migrations.AddUserTimezone do
  use Ecto.Migration

  # Each person's IANA timezone (#1048), for recurring cards and snooze. Null
  # until the browser first says (read as Etc/UTC meanwhile; see
  # `Slipdock.Timezones`).
  def change do
    alter table(:users) do
      add :timezone, :string
    end
  end
end
