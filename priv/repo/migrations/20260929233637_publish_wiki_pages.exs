defmodule Slipdock.Repo.Migrations.PublishWikiPages do
  use Ecto.Migration

  @moduledoc """
  Phase 6 of `docs/wiki.md`: a page can be published read-only at `/p/:token`,
  the way a saved view can.

  `frozen` is why this needs a column rather than just a token. A published
  page's live queries are answered **as of the moment it was published** and
  the answers stored here: there is nobody on the other side of an anonymous
  request to have permissions, so running a query then would be a way to read
  private cards from the open web. Card chips degrade to plain text for the
  same reason.
  """

  def change do
    alter table(:pages) do
      # The answers this page's `kanban` blocks and `{{…}}` expressions gave
      # when it was published, keyed by the block's own text.
      add :frozen, :map
      add :published_at, :utc_datetime
    end
  end
end
