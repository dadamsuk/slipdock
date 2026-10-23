defmodule Slipdock.Repo.Migrations.AddQuestionsToCardWaits do
  use Ecto.Migration

  # Follow-up questions as a series (#1220): a wait can ask several
  # questions, numbered, and is answered one box per question.
  def change do
    alter table(:card_waits) do
      add :questions, {:array, :text}, null: false, default: []
      add :answers, {:array, :text}, null: false, default: []
    end
  end
end
