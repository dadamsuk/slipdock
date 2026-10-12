defmodule Slipdock.Repo.Migrations.AddAliasesToPages do
  use Ecto.Migration

  # The other names a page answers to, from its front matter's `aliases`:
  # `[[Alias]]` resolves to it as `[[Title]]` does (W-103 R3.5).
  def change do
    alter table(:pages) do
      add :aliases, {:array, :string}, default: [], null: false
    end

    create index(:pages, [:aliases], using: "GIN")
  end
end
