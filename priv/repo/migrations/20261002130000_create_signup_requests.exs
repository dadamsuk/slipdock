defmodule Slipdock.Repo.Migrations.CreateSignupRequests do
  use Ecto.Migration

  # Somebody asking for an account under the `approval` registration mode.
  # Deliberately not a `users` row: an unapproved request must not be able to
  # sign in, and `signup_allowed?/1` says yes to anybody who already has an
  # account.
  def change do
    create table(:signup_requests) do
      add :email, :string, null: false
      # What they said about themselves. An approval queue of bare addresses
      # gives an admin nothing to decide on.
      add :note, :string
      # pending | approved | rejected
      add :status, :string, null: false, default: "pending"
      add :decided_at, :utc_datetime
      add :decided_by_id, references(:users, on_delete: :nilify_all)
      # Where it came from, so a flood is visible as one.
      add :requested_ip, :string

      timestamps(type: :utc_datetime)
    end

    # One row per address: asking again refreshes the request rather than
    # piling up duplicates for an admin to wade through.
    create unique_index(:signup_requests, [:email])
    create index(:signup_requests, [:status])
  end
end
