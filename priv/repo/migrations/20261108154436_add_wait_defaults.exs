defmodule Slipdock.Repo.Migrations.AddWaitDefaults do
  @moduledoc """
  A wait that clears itself (#2096): an approval wait (a question of kind
  `other`, with choices) can name the choice it proposes,
  `card_waits.default_choice` (counted from 1), and a board's
  `wait_default_after` (minutes; null, the default, is off) is how long such
  a wait goes unanswered before its proposal stands.
  """
  use Ecto.Migration

  def change do
    alter table(:card_waits) do
      add :default_choice, :integer
    end

    alter table(:boards) do
      add :wait_default_after, :integer
    end
  end
end
