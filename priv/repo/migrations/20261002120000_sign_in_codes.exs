defmodule Slipdock.Repo.Migrations.SignInCodes do
  use Ecto.Migration

  def change do
    alter table(:users_tokens) do
      # A short code beside the long link, for the times the link cannot be
      # clicked: read out of a log, typed from a phone, dictated down a phone.
      #
      # Stored as it is. The long token is hashed so that reading the database
      # is not the same as taking over an account, but six digits cannot be
      # protected that way — an attacker with the table could try all million
      # hashes in a moment. What protects a code is the fifteen-minute window,
      # the attempt counter below, and the rate limiter.
      add :code, :string
      # Six digits is a small space, so a code gets a handful of guesses and is
      # then dead. Without this the window is long enough to walk the space.
      add :code_attempts, :integer, null: false, default: 0
    end

    create index(:users_tokens, [:code])
  end
end
