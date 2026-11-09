defmodule Slipdock.Repo.Migrations.MachineRunnerPauseAndUpdate do
  @moduledoc """
  The Machines page's two actions that aren't config fields (#2572, epic
  #2569):

  - `runners.paused_at`: a machine runner its owner paused. The server hands
    it no job while it is set, and its config says so to the daemon.
  - `machines.update_requested_at`: *update now*, asked from the page. The
    daemon reads it in its config and checks for a newer release at once
    instead of waiting for its next check.
  """
  use Ecto.Migration

  def change do
    alter table(:runners) do
      add :paused_at, :utc_datetime
    end

    alter table(:machines) do
      add :update_requested_at, :utc_datetime
    end
  end
end
