defmodule Slipdock.Repo.Migrations.AddHandoffSettingsToBoards do
  use Ecto.Migration

  # A board's own name for "Left off" and its own instructions for drafting
  # a handoff (#1212). nil keeps the built-in ones.
  def change do
    alter table(:boards) do
      add :handoff_label, :string
      add :handoff_prompt, :text
    end
  end
end
