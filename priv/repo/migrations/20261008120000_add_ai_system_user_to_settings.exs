defmodule Slipdock.Repo.Migrations.AddAiSystemUserToSettings do
  use Ecto.Migration

  # Whose AI settings unattended work — the search indexer, every search
  # query, scheduled automations — runs on, chosen by an admin in the browser
  # rather than through SLIPDOCK_AI_SYSTEM_USER. Blank leaves the older rules
  # (the environment, then the single-admin fallback) to decide. Deleting that
  # person clears it.
  def change do
    alter table(:settings) do
      add :ai_system_user_id, references(:users, on_delete: :nilify_all)
    end
  end
end
