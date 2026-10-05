defmodule Slipdock.Repo.Migrations.AddUnlimitedToUsers do
  use Ecto.Migration

  # Somebody an admin has taken off the free tier for good, without inventing
  # a paid-up date for them (see `Slipdock.Quota.free?/1`). The guardrails
  # still apply to them, as they do to admins.
  def change do
    alter table(:users) do
      add :unlimited, :boolean, null: false, default: false
    end
  end
end
