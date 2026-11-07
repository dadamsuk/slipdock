defmodule Slipdock.Repo.Migrations.AddCardEvidenceNoCode do
  use Ecto.Migration

  # #1938: a card on a board that ships by pull request can be finished with
  # no code at all (a sweep, a handbook reconcile, a read-and-file card).
  # Its evidence says so, with the reason, in place of a pull request.
  def change do
    alter table(:cards) do
      add :evidence_no_code, :text
    end
  end
end
