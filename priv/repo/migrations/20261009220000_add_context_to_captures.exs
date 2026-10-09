defmodule Slipdock.Repo.Migrations.AddContextToCaptures do
  use Ecto.Migration

  def change do
    # What the board already knew that bears on the meeting (pipeline step 5),
    # kept so a restart does not search again and the review can show it.
    alter table(:captures) do
      add :context, :map
    end
  end
end
