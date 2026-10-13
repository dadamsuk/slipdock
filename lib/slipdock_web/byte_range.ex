defmodule SlipdockWeb.ByteRange do
  @moduledoc """
  Sends a file from disk, answering a `Range` request with just those bytes
  (206): an audio player seeks with them, and Safari will not play a
  recording without them. A card's attachments (`SlipdockWeb.AttachmentController`)
  and a wiki file played in the file viewer (`SlipdockWeb.WikiFileController`)
  both go through `send/5`.
  """
  import Plug.Conn
  import Phoenix.Controller, only: [send_download: 3]

  @doc """
  Sends the file at `path` as `filename`, of `content_type`, with
  `disposition` `:inline` or `:attachment`: the whole of it, the one range
  asked for, or a 416 when that range is outside the file. The caller sets
  any caching headers first.
  """
  def send(conn, path, filename, content_type, disposition) do
    conn = put_resp_header(conn, "accept-ranges", "bytes")

    case byte_range(conn, File.stat!(path).size) do
      :all ->
        send_download(conn, {:file, path},
          filename: filename,
          content_type: content_type,
          disposition: disposition
        )

      {:range, first, last, size} ->
        conn
        |> put_resp_content_type(content_type, nil)
        |> put_resp_header("content-disposition", disposition_header(disposition, filename))
        |> put_resp_header("content-range", "bytes #{first}-#{last}/#{size}")
        |> send_file(206, path, first, last - first + 1)

      {:unsatisfiable, size} ->
        conn
        |> put_resp_header("content-range", "bytes */#{size}")
        |> send_resp(416, "")
    end
  end

  # One range, the only kind a media player asks for: `bytes=a-b`, `bytes=a-`
  # or `bytes=-n` (the last n). Several ranges, or a header that doesn't
  # parse, get the whole file, as the spec allows.
  defp byte_range(conn, size) do
    with ["bytes=" <> spec] <- get_req_header(conn, "range"),
         [from, to] <- String.split(spec, "-", parts: 2),
         {:ok, first, last} <- bounds(from, to, size) do
      if first <= last and first < size,
        do: {:range, first, min(last, size - 1), size},
        else: {:unsatisfiable, size}
    else
      :unsatisfiable -> {:unsatisfiable, size}
      _ -> :all
    end
  end

  defp bounds("", "", _size), do: :error

  defp bounds("", suffix, size) do
    case Integer.parse(suffix) do
      {0, ""} -> :unsatisfiable
      {n, ""} when n > 0 -> {:ok, max(size - n, 0), size - 1}
      _ -> :error
    end
  end

  defp bounds(from, to, size) do
    with {first, ""} when first >= 0 <- Integer.parse(from),
         {:ok, last} <- last_byte(to, size) do
      {:ok, first, last}
    else
      _ -> :error
    end
  end

  defp last_byte("", size), do: {:ok, size - 1}

  defp last_byte(to, _size) do
    case Integer.parse(to) do
      {last, ""} when last >= 0 -> {:ok, last}
      _ -> :error
    end
  end

  # As `send_download/3` writes it, so a range and a whole file name the file
  # the same way.
  defp disposition_header(type, filename) do
    encoded = URI.encode(filename, &URI.char_unreserved?/1)
    ~s(#{type}; filename="#{encoded}"; filename*=utf-8''#{encoded})
  end
end
