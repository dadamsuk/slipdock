defmodule Slipdock.Repo.Migrations.CreateCardProvenance do
  use Ecto.Migration

  def change do
    # Where a card, or a change to it, came from when that was a meeting
    # (G11): kept on the card, so it reads true after the capture, its
    # transcript and its recording are long gone.
    create table(:card_provenance) do
      add :card_id, references(:cards, on_delete: :delete_all), null: false
      add :capture_id, references(:captures, on_delete: :nilify_all)
      add :kind, :string, null: false, default: "created"
      add :meeting, :string, null: false
      add :met_at, :utc_datetime
      add :quote, :text
      add :speaker, :string
      add :at_ms, :integer
      add :line, :string
      add :read, :text
      add :committed_by, :string
      add :committed_at, :utc_datetime, null: false
    end

    create index(:card_provenance, [:card_id])
    create index(:card_provenance, [:capture_id])
  end
end
