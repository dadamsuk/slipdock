defmodule Slipdock.Repo.Migrations.AddAiModelsToSettings do
  use Ecto.Migration

  # The models the server's AI asks (#1670), set by an admin. Nil leaves each
  # to the environment and then config.exs.
  def change do
    alter table(:settings) do
      add :ai_model, :string
      add :ai_quick_model, :string
      add :ai_organise_model, :string
      add :ai_fallback_models, :text
    end
  end
end
