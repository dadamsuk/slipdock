defmodule Slipdock.Repo.Migrations.PagesGetCardContents do
  use Ecto.Migration

  @moduledoc """
  A wiki page gets the card's *contents* as well as its facets: comments,
  status updates, a checklist, votes, web links and custom field values.

  Every one of these tables hung off a card and only a card. They now hang
  off exactly one of a card or a page, the way `attachments` already did —
  the same `CHECK ((card_id IS NOT NULL) + (page_id IS NOT NULL) = 1)`, so
  the database refuses a row that belongs to both or to neither.

  SQLite cannot drop a NOT NULL, so each table is rebuilt: create, copy,
  drop, rename. The column order below is the order the old tables had, and
  the copy names every column, so a future `.schema` diff stays readable.

  `activities` needed nothing: it grew `page_id` when pages were first put
  on the board, and its `card_id` was always nullable.

  Votes and field values keep their uniqueness per owner. SQLite treats NULLs
  in a unique index as distinct, so the existing `(card_id, user_id)` index
  ignores every page-owned row, and a second index does the same job for
  pages.
  """

  @tables [
    {"comments",
     """
     id INTEGER PRIMARY KEY AUTOINCREMENT,
     card_id INTEGER REFERENCES cards(id) ON DELETE CASCADE,
     page_id INTEGER REFERENCES pages(id) ON DELETE CASCADE,
     body TEXT NOT NULL,
     inserted_at TEXT NOT NULL,
     updated_at TEXT NOT NULL
     """, "id, card_id, page_id, body, inserted_at, updated_at"},
    {"status_updates",
     """
     id INTEGER PRIMARY KEY AUTOINCREMENT,
     card_id INTEGER REFERENCES cards(id) ON DELETE CASCADE,
     page_id INTEGER REFERENCES pages(id) ON DELETE CASCADE,
     user_id INTEGER REFERENCES users(id) ON DELETE SET NULL,
     health TEXT NOT NULL,
     body TEXT,
     inserted_at TEXT NOT NULL
     """, "id, card_id, page_id, user_id, health, body, inserted_at"},
    {"checklist_items",
     """
     id INTEGER PRIMARY KEY AUTOINCREMENT,
     card_id INTEGER REFERENCES cards(id) ON DELETE CASCADE,
     page_id INTEGER REFERENCES pages(id) ON DELETE CASCADE,
     text TEXT NOT NULL,
     done INTEGER DEFAULT false NOT NULL,
     position INTEGER DEFAULT 0 NOT NULL,
     inserted_at TEXT NOT NULL,
     updated_at TEXT NOT NULL
     """, "id, card_id, page_id, text, done, position, inserted_at, updated_at"},
    {"votes",
     """
     id INTEGER PRIMARY KEY AUTOINCREMENT,
     card_id INTEGER REFERENCES cards(id) ON DELETE CASCADE,
     page_id INTEGER REFERENCES pages(id) ON DELETE CASCADE,
     user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
     count INTEGER DEFAULT 1 NOT NULL,
     comment TEXT,
     inserted_at TEXT NOT NULL,
     updated_at TEXT NOT NULL
     """, "id, card_id, page_id, user_id, count, comment, inserted_at, updated_at"},
    {"card_urls",
     """
     id INTEGER PRIMARY KEY AUTOINCREMENT,
     url TEXT NOT NULL,
     title TEXT,
     card_id INTEGER REFERENCES cards(id) ON DELETE CASCADE,
     page_id INTEGER REFERENCES pages(id) ON DELETE CASCADE,
     inserted_at TEXT NOT NULL
     """, "id, url, title, card_id, page_id, inserted_at"},
    {"card_field_values",
     """
     id INTEGER PRIMARY KEY AUTOINCREMENT,
     card_id INTEGER REFERENCES cards(id) ON DELETE CASCADE,
     page_id INTEGER REFERENCES pages(id) ON DELETE CASCADE,
     field_id INTEGER NOT NULL REFERENCES field_definitions(id) ON DELETE CASCADE,
     number NUMERIC,
     text TEXT,
     date TEXT,
     option TEXT,
     inserted_at TEXT NOT NULL,
     updated_at TEXT NOT NULL
     """, "id, card_id, page_id, field_id, number, text, date, option, inserted_at, updated_at"}
  ]

  def up do
    for {table, columns, cols} <- @tables do
      old_cols = cols |> String.replace("page_id", "NULL") |> then(&"#{&1}")

      execute """
      CREATE TABLE #{table}_new (
      #{String.trim_trailing(columns)},
      CHECK ((card_id IS NOT NULL) + (page_id IS NOT NULL) = 1)
      )
      """

      execute "INSERT INTO #{table}_new (#{cols}) SELECT #{old_cols} FROM #{table}"
      execute "DROP TABLE #{table}"
      execute "ALTER TABLE #{table}_new RENAME TO #{table}"
      execute "CREATE INDEX #{table}_page_id_index ON #{table} (page_id)"
    end

    execute "CREATE INDEX comments_card_id_index ON comments (card_id)"

    execute "CREATE INDEX status_updates_card_id_inserted_at_index ON status_updates (card_id, inserted_at)"

    execute "CREATE INDEX status_updates_page_id_inserted_at_index ON status_updates (page_id, inserted_at)"

    execute "CREATE INDEX checklist_items_card_id_position_index ON checklist_items (card_id, position)"

    execute "CREATE INDEX checklist_items_page_id_position_index ON checklist_items (page_id, position)"

    execute "CREATE UNIQUE INDEX votes_card_id_user_id_index ON votes (card_id, user_id)"
    execute "CREATE UNIQUE INDEX votes_page_id_user_id_index ON votes (page_id, user_id)"
    execute "CREATE INDEX card_urls_card_id_index ON card_urls (card_id)"

    execute "CREATE UNIQUE INDEX card_field_values_card_id_field_id_index ON card_field_values (card_id, field_id)"

    execute "CREATE UNIQUE INDEX card_field_values_page_id_field_id_index ON card_field_values (page_id, field_id)"

    execute "CREATE INDEX card_field_values_field_id_index ON card_field_values (field_id)"
  end

  def down do
    for {table, _columns, _cols} <- @tables do
      execute "DELETE FROM #{table} WHERE card_id IS NULL"
    end

    # The tables keep their nullable card_id and their page_id column; what
    # comes back is the card-only reading of them. Rebuilding six tables a
    # second time to re-impose a NOT NULL nobody can violate any more buys
    # nothing, and the rows that could have violated it are gone above.
    execute "DROP INDEX IF EXISTS votes_page_id_user_id_index"
    execute "DROP INDEX IF EXISTS card_field_values_page_id_field_id_index"
  end
end
