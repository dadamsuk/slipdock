defmodule SlipdockWeb.API.Uploads do
  @moduledoc """
  A file sent over the API, for a card or a page to keep: the multipart field
  `file`, the same thing the card panel's drop zone and a pasted image take.

  What comes back carries a ready-made Markdown snippet, so an agent that
  uploads a screenshot can put it in a description, a comment or a page body
  without building the URL itself.
  """

  alias Slipdock.Boards
  alias Slipdock.Boards.Attachment

  @doc """
  The upload in `params` as `{meta, path}` for `Boards.add_attachment/3` or
  `Wiki.add_attachment/3`, or the error the fallback controller answers with.
  """
  def take(%{"file" => %Plug.Upload{path: path, filename: name} = upload} = params) do
    filename = present(params["filename"]) || name

    {:ok,
     %{
       filename: filename,
       content_type: content_type(upload.content_type, filename),
       size: File.stat!(path).size
     }, path}
  end

  def take(%{"file" => _}),
    do: {:error, :unprocessable_entity, "file must be sent as a multipart file upload"}

  def take(_params),
    do:
      {:error, :unprocessable_entity,
       "send the file as the multipart form field `file` (curl -F file=@shot.png)"}

  @doc "The attachment as the API shows it, with the Markdown that embeds or links it."
  def json(%Attachment{} = a) do
    Map.put(SlipdockWeb.API.JSON.attachment(a), :markdown, markdown(a))
  end

  @doc "An image shows inline; any other file is a link to download it."
  def markdown(%Attachment{} = a) do
    link = "[#{a.filename}](#{Boards.attachment_url(a)})"
    if Attachment.image?(a), do: "!" <> link, else: link
  end

  # What the client said, unless it said nothing useful — curl calls anything
  # it does not recognise application/octet-stream — when the name decides.
  defp content_type(type, filename) when type in [nil, "", "application/octet-stream"],
    do: MIME.from_path(filename)

  defp content_type(type, _filename), do: type

  defp present(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  defp present(_), do: nil
end
