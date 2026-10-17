defmodule Slipdock.Repo.Migrations.AddAttachmentSha256 do
  use Ecto.Migration

  # The SHA-256 of a file's stored bytes (#1015), so a caller can check an
  # upload is intact without downloading it again. Rows from before this are
  # filled in on boot by `Slipdock.Boards.backfill_attachment_hashes/0`.
  def change do
    alter table(:attachments) do
      add :sha256, :string
    end
  end
end
