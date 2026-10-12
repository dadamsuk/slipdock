defmodule Slipdock.Repo.Migrations.AddFileNameToPages do
  use Ecto.Migration

  # The name of the file a page came from (without `.md`), kept when it is
  # not simply the page's title made safe for a file — a note whose front
  # matter gives it another title, or whose name a title can't hold as it
  # is (a trailing space, more than 80 characters). A synced vault writes
  # the page back under that name, so importing a vault renames nothing
  # (W-103 R9). Null for every page whose file is named after its title.
  def change do
    alter table(:pages) do
      add :file_name, :string, size: 255
    end
  end
end
