defmodule SlipdockWeb.MCP.Tools.UploadFile do
  @moduledoc """
  A file attached to a card or a wiki page over MCP (#919): what
  `POST /api/cards/:id/attachments` and its page twin do, with the bytes in
  the arguments, since a tool call has no multipart body. It goes through the
  same `Boards.add_attachment/3` and `Wiki.add_attachment/3`, so the size
  limit, the quota and the activity log are the ones every upload meets.
  """
  @behaviour SlipdockWeb.MCP.Tool

  alias Slipdock.{Boards, Wiki}
  alias SlipdockWeb.API.{Authorize, CardWrites, Uploads}
  alias SlipdockWeb.MCP.Args
  alias SlipdockWeb.MCP.Tools.ReadPage

  # Decoded. Base64 makes it a third bigger, which still fits the request
  # limit in `SlipdockWeb.MCP.Plug`; a bigger file goes through the API.
  @max_bytes 10_000_000

  @doc "The largest file `upload_file` takes, in bytes."
  def max_bytes, do: @max_bytes

  @impl true
  def name, do: "upload_file"

  @impl true
  def title, do: "Upload a file"

  @impl true
  def description,
    do:
      "Attaches a file (up to 10 MB) to a card, or to a wiki page. Send the bytes as " <>
        "content_base64, or a text file's contents as text. Returns the attachment and " <>
        "markdown that embeds it, to put in a description, comment or page body."

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        card: %{type: "integer", description: "The card to attach it to, e.g. 129."},
        page: %{
          type: "string",
          description: "Or the page: its code like W-31, or a slug with board."
        },
        board: %{type: "string", description: "The board, when page is a slug or title."},
        filename: %{type: "string", description: "The name to store it under, e.g. shot.png."},
        content_base64: %{type: "string", description: "The file's bytes, base64."},
        text: %{type: "string", description: "Or a text file's contents, as they are."},
        content_type: %{type: "string", description: "Its MIME type. Left out, the name decides."},
        hide_on_card: %{type: "boolean", description: "Keep an image off the card's front."}
      },
      required: ["filename"],
      additionalProperties: false
    }
  end

  @impl true
  def read_only?, do: false

  @impl true
  def call(args, context) do
    auth = Args.auth(context)

    with {:ok, filename} <- Args.required(args, "filename"),
         {:ok, bytes} <- bytes(args),
         {:ok, type} <- Args.optional(args, "content_type"),
         {:ok, hide?} <- Args.boolean(args, "hide_on_card", false),
         {:ok, owner} <- owner(args, auth) do
      meta = %{
        filename: filename,
        content_type: type || MIME.from_path(filename),
        size: byte_size(bytes),
        hide_on_card: hide?
      }

      with_file(bytes, fn path -> attach(owner, meta, path) end)
    end
  end

  defp bytes(%{"content_base64" => _, "text" => _}),
    do: {:error, "send content_base64 or text, not both"}

  defp bytes(%{"content_base64" => data}) when is_binary(data) do
    case Base.decode64(String.replace(data, ~r/\s/, ""), padding: false) do
      {:ok, bytes} -> sized(bytes)
      :error -> {:error, "content_base64 is not valid base64"}
    end
  end

  defp bytes(%{"text" => text}) when is_binary(text), do: sized(text)

  defp bytes(%{"content_base64" => _}), do: {:error, "content_base64 must be a string"}
  defp bytes(%{"text" => _}), do: {:error, "text must be a string"}

  defp bytes(_),
    do: {:error, "send the file as content_base64 (any file) or text (a text file)"}

  defp sized(""), do: {:error, "the file is empty"}

  defp sized(bytes) when byte_size(bytes) > @max_bytes,
    do:
      {:error,
       "the file is #{byte_size(bytes)} bytes, and upload_file takes up to #{@max_bytes}. " <>
         "Send a bigger one with the CLI (slipdock attach) or the HTTP API."}

  defp sized(bytes), do: {:ok, bytes}

  defp owner(%{"card" => _, "page" => _}, _auth), do: {:error, "give card or page, not both"}

  defp owner(%{"card" => _} = args, auth) do
    with {:ok, id} <- Args.id(args, "card"),
         {:ok, card} <- Args.refusal(CardWrites.fetch_card(id)),
         :ok <- Args.refusal(Authorize.card(auth, card, :write)) do
      {:ok, {:card, card}}
    end
  end

  defp owner(%{"page" => _} = args, auth) do
    with {:ok, ref} <- Args.required(args, "page"),
         {:ok, board_ref} <- Args.optional(args, "board"),
         {:ok, page} <- ReadPage.find(ref, board_ref, auth),
         :ok <- ReadPage.check(page, auth, :write) do
      {:ok, {:page, page}}
    end
  end

  defp owner(_args, _auth), do: {:error, "say where it goes: card, or page"}

  defp attach({:card, card}, meta, path) do
    with {:ok, a} <- Args.refusal(Boards.add_attachment(card, meta, path)) do
      {:ok, %{card: card.id, attachment: Uploads.json(a)}}
    end
  end

  defp attach({:page, page}, meta, path) do
    with {:ok, a} <- Args.refusal(Wiki.add_attachment(page, meta, path)) do
      {:ok, %{page: page.code, attachment: Uploads.json(a)}}
    end
  end

  # The attachment code copies from a path, as it does for a multipart upload.
  defp with_file(bytes, fun) do
    path = Path.join(System.tmp_dir!(), "mcp-upload-" <> Ecto.UUID.generate())
    File.write!(path, bytes)

    try do
      fun.(path)
    after
      File.rm(path)
    end
  end
end
