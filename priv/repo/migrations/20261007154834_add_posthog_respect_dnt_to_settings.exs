defmodule Slipdock.Repo.Migrations.AddPosthogRespectDntToSettings do
  use Ecto.Migration

  # Whether a visitor who asks not to be tracked (Do-Not-Track / Global Privacy
  # Control) is left out of analytics. Until now this was hardcoded on in the
  # client; making it a setting hands the choice to the admin. The default is
  # the current behaviour — DNT is respected — so nothing changes on deploy.
  def change do
    alter table(:settings) do
      add :posthog_respect_dnt, :boolean, default: true, null: false
    end
  end
end
