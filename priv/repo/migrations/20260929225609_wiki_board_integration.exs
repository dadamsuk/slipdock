defmodule Slipdock.Repo.Migrations.WikiBoardIntegration do
  use Ecto.Migration

  @moduledoc """
  Phase 3 of `docs/wiki.md`: the wiki and the board stop having to remember
  each other exists.

  Three small changes:

    * A link can now come **from** a comment or a status update as well as
      from a page. A comment pointing at a runbook belongs in that runbook's
      backlinks — the writing people do on cards is writing too. `page_links`
      grows `source_comment_id` and `source_status_id`, and `page_id` (the
      source page) becomes optional, with exactly one source per row.
    * `favourites` grows `page_id`, so a page can be one of the handful of
      things a person goes back to.
    * `board_templates` grows `pages`, so a new board can arrive with its
      documentation skeleton rather than an empty wiki.

  SQLite cannot drop a NOT NULL, so `page_links` is rebuilt. It is a derived
  index — `Slipdock.Wiki.Links.reconcile/1` rewrites it from the prose on every
  save — so the copy is for the pins alone, which are the one thing in it
  that nobody wrote in a body.
  """

  def up do
    execute """
    CREATE TABLE page_links_new (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      page_id INTEGER REFERENCES pages(id) ON DELETE CASCADE,
      source_comment_id INTEGER REFERENCES comments(id) ON DELETE CASCADE,
      source_status_id INTEGER REFERENCES status_updates(id) ON DELETE CASCADE,
      source_card_id INTEGER REFERENCES cards(id) ON DELETE CASCADE,
      kind TEXT NOT NULL,
      target_page_id INTEGER REFERENCES pages(id) ON DELETE SET NULL,
      target_card_id INTEGER REFERENCES cards(id) ON DELETE SET NULL,
      target_board_id INTEGER REFERENCES boards(id) ON DELETE SET NULL,
      target_view_id INTEGER REFERENCES saved_views(id) ON DELETE SET NULL,
      raw TEXT NOT NULL,
      label TEXT,
      resolved BOOLEAN NOT NULL DEFAULT 0,
      pinned BOOLEAN NOT NULL DEFAULT 0,
      count INTEGER NOT NULL DEFAULT 1,
      inserted_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      CHECK ((page_id IS NOT NULL) + (source_comment_id IS NOT NULL) + (source_status_id IS NOT NULL) = 1)
    )
    """

    execute """
    INSERT INTO page_links_new (id, page_id, kind, target_page_id, target_card_id,
                                target_board_id, target_view_id, raw, label, resolved,
                                pinned, count, inserted_at, updated_at)
    SELECT id, page_id, kind, target_page_id, target_card_id,
           target_board_id, target_view_id, raw, label, resolved,
           pinned, count, inserted_at, updated_at FROM page_links
    """

    execute "DROP TABLE page_links"
    execute "ALTER TABLE page_links_new RENAME TO page_links"

    create index(:page_links, [:page_id])
    create index(:page_links, [:source_comment_id])
    create index(:page_links, [:source_status_id])
    create index(:page_links, [:source_card_id])
    create index(:page_links, [:target_page_id])
    create index(:page_links, [:target_card_id])
    create index(:page_links, [:resolved])

    alter table(:favourites) do
      add :page_id, references(:pages, on_delete: :delete_all)
    end

    create unique_index(:favourites, [:user_id, :page_id])

    alter table(:board_templates) do
      # A list of `%{"title" => …, "body" => …, "summary" => …}` maps: the
      # pages a board made from this template starts with.
      add :pages, :map, null: false, default: "[]"
    end
  end

  def down do
    alter table(:board_templates) do
      remove :pages
    end

    drop index(:favourites, [:user_id, :page_id])

    alter table(:favourites) do
      remove :page_id
    end

    execute "DELETE FROM page_links WHERE page_id IS NULL"

    execute """
    CREATE TABLE page_links_old (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      page_id INTEGER NOT NULL REFERENCES pages(id) ON DELETE CASCADE,
      kind TEXT NOT NULL,
      target_page_id INTEGER REFERENCES pages(id) ON DELETE SET NULL,
      target_card_id INTEGER REFERENCES cards(id) ON DELETE SET NULL,
      target_board_id INTEGER REFERENCES boards(id) ON DELETE SET NULL,
      target_view_id INTEGER REFERENCES saved_views(id) ON DELETE SET NULL,
      raw TEXT NOT NULL,
      label TEXT,
      resolved BOOLEAN NOT NULL DEFAULT 0,
      pinned BOOLEAN NOT NULL DEFAULT 0,
      count INTEGER NOT NULL DEFAULT 1,
      inserted_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
    """

    execute """
    INSERT INTO page_links_old SELECT id, page_id, kind, target_page_id, target_card_id,
           target_board_id, target_view_id, raw, label, resolved, pinned, count,
           inserted_at, updated_at FROM page_links
    """

    execute "DROP TABLE page_links"
    execute "ALTER TABLE page_links_old RENAME TO page_links"

    create index(:page_links, [:page_id])
    create index(:page_links, [:target_page_id])
    create index(:page_links, [:target_card_id])
    create index(:page_links, [:resolved])
  end
end
