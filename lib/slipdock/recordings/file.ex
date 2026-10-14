defmodule Slipdock.Recordings.File do
  @moduledoc """
  A recording path a vault has found on Drive: the path (from My Drive's
  root, as front matter names it) and the file it turned out to be. See
  `Slipdock.Recordings`.
  """
  use Ecto.Schema

  schema "recording_files" do
    field :path, :string
    field :drive_id, :string
    field :mime_type, :string
    field :size, :integer

    belongs_to :vault, Slipdock.Vaults.Vault

    timestamps(type: :utc_datetime)
  end
end
