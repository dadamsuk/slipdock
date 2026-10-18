defmodule Slipdock.Repo.Migrations.AddCardSnooze do
  use Ecto.Migration

  # Snooze (W-1803): a card hidden until a moment, by whom, why, and how it
  # wakes. Null `snoozed_until` is a card that isn't snoozed; one in the past
  # is waiting for the scheduler's tick to clear it.
  def change do
    alter table(:cards) do
      add :snoozed_until, :utc_datetime
      add :snoozed_by_id, references(:users, on_delete: :nilify_all)
      add :snooze_note, :string, size: 280
      add :snooze_notify, :boolean, null: false, default: false
      add :snooze_wake_on_activity, :boolean, null: false, default: true
    end

    create index(:cards, [:snoozed_until], where: "snoozed_until IS NOT NULL")
  end
end
