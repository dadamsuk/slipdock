defmodule Slipdock.Repo.Migrations.AddNoteTagsToPages do
  use Ecto.Migration

  # The tags a note gives itself — its front matter's `tags` and the inline
  # `#tags` in its body — on boards that belong to a vault. Kept apart from
  # the board's card tags (`page_tags`), so notes never fill the card tag
  # picker (see `Slipdock.Wiki.NoteTags`, W-103 R3.4).
  def change do
    alter table(:pages) do
      add :note_tags, {:array, :string}, default: [], null: false
    end

    create index(:pages, [:note_tags], using: "GIN")
  end
end
