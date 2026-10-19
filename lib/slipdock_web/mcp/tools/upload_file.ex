defmodule SlipdockWeb.MCP.Tools.UploadFile do
  @moduledoc """
  A file attached to a card or a wiki page over MCP (#919): what
  `POST /api/cards/:id/attachments` and its page twin do, with the bytes in
  the arguments, since a tool call has no multipart body. It goes through the
  same `Boards.add_attachment/3` and `Wiki.add_attachment/3`, so the size
  limit, the quota and the activity log are the ones every upload meets.

  A file can also come in verified pieces (#1016): `append: true` starts or
  adds to an upload (`upload_id`), each piece with its own `sha256`, so a
  piece that changed on the way is refused and resent alone; `finish: true`
  checks the whole file's `sha256` and only then makes it an attachment.
  The pieces wait in `Slipdock.ChunkedUploads`, never on the card.

  Base64 a model writes out goes wrong above about 1 KB (#1040), so a whole
  `content_base64` upload must carry its `sha256`, and `vault` with
  `vault_file` copies a file the vault already holds, by sync, without its
  bytes passing through the caller at all.

  `link: true` (#1147) sends no file at all: it answers with a single-use
  URL, good for ten minutes, that a shell POSTs the file to with curl
  (`SlipdockWeb.API.TransferController`), so neither the bytes nor a
  long-lived token pass through the agent.

  `replace: true` (#1017) deletes the card's or page's older files of the
  same name once the new one is stored, so a rebuild leaves one current
  copy; `delete_attachment` removes one by id.
  """
  @behaviour SlipdockWeb.MCP.Tool

  alias Slipdock.{Boards, ChunkedUploads, TransferLinks, Vaults, Wiki}
  alias Slipdock.Boards.Attachment
  alias Slipdock.Vaults.Sync
  alias Slipdock.Wiki.Files
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
      "Attaches a file (up to 10 MB) to a card, or to a wiki page. Bytes you write out " <>
        "yourself as base64 go wrong above about 1 KB, so pick the path where they don't " <>
        "pass through you. With a shell where the file is: card or page with link: true " <>
        "returns a single-use upload_url, good for 10 minutes, and no token is needed to use " <>
        "it: curl -F file=@a.docx -F sha256=<hex> <upload_url> (also takes filename, replace, " <>
        "hide_on_card) answers with the attachment. A file in a synced vault: vault and " <>
        "vault_file (its path in the vault, or its id), and the server copies it. Otherwise " <>
        "text for a text file's contents, or content_base64 with sha256 (required: the hex " <>
        "SHA-256 of the bytes before base64; a file that changed on the way is refused with " <>
        "sha256_mismatch and not stored), anything over 1 KB in chunks: the first with " <>
        "append: true (plus card or page, filename) and its own sha256 returns an upload_id; " <>
        "each next chunk with upload_id, append: true, offset and its sha256 (a refused " <>
        "chunk is resent on its own); then upload_id, finish: true and the whole file's " <>
        "sha256, which makes the attachment. Returns the attachment, with the sha256 of the " <>
        "bytes as stored, and markdown that embeds it. replace: true deletes older files of " <>
        "the same name once this one is stored."

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
        filename: %{
          type: "string",
          description:
            "The name to store it under, e.g. shot.png. Left out with vault_file, the file's own."
        },
        content_base64: %{
          type: "string",
          description: "The file's bytes, base64, with sha256. Over 1 KB, in chunks (append)."
        },
        text: %{type: "string", description: "Or a text file's contents, as they are."},
        vault: %{type: "string", description: "With vault_file: the vault's name or id."},
        vault_file: %{
          type: "string",
          description:
            "Or copy a file the vault already holds: its path in the vault (e.g. " <>
              "Jobs/cv.docx) or its id. No content in the call; sha256, if sent, is checked " <>
              "against the vault's copy."
        },
        sha256: %{
          type: "string",
          description:
            "The SHA-256 of the file's bytes, hex, before base64. Sent, a file that doesn't " <>
              "match is refused and not stored. Required with content_base64."
        },
        append: %{
          type: "boolean",
          description:
            "Send the file in chunks: this is one, with its own sha256. Without upload_id it " <>
              "starts an upload and returns its upload_id."
        },
        upload_id: %{
          type: "string",
          description: "The chunked upload this chunk belongs to, or that finish completes."
        },
        offset: %{
          type: "integer",
          description:
            "Where this chunk starts in the file, in bytes (the received of the last answer). " <>
              "Makes a resend of a chunk that already landed harmless."
        },
        finish: %{
          type: "boolean",
          description:
            "With upload_id and the whole file's sha256: checks the assembled file and attaches " <>
              "it. No content in this call."
        },
        content_type: %{type: "string", description: "Its MIME type. Left out, the name decides."},
        hide_on_card: %{type: "boolean", description: "Keep an image off the card's front."},
        link: %{
          type: "boolean",
          description:
            "Send no file: get a single-use upload_url for card or page, good for 10 minutes, " <>
              "to POST the file to from a shell (curl -F file=@a.docx -F sha256=<hex> <url>)."
        },
        replace: %{
          type: "boolean",
          description:
            "Delete the card's or page's older files of this filename once this one is stored, " <>
              "so a rebuild leaves one copy. Their ids come back as replaced."
        }
      },
      additionalProperties: false
    }
  end

  @impl true
  def read_only?, do: false

  @impl true
  def call(%{"link" => true} = args, context), do: link(args, context)

  def call(args, context) do
    case {args["finish"], args["append"]} do
      {true, true} ->
        {:error, "send append: true (a chunk) or finish: true, not both"}

      {true, _} ->
        finish(args, context)

      {_, true} when is_map_key(args, "vault_file") ->
        {:error, "a vault_file is copied whole: leave out append"}

      {_, true} ->
        chunk(args, context)

      _ when is_map_key(args, "upload_id") ->
        {:error, "with upload_id, say append: true or finish: true"}

      _ when is_map_key(args, "vault_file") ->
        from_vault(args, context)

      _ ->
        whole(args, context)
    end
  end

  # Only where it goes: what the file is called and how it is stored are the
  # POST's to say, as they are for the attachment endpoint.
  defp link(args, context) do
    extra = Map.keys(args) -- ["link", "card", "page", "board"]

    with :ok <- link_only(extra),
         {:ok, owner} <- owner(args, Args.auth(context)) do
      {:ok, secret, expires_at} = TransferLinks.mint(context.user, context.token, owner)
      url = context.base_url <> "/api/upload/" <> secret

      {:ok,
       Map.merge(target(owner), %{
         upload_url: url,
         method: "POST",
         expires_at: expires_at,
         fields: %{
           file: "required: the file, as multipart (-F file=@path)",
           sha256: "the hex SHA-256 of the file; a file that doesn't match is refused",
           filename: "the name to store it under; left out, the file's own",
           replace: "true deletes older files of the same name once this one is stored",
           hide_on_card: "true keeps an image off the card's front"
         },
         curl: "curl -sS -F file=@<path> -F sha256=<hex> #{url}",
         note:
           "Works once, for #{div(TransferLinks.ttl_seconds(), 60)} minutes, with no token; a " <>
             "refused upload (say a sha256 mismatch) leaves it good to try again. The answer " <>
             "is the attachment, as the attachments endpoint gives it."
       })}
    end
  end

  defp link_only([]), do: :ok

  defp link_only(extra),
    do:
      {:error,
       "with link: true send only card or page (and board): the file and its " <>
         "#{Enum.join(Enum.sort(extra), ", ")} go in the POST to upload_url"}

  defp target({:card, card}), do: %{card: card.id}
  defp target({:page, page}), do: %{page: page.code}

  defp whole(args, context) do
    auth = Args.auth(context)

    with {:ok, filename} <- Args.required(args, "filename"),
         {:ok, bytes} <- bytes(args),
         :ok <- base64_sha256(args),
         :ok <- Args.refusal(Uploads.check_sha256(bytes, args["sha256"])),
         {:ok, type} <- Args.optional(args, "content_type"),
         {:ok, hide?} <- Args.boolean(args, "hide_on_card", false),
         {:ok, replace?} <- Args.boolean(args, "replace", false),
         {:ok, owner} <- owner(args, auth) do
      meta = %{
        filename: filename,
        content_type: type || MIME.from_path(filename),
        size: byte_size(bytes),
        hide_on_card: hide?
      }

      with_file(bytes, fn path -> attach(owner, meta, path, replace?) end)
    end
  end

  # Base64 a model wrote out comes back wrong often enough (#1040) that an
  # unchecked one is a silent corruption waiting to happen; text is sent as is.
  defp base64_sha256(%{"content_base64" => _} = args) when not is_map_key(args, "sha256"),
    do:
      {:error,
       "content_base64 needs sha256: the hex SHA-256 of the file's bytes before base64, so " <>
         "a file that changed on the way is refused rather than stored damaged"}

  defp base64_sha256(_args), do: :ok

  # A file the vault already holds, copied on the server (#1040): the bytes
  # came in by sync, so none of them pass through the caller.
  defp from_vault(args, context) do
    auth = Args.auth(context)

    with :ok <- no_vault_content(args),
         {:ok, vault_ref} <- Args.required(args, "vault"),
         {:ok, ref} <- Args.required(args, "vault_file"),
         {:ok, vault} <- Args.refusal(Vaults.get_vault(context.user, vault_ref)),
         {:ok, file, entry} <- vault_file(vault, ref, context),
         path = Files.disk_path(file),
         :ok <- vault_sha256(path, entry, args["sha256"]),
         {:ok, filename} <- Args.optional(args, "filename"),
         {:ok, type} <- Args.optional(args, "content_type"),
         {:ok, hide?} <- Args.boolean(args, "hide_on_card", false),
         {:ok, replace?} <- Args.boolean(args, "replace", false),
         {:ok, owner} <- owner(args, auth) do
      name = filename || file.name

      meta = %{
        filename: name,
        content_type: type || MIME.from_path(name),
        size: entry.size,
        hide_on_card: hide?
      }

      attach(owner, meta, path, replace?)
    end
  end

  defp no_vault_content(args) do
    if Map.has_key?(args, "content_base64") or Map.has_key?(args, "text"),
      do: {:error, "send vault_file or the content, not both"},
      else: :ok
  end

  # An id, or a path in the vault.
  defp vault_file(vault, ref, context) do
    opts = [token: context[:token]]

    result =
      case Integer.parse(ref) do
        {id, ""} -> Sync.read_file(vault, context.user, id, opts)
        _ -> Sync.read_file_at(vault, context.user, ref, opts)
      end

    Args.refusal(result)
  end

  defp vault_sha256(_path, _entry, nil), do: :ok

  defp vault_sha256(path, entry, given) do
    case Uploads.check_sha256({:path, path}, given) do
      {:error, _status, "sha256_mismatch" <> _} ->
        {actual, _size} = Attachment.file_sha256(path)

        {:error,
         "sha256_mismatch: #{entry.path} in the vault has sha256 #{actual}, not the one you " <>
           "sent, so the vault holds another version of it (has the sync caught up?). Nothing " <>
           "was stored."}

      result ->
        Args.refusal(result)
    end
  end

  # The first chunk says where the file goes and what it's called, and is
  # checked as the whole call is: the upload starts with a card or page the
  # token may write to.
  defp chunk(args, context) do
    auth = Args.auth(context)

    with {:ok, upload_id} <- Args.optional(args, "upload_id"),
         {:ok, offset} <- offset(args),
         {:ok, bytes} <- bytes(args),
         :ok <- chunk_sha256(args, bytes) do
      if upload_id,
        do: add_chunk(context.user.id, upload_id, bytes, offset),
        else: start(args, auth, context.user.id, bytes, offset)
    end
  end

  defp start(_args, _auth, _user_id, _bytes, offset) when offset not in [nil, 0],
    do: {:error, "offset_mismatch: the first chunk starts at offset 0; give an upload_id to add"}

  defp start(args, auth, user_id, bytes, _offset) do
    with {:ok, filename} <- Args.required(args, "filename"),
         {:ok, type} <- Args.optional(args, "content_type"),
         {:ok, hide?} <- Args.boolean(args, "hide_on_card", false),
         {:ok, replace?} <- Args.boolean(args, "replace", false),
         {:ok, owner} <- owner(args, auth) do
      meta = %{
        "owner" => owner_ref(owner),
        "replace" => replace?,
        "filename" => filename,
        "content_type" => type || MIME.from_path(filename),
        "hide_on_card" => hide?
      }

      with {:ok, id, received} <- ChunkedUploads.start(user_id, meta, bytes, @max_bytes) do
        {:ok, chunk_answer(id, received)}
      end
    end
  end

  defp add_chunk(user_id, upload_id, bytes, offset) do
    with {:ok, received} <-
           ChunkedUploads.append(user_id, upload_id, bytes, offset, @max_bytes) do
      {:ok, chunk_answer(upload_id, received)}
    end
  end

  defp chunk_answer(id, received) do
    %{
      upload_id: id,
      received: received,
      next:
        "Send the next chunk with upload_id, append: true and offset #{received}; when all " <>
          "are in, upload_id, finish: true and the whole file's sha256."
    }
  end

  # Every chunk carries its hash: verifying the pieces is what the chunks are for.
  defp chunk_sha256(%{"sha256" => given}, bytes) when is_binary(given) do
    case Uploads.check_sha256(bytes, given) do
      :ok ->
        :ok

      {:error, _status, "sha256_mismatch" <> rest} ->
        {:error,
         "sha256_mismatch" <>
           String.replace(rest, "the file arrived", "this chunk arrived") <>
           " The upload so far is kept: resend just this chunk."}

      refusal ->
        Args.refusal(refusal)
    end
  end

  defp chunk_sha256(_args, _bytes),
    do: {:error, "each chunk needs its sha256: the hex SHA-256 of this chunk's bytes"}

  defp offset(args) do
    case args["offset"] do
      nil -> {:ok, nil}
      n when is_integer(n) and n >= 0 -> {:ok, n}
      _ -> {:error, "offset must be a whole number of bytes, 0 or more"}
    end
  end

  # The assembled file against the whole file's hash, then the same checks a
  # whole upload meets, made again now: the token may have lost the card since.
  defp finish(args, context) do
    auth = Args.auth(context)
    user_id = context.user.id

    with {:ok, upload_id} <- Args.required(args, "upload_id"),
         :ok <- no_content(args),
         {:ok, given} <- whole_sha256(args),
         {:ok, replace?} <- Args.boolean(args, "replace", false),
         {:ok, meta, path, size} <- ChunkedUploads.fetch(user_id, upload_id),
         :ok <- assembled_sha256(upload_id, path, given),
         {:ok, owner} <- stored_owner(meta["owner"], auth) do
      attachment_meta = %{
        filename: meta["filename"],
        content_type: meta["content_type"],
        size: size,
        hide_on_card: meta["hide_on_card"]
      }

      # Said on the first chunk or on finish, either counts.
      result = attach(owner, attachment_meta, path, replace? or meta["replace"] == true)
      ChunkedUploads.discard(upload_id)
      result
    end
  end

  defp no_content(args) do
    if Map.has_key?(args, "content_base64") or Map.has_key?(args, "text"),
      do:
        {:error,
         "finish takes no content: send the last chunk with append: true first, then finish"},
      else: :ok
  end

  defp whole_sha256(%{"sha256" => given}) when is_binary(given), do: {:ok, given}

  defp whole_sha256(_),
    do: {:error, "finish needs sha256: the hex SHA-256 of the whole file, before base64"}

  # Every chunk was checked, so a whole file that still differs is missing or
  # repeating a piece; there is no telling which, so the upload goes.
  defp assembled_sha256(upload_id, path, given) do
    case Uploads.check_sha256({:path, path}, given) do
      :ok ->
        :ok

      {:error, _status, "sha256_mismatch" <> _} = refusal ->
        ChunkedUploads.discard(upload_id)
        {:error, message} = Args.refusal(refusal)

        {:error,
         String.replace(message, "Encode it again from the source file and resend.", "") <>
           "Every chunk matched its own hash, so a chunk is missing or was sent twice; the " <>
           "upload is discarded. Start again, sending offset with each chunk."}

      refusal ->
        Args.refusal(refusal)
    end
  end

  defp owner_ref({:card, card}), do: %{"card" => card.id}
  defp owner_ref({:page, page}), do: %{"page" => page.code}

  defp stored_owner(%{"card" => id}, auth), do: owner(%{"card" => id}, auth)
  defp stored_owner(%{"page" => code}, auth), do: owner(%{"page" => code}, auth)

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

  defp attach({:card, card}, meta, path, replace?) do
    with {:ok, a} <- Args.refusal(Boards.add_attachment(card, meta, path)) do
      {:ok, Map.put(Uploads.stored(a, replace?), :card, card.id)}
    end
  end

  defp attach({:page, page}, meta, path, replace?) do
    with {:ok, a} <- Args.refusal(Wiki.add_attachment(page, meta, path)) do
      {:ok, Map.put(Uploads.stored(a, replace?), :page, page.code)}
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
