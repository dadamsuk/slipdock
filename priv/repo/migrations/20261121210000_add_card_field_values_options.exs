defmodule Slipdock.Repo.Migrations.AddCardFieldValuesOptions do
  use Ecto.Migration

  # The options a choice field that allows several holds (#3611), in the
  # field's option order; a single choice keeps using `option`. A list of
  # keys rather than one, so a later kind holding several of something
  # (people) can use it too.
  def change do
    alter table(:card_field_values) do
      add :options, {:array, :string}
    end
  end
end
