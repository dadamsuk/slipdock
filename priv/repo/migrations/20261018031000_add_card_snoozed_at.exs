defmodule Slipdock.Repo.Migrations.AddCardSnoozedAt do
  use Ecto.Migration

  # When the snooze was set, for the line a card writes when it wakes
  # ("snoozed by Ann on 3 Nov"). W-1803.
  def change do
    alter table(:cards) do
      add :snoozed_at, :utc_datetime
    end
  end
end
