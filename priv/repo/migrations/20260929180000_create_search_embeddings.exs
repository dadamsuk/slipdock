defmodule Slipdock.Repo.Migrations.CreateSearchEmbeddings do
  use Ecto.Migration

  def change do
    create table(:search_embeddings) do
      # What was embedded: "card", "comment" or "status_update", and that
      # row's id. Every chunk also carries the card and board it belongs to,
      # so results roll up to a card and permission filtering is one `in`.
      add :kind, :string, null: false
      add :source_id, :integer, null: false
      add :card_id, references(:cards, on_delete: :delete_all), null: false
      add :board_id, references(:boards, on_delete: :delete_all), null: false

      # The text that was embedded, kept for the snippet in results and so a
      # reindex can tell what changed without re-reading every association.
      add :body, :text, null: false
      # SHA-256 of `body`: unchanged text is never re-embedded.
      add :content_hash, :string, null: false

      # Which model produced the vector and at what size. A change to either
      # makes every existing row stale (see `mix slipdock.reindex`).
      add :model, :string, null: false
      add :dimensions, :integer, null: false
      # The vector itself: `dimensions` 32-bit little-endian floats, unit
      # length, so cosine similarity is a dot product.
      add :vector, :binary, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:search_embeddings, [:kind, :source_id])
    create index(:search_embeddings, [:board_id])
    create index(:search_embeddings, [:card_id])
  end
end
