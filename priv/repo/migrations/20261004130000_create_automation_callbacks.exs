defmodule Slipdock.Repo.Migrations.CreateAutomationCallbacks do
  use Ecto.Migration

  # One row per callback a rule has made, so the board's owner can see what
  # went out and what came back. The rule's and card's names are copied in,
  # because the log should still read after either is deleted.
  def change do
    create table(:automation_callbacks) do
      add :board_id, references(:boards, on_delete: :delete_all), null: false
      add :rule_id, references(:automation_rules, on_delete: :nilify_all)
      add :card_id, references(:cards, on_delete: :nilify_all)
      add :rule_name, :string
      add :card_title, :string
      add :method, :string, null: false
      add :url, :text, null: false
      add :status, :integer
      add :error, :text
      add :duration_ms, :integer

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:automation_callbacks, [:board_id, :id])
  end
end
