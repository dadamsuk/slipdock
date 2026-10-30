defmodule Slipdock.OCR.Text do
  @moduledoc """
  The words in one uploaded file, and where reading them has got to. The row
  is the queue too (see `Slipdock.OCR`): `queued`, `running`, then `done` with
  the text or `failed` with the reason. A file with no words in it is `done`
  with no text, which is an answer rather than a failure.

  Exactly one of `attachment_id` and `wiki_file_id` is set, and the row goes
  when the file does.
  """
  use Ecto.Schema

  schema "document_texts" do
    field :status, :string, default: "queued"
    field :text, :string
    field :error, :string
    field :pages, :integer
    # How many of `pages` had to be read from a picture of the page.
    field :ocr_pages, :integer
    # Stopped at a limit, so there is more in the file than here.
    field :truncated, :boolean, default: false
    field :attempts, :integer, default: 0
    field :started_at, :utc_datetime
    belongs_to :attachment, Slipdock.Boards.Attachment
    belongs_to :wiki_file, Slipdock.Wiki.WikiFile
    timestamps(type: :utc_datetime)
  end

  @doc "Whether the file has words worth showing or searching."
  def readable?(%__MODULE__{status: "done", text: text}) when is_binary(text),
    do: String.trim(text) != ""

  def readable?(_), do: false
end
