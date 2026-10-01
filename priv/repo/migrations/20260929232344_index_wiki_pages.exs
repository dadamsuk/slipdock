defmodule Slipdock.Repo.Migrations.IndexWikiPages do
  use Ecto.Migration

  @moduledoc """
  Phase 5 of `docs/wiki.md`: pages join the semantic index.

  A separate search over documents would be the whole point missed — "what
  did we decide about refunds" should find the decision record and the card
  that argued about it, in one list, ranked against each other.

  Two changes to `search_embeddings`:

    * `card_id` becomes optional and `page_id` appears, with exactly one of
      the two set. `board_id` stays required and non-null, because that is
      what the permission filter runs on, so the fast path is unchanged.
    * A `section` column joins the key. A page is chunked by heading (see
      `Slipdock.Search.Chunk.for_page/1`), so one page has many chunks and
      `{kind, source_id}` alone can no longer tell them apart. `docs/wiki.md`
      expected the key to stay as it was; it cannot, and a discriminator is
      the honest fix — for a card's chunks it is simply empty.

  SQLite cannot drop a NOT NULL, so the table is rebuilt. Nothing is lost:
  every row is derived from text that is still there, and `mix slipdock.reindex`
  rebuilds any that are not.
  """

  def up do
    execute """
    CREATE TABLE search_embeddings_new (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      kind TEXT NOT NULL,
      source_id INTEGER NOT NULL,
      section TEXT NOT NULL DEFAULT '',
      card_id INTEGER REFERENCES cards(id) ON DELETE CASCADE,
      page_id INTEGER REFERENCES pages(id) ON DELETE CASCADE,
      board_id INTEGER NOT NULL REFERENCES boards(id) ON DELETE CASCADE,
      body TEXT NOT NULL,
      content_hash TEXT NOT NULL,
      model TEXT NOT NULL,
      dimensions INTEGER NOT NULL,
      vector BLOB NOT NULL,
      inserted_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      CHECK ((card_id IS NOT NULL) + (page_id IS NOT NULL) = 1)
    )
    """

    execute """
    INSERT INTO search_embeddings_new (id, kind, source_id, section, card_id, page_id, board_id,
                                       body, content_hash, model, dimensions, vector,
                                       inserted_at, updated_at)
    SELECT id, kind, source_id, '', card_id, NULL, board_id,
           body, content_hash, model, dimensions, vector,
           inserted_at, updated_at FROM search_embeddings
    """

    execute "DROP TABLE search_embeddings"
    execute "ALTER TABLE search_embeddings_new RENAME TO search_embeddings"

    create unique_index(:search_embeddings, [:kind, :source_id, :section])
    create index(:search_embeddings, [:board_id])
    create index(:search_embeddings, [:card_id])
    create index(:search_embeddings, [:page_id])
  end

  def down do
    execute "DELETE FROM search_embeddings WHERE page_id IS NOT NULL"

    execute """
    CREATE TABLE search_embeddings_old (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      kind TEXT NOT NULL,
      source_id INTEGER NOT NULL,
      card_id INTEGER NOT NULL REFERENCES cards(id) ON DELETE CASCADE,
      board_id INTEGER NOT NULL REFERENCES boards(id) ON DELETE CASCADE,
      body TEXT NOT NULL,
      content_hash TEXT NOT NULL,
      model TEXT NOT NULL,
      dimensions INTEGER NOT NULL,
      vector BLOB NOT NULL,
      inserted_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
    """

    execute """
    INSERT INTO search_embeddings_old SELECT id, kind, source_id, card_id, board_id,
           body, content_hash, model, dimensions, vector, inserted_at, updated_at
    FROM search_embeddings
    """

    execute "DROP TABLE search_embeddings"
    execute "ALTER TABLE search_embeddings_old RENAME TO search_embeddings"

    create unique_index(:search_embeddings, [:kind, :source_id])
    create index(:search_embeddings, [:board_id])
    create index(:search_embeddings, [:card_id])
  end
end
