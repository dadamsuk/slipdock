defmodule Slipdock.Repo.Migrations.SupportSessionAdminNullable do
  use Ecto.Migration

  # admin_id was on_delete: :nilify_all and NOT NULL at once, so deleting an
  # admin who had ever opened a support session failed. The record stays — the
  # person it was about is owed it — with the admin nulled.
  def up do
    execute "ALTER TABLE support_sessions ALTER COLUMN admin_id DROP NOT NULL"
  end

  def down do
    execute "DELETE FROM support_sessions WHERE admin_id IS NULL"
    execute "ALTER TABLE support_sessions ALTER COLUMN admin_id SET NOT NULL"
  end
end
