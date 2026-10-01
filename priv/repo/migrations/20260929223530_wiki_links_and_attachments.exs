defmodule Slipdock.Repo.Migrations.WikiLinksAndAttachments do
  use Ecto.Migration

  @moduledoc """
  Phase 2 of `docs/wiki.md`: what a page points at.

  `page_links` is rebuilt from the body on every save, so it is a derived
  index and never a source of truth — except for `pinned`, which is a
  person's judgement ("this doc is *the* spec for that card") and so survives
  a rebuild.

  An unresolved row is the interesting one: a `[[wanted page]]` somebody
  wrote before anyone wrote the page. Those are the wiki's own backlog.

  Attachments grow a `page_id` so an image pasted into a page uses the flow
  cards already have. SQLite cannot drop a NOT NULL, so the table is rebuilt
  — the standard twelve-step dance, minus the steps this table does not need.
  """

  def up do
    create table(:page_links) do
      add :page_id, references(:pages, on_delete: :delete_all), null: false
      # "page" | "card" | "board" | "view" | "external"
      add :kind, :string, null: false
      add :target_page_id, references(:pages, on_delete: :nilify_all)
      add :target_card_id, references(:cards, on_delete: :nilify_all)
      add :target_board_id, references(:boards, on_delete: :nilify_all)
      add :target_view_id, references(:saved_views, on_delete: :nilify_all)
      # What was written — "Retry policy", "#412" — kept so an unresolved
      # link can still say what it was looking for.
      add :raw, :string, null: false
      add :label, :string
      add :resolved, :boolean, null: false, default: false
      # "this doc is the spec for that card": set by a person, kept across
      # rebuilds of the rest of the row.
      add :pinned, :boolean, null: false, default: false
      # Occurrences, so a passing mention ranks below a page about the thing.
      add :count, :integer, null: false, default: 1
      timestamps(type: :utc_datetime)
    end

    create index(:page_links, [:page_id])
    create index(:page_links, [:target_page_id])
    create index(:page_links, [:target_card_id])
    create index(:page_links, [:resolved])

    create table(:page_tags, primary_key: false) do
      add :page_id, references(:pages, on_delete: :delete_all), null: false
      add :tag_id, references(:tags, on_delete: :delete_all), null: false
    end

    create unique_index(:page_tags, [:page_id, :tag_id])

    # Rebuild attachments so card_id may be null and page_id exists, with
    # exactly one of the two set.
    execute """
    CREATE TABLE attachments_new (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      card_id INTEGER REFERENCES cards(id) ON DELETE CASCADE,
      page_id INTEGER REFERENCES pages(id) ON DELETE CASCADE,
      filename TEXT NOT NULL,
      content_type TEXT NOT NULL,
      size INTEGER NOT NULL,
      key TEXT NOT NULL,
      inserted_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      CHECK ((card_id IS NOT NULL) + (page_id IS NOT NULL) = 1)
    )
    """

    execute """
    INSERT INTO attachments_new (id, card_id, page_id, filename, content_type, size, key, inserted_at, updated_at)
    SELECT id, card_id, NULL, filename, content_type, size, key, inserted_at, updated_at FROM attachments
    """

    execute "DROP TABLE attachments"
    execute "ALTER TABLE attachments_new RENAME TO attachments"

    create index(:attachments, [:card_id])
    create index(:attachments, [:page_id])
    create unique_index(:attachments, [:key])
  end

  def down do
    drop table(:page_links)
    drop table(:page_tags)

    execute "DELETE FROM attachments WHERE card_id IS NULL"

    execute """
    CREATE TABLE attachments_old (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      card_id INTEGER NOT NULL REFERENCES cards(id) ON DELETE CASCADE,
      filename TEXT NOT NULL,
      content_type TEXT NOT NULL,
      size INTEGER NOT NULL,
      key TEXT NOT NULL,
      inserted_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
    """

    execute """
    INSERT INTO attachments_old (id, card_id, filename, content_type, size, key, inserted_at, updated_at)
    SELECT id, card_id, filename, content_type, size, key, inserted_at, updated_at FROM attachments
    """

    execute "DROP TABLE attachments"
    execute "ALTER TABLE attachments_old RENAME TO attachments"

    create index(:attachments, [:card_id])
    create unique_index(:attachments, [:key])
  end
end
