defmodule Slipdock.Repo.Migrations.CreateSavedQueries do
  use Ecto.Migration

  @moduledoc """
  Saved queries: the questions one person asks their boards again and again.

  Only the question is kept, never the answer. "What's at risk this week"
  is worth saving; what it said last Tuesday is not — the whole point of
  asking again is that the answer has moved on.

  They belong to the person, like `favourites`, and `mode` says which box
  the text belongs in: "search" for the ones that find cards, "ask" for the
  ones a model answers. The same words can be saved once in each.
  """

  def change do
    create table(:saved_queries) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :mode, :string, null: false
      add :text, :string, null: false
      timestamps(type: :utc_datetime)
    end

    create index(:saved_queries, [:user_id, :mode])
    create unique_index(:saved_queries, [:user_id, :mode, :text])
  end
end
