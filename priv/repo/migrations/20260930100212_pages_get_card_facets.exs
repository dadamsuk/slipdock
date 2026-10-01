defmodule Slipdock.Repo.Migrations.PagesGetCardFacets do
  use Ecto.Migration

  @moduledoc """
  A wiki page gets the card's **facets**: the handful of attributes the board
  views filter, group, sort and colour by.

  The line is deliberate. A page takes the things that say *where it stands* —
  priority, flags, dates, who has it, how far through it is, a cover colour —
  because those are what make it groupable beside the cards, and a document
  being written has all of them: a spec can be blocked, a retro can be due
  Friday, a runbook can be somebody's.

  It does **not** take the card's contents — checklists, comments,
  dependencies, votes, custom fields, subcards. A page already has better
  versions of those: a whole body with revision history, backlinks, and a tree
  of child pages. Giving it a second, worse set would be two places to write
  the same thing down.
  """

  def change do
    alter table(:pages) do
      add :priority, :string, null: false, default: "none"
      add :flags, {:array, :string}, null: false, default: []
      add :start_date, :date
      add :due_date, :date
      # How precisely it is scheduled (see `Slipdock.Dates`), as for a card.
      add :date_precision, :string, null: false, default: "day"
      # "Written", for a document. Independent of `percent_complete`.
      add :completed, :boolean, null: false, default: false
      add :percent_complete, :integer
      add :color, :string
      add :assignee_id, references(:users, on_delete: :nilify_all)
    end

    create index(:pages, [:assignee_id])
    create index(:pages, [:due_date])
  end
end
