defmodule Slipdock.Repo.Migrations.UsersGetAdminAndStanding do
  use Ecto.Migration

  def up do
    alter table(:users) do
      # The only role there is. Nobody with 250 users is going to run this, so
      # there is no permission matrix — an admin can change how the server
      # behaves, and everyone else cannot.
      add :admin, :boolean, null: false, default: false
      # Set on every browser sign-in, so the admin users list can tell a
      # dormant account from a live one.
      add :last_signed_in_at, :utc_datetime
      # Disabling is the reversible alternative to deleting, which would orphan
      # cards, comments, grants and authored wiki revisions.
      add :disabled_at, :utc_datetime
      # Null means "use the instance's free_card_limit". Set per person for
      # whoever pays, or for a colleague who should not be capped.
      add :card_limit_override, :integer
    end

    create index(:users, [:admin])

    # Whoever `Slipdock.Settings.seed/0` named as the admin becomes one. On an
    # instance that was claimed long before any of this existed, that is the
    # oldest account.
    execute """
    UPDATE users SET admin = true
     WHERE email IN (SELECT admin_email FROM settings
                      WHERE id = 1 AND admin_email IS NOT NULL)
    """

    # Belt and braces: a set-up server with users and no admin at all would be
    # a server nobody can administer, so the oldest account gets it.
    execute """
    UPDATE users SET admin = true
     WHERE id = (SELECT MIN(id) FROM users)
       AND NOT EXISTS (SELECT 1 FROM users WHERE admin = true)
       AND EXISTS (SELECT 1 FROM settings WHERE setup_completed_at IS NOT NULL)
    """
  end

  def down do
    drop index(:users, [:admin])

    alter table(:users) do
      remove :admin
      remove :last_signed_in_at
      remove :disabled_at
      remove :card_limit_override
    end
  end
end
