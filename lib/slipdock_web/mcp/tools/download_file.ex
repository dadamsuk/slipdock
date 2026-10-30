defmodule SlipdockWeb.MCP.Tools.DownloadFile do
  @moduledoc """
  A file attached to a card or a wiki page, read over MCP (#919). The web
  app's `/attachments/...` link needs a browser session, so a connector's
  agent gets the bytes here instead, after the same check `get_card` and
  `read_page` make: what the token may read, and no more.

  How it comes back depends on what it is. Text is text, cut like a page
  body; an image is an MCP image block the model can look at; anything else
  is an embedded resource, base64. Either way the attachment's details come
  first, as JSON.

  `link: true` (#1147) sends no bytes: it answers with a single-use URL,
  good for ten minutes, for a shell to fetch the file from with curl, of any
  size and without a token.

  `text: true` (#1527) sends the words read from a PDF or an image instead of
  the file, which is usually what an agent wanted from a scan.
  """
  @behaviour SlipdockWeb.MCP.Tool

  alias Slipdock.{Boards, Repo, TransferLinks}
  alias Slipdock.Boards.Attachment
  alias SlipdockWeb.API.{Authorize, Uploads}
  alias SlipdockWeb.MCP.Args
  alias SlipdockWeb.MCP.Tools.ReadPage

  # As `read_page` cuts a body: Claude's clients take about 150k characters
  # per tool result (W-21).
  @max_text 100_000
  # A binary file, before base64. Bigger ones are for the web app.
  @max_bytes 5_000_000

  @doc "The largest image or binary file `download_file` sends, in bytes."
  def max_bytes, do: @max_bytes

  @doc "How much of a text file `download_file` sends, in characters."
  def max_text, do: @max_text

  @impl true
  def name, do: "download_file"

  @impl true
  def title, do: "Download a file"

  @impl true
  def description,
    do:
      "A file attached to a card or wiki page, by its attachment id (get_card and " <>
        "read_page list them). Text comes back as text, an image as an image, anything " <>
        "else (up to 5 MB) as base64. With a shell, link: true instead returns a single-use " <>
        "download_url, good for 10 minutes and needing no token: curl -fsSo <name> <url>."

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        attachment: %{
          type: "integer",
          description: "The attachment's id, from get_card or read_page."
        },
        text: %{
          type: "boolean",
          description: "Send the words read from a PDF or image (OCR) instead of the file."
        },
        link: %{
          type: "boolean",
          description:
            "Send no bytes: get a single-use download_url, good for 10 minutes, to fetch the " <>
              "file from a shell (curl -fsSo <name> <url>)."
        }
      },
      required: ["attachment"],
      additionalProperties: false
    }
  end

  @impl true
  def read_only?, do: true

  @impl true
  def call(%{"link" => true} = args, context), do: link(args, context)
  def call(%{"text" => true} = args, context), do: text(args, context)

  def call(args, context) do
    auth = Args.auth(context)

    with {:ok, id} <- attachment_id(args),
         {:ok, attachment} <- fetch(id),
         :ok <- readable(attachment, auth),
         {:ok, bytes} <- read(attachment) do
      info =
        attachment
        |> Uploads.json()
        |> Map.merge(owner(attachment))
        |> Map.put(:url, context.base_url <> Boards.attachment_url(attachment))

      answer(attachment, bytes, info)
    end
  end

  defp text(args, context) do
    with {:ok, id} <- attachment_id(args),
         {:ok, attachment} <- fetch(id),
         :ok <- readable(attachment, Args.auth(context)) do
      read = Slipdock.OCR.text_of(attachment)
      words = (read && read.text) || ""

      {:ok,
       %{
         id: attachment.id,
         filename: attachment.filename,
         status: read && read.status,
         error: read && read.error,
         pages: read && read.pages,
         truncated: (read && read.truncated) || String.length(words) > @max_text,
         text: String.slice(words, 0, @max_text)
       }}
    end
  end

  defp link(args, context) do
    with {:ok, id} <- attachment_id(args),
         {:ok, attachment} <- fetch(id),
         :ok <- readable(attachment, Args.auth(context)) do
      {:ok, secret, expires_at} =
        TransferLinks.mint(context.user, context.token, {:attachment, attachment})

      url = context.base_url <> "/api/download/" <> secret

      {:ok,
       attachment
       |> Uploads.json()
       |> Map.merge(owner(attachment))
       |> Map.merge(%{
         download_url: url,
         expires_at: expires_at,
         curl: "curl -fsSo #{shell_name(attachment.filename)} #{url}",
         note: "Works once, for #{div(TransferLinks.ttl_seconds(), 60)} minutes, with no token."
       })}
    end
  end

  @doc "`name` quoted for a shell when it needs to be: a name with spaces is common."
  def shell_name(name) do
    if Regex.match?(~r/\A[\w.-]+\z/, name),
      do: name,
      else: "'" <> String.replace(name, "'", "'\\''") <> "'"
  end

  defp attachment_id(args) do
    case Args.id(args, "attachment") do
      {:ok, id} -> {:ok, id}
      {:error, "attachment is required"} = e -> e
      {:error, _} -> {:error, "attachment must be an attachment id, like 42"}
    end
  end

  defp fetch(id) do
    case Repo.get(Attachment, id) do
      nil -> not_found()
      attachment -> {:ok, Repo.preload(attachment, [:card, :page])}
    end
  end

  # Whatever the file hangs off decides, through the same checks as reading
  # that card or page. One the token can't read is not there.
  defp readable(%Attachment{card: %Boards.Card{} = card}, auth) do
    case Authorize.card(auth, card, :read) do
      :ok -> :ok
      _ -> not_found()
    end
  end

  defp readable(%Attachment{page: %Slipdock.Wiki.Page{} = page}, auth) do
    case ReadPage.check(page, auth, :read) do
      :ok -> :ok
      _ -> not_found()
    end
  end

  defp readable(_attachment, _auth), do: not_found()

  defp read(attachment) do
    case File.read(Boards.attachment_path(attachment)) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, _} -> {:error, "the file's bytes are missing on the server, so it can't be sent"}
    end
  end

  defp owner(%Attachment{card: %Boards.Card{id: id}}), do: %{card: id}
  defp owner(%Attachment{page: %Slipdock.Wiki.Page{code: code}}), do: %{page: code}

  defp answer(attachment, bytes, info) do
    cond do
      Attachment.image?(attachment) ->
        with :ok <- fits(bytes, info) do
          {:ok, info,
           [%{type: "image", data: Base.encode64(bytes), mimeType: attachment.content_type}]}
        end

      text?(attachment, bytes) ->
        {:ok,
         Map.merge(info, %{
           text: String.slice(bytes, 0, @max_text),
           truncated: String.length(bytes) > @max_text
         })}

      true ->
        with :ok <- fits(bytes, info) do
          {:ok, info,
           [
             %{
               type: "resource",
               resource: %{
                 uri: info.url,
                 mimeType: attachment.content_type,
                 blob: Base.encode64(bytes)
               }
             }
           ]}
        end
    end
  end

  defp fits(bytes, _info) when byte_size(bytes) <= @max_bytes, do: :ok

  defp fits(bytes, info),
    do:
      {:error,
       "#{info.filename} is #{byte_size(bytes)} bytes, and download_file sends up to " <>
         "#{@max_bytes}. Open it in the web app instead: #{info.url}"}

  # Text by its type, or by being valid UTF-8 with no NUL in it: a .md or a
  # .csv that came in as application/octet-stream is still worth reading.
  defp text?(%Attachment{content_type: "text/" <> _}, bytes), do: String.valid?(bytes)

  defp text?(%Attachment{content_type: type}, bytes)
       when type in ~w(application/json application/xml application/x-yaml application/yaml
                       application/javascript application/x-sh image/svg+xml),
       do: String.valid?(bytes)

  defp text?(%Attachment{content_type: "application/octet-stream"}, bytes),
    do: String.valid?(bytes) and not String.contains?(bytes, <<0>>)

  defp text?(_attachment, _bytes), do: false

  defp not_found, do: {:error, "no attachment you can see matches that"}
end
