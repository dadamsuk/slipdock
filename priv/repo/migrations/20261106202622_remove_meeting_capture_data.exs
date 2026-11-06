defmodule Slipdock.Repo.Migrations.RemoveMeetingCaptureData do
  @moduledoc """
  Meeting and chat capture are gone (W-2330, #1819), and nothing of theirs is
  kept: the search embeddings of what was said in a meeting (`provenance`)
  are deleted, and so is the capture audio under `<uploads_dir>/captures/`.
  Forward only: neither comes back.
  """
  use Ecto.Migration

  def up do
    execute delete_provenance()
    purge_audio(Slipdock.Boards.uploads_dir())
  end

  def down do
    raise Ecto.MigrationError,
      message: "meeting capture's embeddings and audio were deleted and can't be put back"
  end

  @doc false
  # The search rows of what was said in a meeting. A test runs it again.
  def delete_provenance, do: "DELETE FROM search_embeddings WHERE kind = 'provenance'"

  @doc false
  # The capture recordings, all of them under one folder. Gone already, or
  # never there, is the same answer: running it twice changes nothing.
  def purge_audio(uploads_dir) do
    dir = Path.join(uploads_dir, "captures")
    {:ok, _} = File.rm_rf(dir)
    :ok
  end
end
