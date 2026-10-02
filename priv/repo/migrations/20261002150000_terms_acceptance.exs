defmodule Slipdock.Repo.Migrations.TermsAcceptance do
  use Ecto.Migration

  def change do
    alter table(:settings) do
      # Where the terms and the privacy notice live, and which version is
      # current. All three empty on a self-hosted install, where there is
      # nobody to have terms *with* — and then none of this appears.
      add :terms_url, :string
      add :privacy_url, :string
      # Bumping this asks everybody again. It is a free-text label rather than
      # a number so it can be a date, which is how people actually version
      # terms.
      add :terms_version, :string
    end

    alter table(:users) do
      add :terms_accepted_at, :utc_datetime
      # Which version they agreed to. Recording only the date would make it
      # impossible to answer "did they accept *these* terms".
      add :terms_version, :string
    end
  end
end
