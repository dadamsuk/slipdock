defmodule Slipdock.Repo.Migrations.CreateSkillEnablements do
  @moduledoc """
  A skill registry entry enabled on a board (#2062, spec W-2513 §Enabling per
  board). Enabling pins the text the writer read: its hash and the text
  itself, so a refresh that changes the entry changes nothing agents get
  until a writer re-pins it. One enablement per skill name per board. An
  entry removed upstream leaves its enablement, and its pinned text, until a
  writer disables it.
  """
  use Ecto.Migration

  def change do
    create table(:skill_enablements) do
      add :board_id, references(:boards, on_delete: :delete_all), null: false
      add :entry_id, references(:skill_entries, on_delete: :nilify_all)
      add :enabled_by_id, references(:users, on_delete: :nilify_all)
      add :name, :string, null: false
      add :description, :text
      add :source_name, :string
      add :source_url, :string, size: 2000
      add :licence, :string
      add :version, :string
      add :pinned_hash, :string, null: false
      add :pinned_body, :text, null: false
      add :pinned_at, :utc_datetime, null: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:skill_enablements, [:board_id, :name])
    create index(:skill_enablements, [:entry_id])
  end
end
