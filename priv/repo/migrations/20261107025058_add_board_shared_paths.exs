defmodule Slipdock.Repo.Migrations.AddBoardSharedPaths do
  @moduledoc """
  Shared paths (#1971): a board's globs that never count toward a lane, so
  cards can declare the files nearly every card edits (the manual, the API
  guide) without holding each other. Empty by default: nothing changes.
  """
  use Ecto.Migration

  def change do
    alter table(:boards) do
      add :shared_paths, {:array, :string}, default: [], null: false
    end
  end
end
