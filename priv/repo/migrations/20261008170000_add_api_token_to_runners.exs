defmodule Slipdock.Repo.Migrations.AddApiTokenToRunners do
  use Ecto.Migration

  # A Claude session takes jobs with the API token it already has (over MCP
  # or the CLI) rather than a runner token of its own. It still shows up as
  # a runner — one per token, board tree and pool — so the runner list says
  # who is working, and goes when the token does.
  def change do
    alter table(:runners) do
      add :api_token_id, references(:users_tokens, on_delete: :delete_all)
    end

    create unique_index(:runners, [:board_id, :pool, :api_token_id],
             where: "api_token_id IS NOT NULL",
             name: :runners_one_per_session
           )
  end
end
