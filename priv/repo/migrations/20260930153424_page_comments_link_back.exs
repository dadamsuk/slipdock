defmodule Slipdock.Repo.Migrations.PageCommentsLinkBack do
  use Ecto.Migration

  @moduledoc """
  A comment on a *page* that writes `[[Retry policy]]` belongs in that
  page's backlinks, exactly as a comment on a card does.

  `source_card_id` already carried "the card this remark was written on",
  alongside the comment or status source, so a backlink could name it
  without a join. `source_page_id` is its twin, and is what a comment on a
  page fills in now that pages take comments (see `Slipdock.Boards.Owned`).

  It is *not* a source in the "exactly one of" sense — `page_id` means "the
  page whose body contains this link", which a comment's row does not have.
  """

  def up do
    alter table(:page_links) do
      add :source_page_id, references(:pages, on_delete: :delete_all)
    end

    create index(:page_links, [:source_page_id])
  end

  def down do
    drop index(:page_links, [:source_page_id])

    alter table(:page_links) do
      remove :source_page_id
    end
  end
end
