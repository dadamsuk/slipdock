defmodule Slipdock.Repo.Migrations.AddEncryptedToPages do
  use Ecto.Migration

  # Whether a page holds Meld Encrypt ciphertext (#639), so the tree can show
  # a lock without reading bodies. Set on every save from then on; pages
  # written before are marked here by the same test the app uses.
  def up do
    alter table(:pages) do
      add :encrypted, :boolean, null: false, default: false
    end

    flush()

    execute("""
    UPDATE pages SET encrypted = true
    WHERE body ~ '🔐(β |α | )(💡[^💡\\n]*💡)?[A-Za-z0-9+/=]* 🔐'
    """)
  end

  def down do
    alter table(:pages) do
      remove :encrypted
    end
  end
end
