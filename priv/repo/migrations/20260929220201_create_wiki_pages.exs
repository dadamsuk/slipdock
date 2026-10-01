defmodule Slipdock.Repo.Migrations.CreateWikiPages do
  use Ecto.Migration

  @moduledoc """
  Wiki pages: Markdown documents that hang off a board, in a tree of their
  own (see `docs/wiki.md`).

  A board is the space, so a page needs no permission model of its own — it
  inherits the board's, raised by a grant on the page itself, which is what
  the new `access_grants.page_id` is for.

  `code` is the page's stable short handle ("W-31"), taken from the
  per-board counter `boards.page_seq` in the same transaction as the insert.
  It survives renames and re-slugs, which `board-code/slug` does not.

  Every save writes a `page_revisions` row: a full snapshot rather than a
  diff, because bodies are kilobytes and diffs are cheap to compute but
  expensive to get wrong. `via` and `agent` record who wrote it — a person
  in the web app, a token on the CLI, the assistant — so provenance lives in
  history rather than in a separate audit log.
  """

  def change do
    create table(:pages) do
      add :board_id, references(:boards, on_delete: :delete_all), null: false
      # The tree within the board, independent of cards. A purged parent
      # leaves its children behind as roots rather than taking them with it.
      add :parent_id, references(:pages, on_delete: :nilify_all)
      add :title, :string, null: false
      add :slug, :string, null: false
      add :code, :string, null: false
      add :number, :integer, null: false
      add :body, :text, null: false, default: ""
      add :summary, :string
      add :position, :integer, null: false, default: 0
      # "draft" pages are visible to writers only; "published" to any reader.
      add :status, :string, null: false, default: "published"
      # A page used as a starting point for others, not read as content.
      add :template, :boolean, null: false, default: false
      # Set when published read-only at /p/:token, as saved views are.
      add :public_token, :string
      # sha256 of the body: the concurrency token a save is based on.
      add :content_hash, :string, null: false
      add :created_by_id, references(:users, on_delete: :nilify_all)
      add :updated_by_id, references(:users, on_delete: :nilify_all)
      # Archived like cards, never deleted (except a purge by the owner).
      add :archived_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    create index(:pages, [:board_id])
    create index(:pages, [:parent_id])
    create unique_index(:pages, [:board_id, :slug])
    create unique_index(:pages, [:code])
    create unique_index(:pages, [:public_token])

    create table(:page_revisions) do
      add :page_id, references(:pages, on_delete: :delete_all), null: false
      add :title, :string, null: false
      add :body, :text, null: false, default: ""
      # The edit's own message — why, not what.
      add :summary, :string
      add :author_id, references(:users, on_delete: :nilify_all)
      add :via, :string
      add :agent, :string
      add :byte_size, :integer, null: false, default: 0
      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:page_revisions, [:page_id])

    alter table(:boards) do
      # The counter the next page's number (and so its code) comes from.
      add :page_seq, :integer, null: false, default: 0
    end

    alter table(:access_grants) do
      add :page_id, references(:pages, on_delete: :delete_all)
    end

    create index(:access_grants, [:page_id])

    alter table(:activities) do
      add :page_id, references(:pages, on_delete: :nilify_all)
    end
  end
end
