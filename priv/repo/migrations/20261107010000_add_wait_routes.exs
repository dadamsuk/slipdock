defmodule Slipdock.Repo.Migrations.AddWaitRoutes do
  @moduledoc """
  Waits go to a role (#1949). A board's `wait_routes` maps a question's kind
  (`product`, `ux`, `security`, `release`, `other`) to the ids of the board's
  users it goes to, the first being who the wait is on; empty by default. A
  wait's `question` is the kind it was opened with. `kind` stays what it
  was: the opener's actor kind.
  """
  use Ecto.Migration

  def change do
    alter table(:boards) do
      add :wait_routes, :map, null: false, default: %{}
    end

    alter table(:card_waits) do
      add :question, :string
    end
  end
end
