defmodule Slipdock.Inbound.Message do
  @moduledoc """
  An inbound email, parsed: the headers the app decides by, the text and HTML
  bodies as UTF-8, and the attachments (#1237, W-1933).

  `parse/1` takes the raw MIME exactly as the Worker posted it. It never
  raises: mail that cannot be read is `{:error, reason}`.

  Why not `:mimemail.decode/2`, which `gen_smtp` already brings in: without the
  `iconv` package it drops every byte above 127 *before* undoing the transfer
  encoding, so an 8-bit UTF-8 body loses its accents, and its header parser
  turns raw UTF-8 headers into question marks. Mail is mostly
  `multipart/alternative` with a known handful of charsets, so the parsing is
  done here: headers (folded, RFC 2047 encoded words, raw UTF-8), MIME parts
  (multipart of any depth, `message/rfc822`), transfer encodings (base64,
  quoted-printable, 7bit, 8bit, binary) and charsets (UTF-8, US-ASCII,
  ISO-8859-1 and -15, Windows-1252; anything else is kept where it is valid
  UTF-8, with the rest replaced).
  """

  defstruct from: nil,
            from_name: nil,
            to: [],
            cc: [],
            subject: nil,
            message_id: nil,
            in_reply_to: nil,
            references: [],
            authentication_results: [],
            auto_submitted: nil,
            precedence: nil,
            list_id: nil,
            text: nil,
            html: nil,
            attachments: [],
            headers: []

  @type attachment :: %{
          filename: String.t(),
          content_type: String.t(),
          data: binary(),
          content_id: String.t() | nil,
          inline: boolean()
        }

  @type t :: %__MODULE__{
          from: String.t() | nil,
          from_name: String.t() | nil,
          to: [String.t()],
          cc: [String.t()],
          subject: String.t() | nil,
          message_id: String.t() | nil,
          in_reply_to: String.t() | nil,
          references: [String.t()],
          authentication_results: [{String.t(), String.t()}],
          auto_submitted: String.t() | nil,
          precedence: String.t() | nil,
          list_id: String.t() | nil,
          text: String.t() | nil,
          html: String.t() | nil,
          attachments: [attachment()],
          headers: [{String.t(), String.t()}]
        }

  # Deeper than any real message nests; a crafted one could recurse forever.
  @max_depth 20

  @doc """
  Parses raw MIME. `authentication_results` keeps every
  `Authentication-Results` and `ARC-Authentication-Results` header, top first
  (the order receiving servers prepend them in), as `{lowercase name, value}`.
  `headers` is every top-level header, decoded, in order.
  """
  @spec parse(binary()) :: {:ok, t()} | {:error, atom()}
  def parse(raw) when is_binary(raw) and byte_size(raw) > 0 do
    {headers, body} = split_headers(raw)

    if headers == [] do
      {:error, :no_headers}
    else
      {texts, htmls, attachments} = walk(headers, body, 0)
      {from_name, from} = from(header(headers, "from"))

      {:ok,
       %__MODULE__{
         from: from,
         from_name: from_name,
         to: addresses(header(headers, "to")),
         cc: addresses(header(headers, "cc")),
         subject: header(headers, "subject"),
         message_id: header(headers, "message-id"),
         in_reply_to: header(headers, "in-reply-to"),
         references: references(header(headers, "references")),
         authentication_results:
           Enum.filter(
             headers,
             &(elem(&1, 0) in ["authentication-results", "arc-authentication-results"])
           ),
         auto_submitted: header(headers, "auto-submitted"),
         precedence: header(headers, "precedence"),
         list_id: header(headers, "list-id"),
         text: first(texts),
         html: first(htmls),
         attachments: attachments,
         headers: headers
       }}
    end
  rescue
    _ -> {:error, :malformed}
  catch
    {:malformed, reason} -> {:error, reason}
    _, _ -> {:error, :malformed}
  end

  def parse(_), do: {:error, :empty}

  @doc "The first header called `name` (any case), decoded; nil if there is none."
  @spec header([{String.t(), String.t()}], String.t()) :: String.t() | nil
  def header(headers, name) do
    case List.keyfind(headers, String.downcase(name), 0) do
      {_, value} -> value
      nil -> nil
    end
  end

  ## Parts

  # Returns the text bodies, HTML bodies and attachments of a part, in order.
  defp walk(_headers, _body, depth) when depth > @max_depth, do: throw({:malformed, :too_deep})

  defp walk(headers, body, depth) do
    {type, params} = content_type(header(headers, "content-type"))
    {disposition, disp_params} = disposition(header(headers, "content-disposition"))

    cond do
      String.starts_with?(type, "multipart/") ->
        boundary = params["boundary"] || throw({:malformed, :no_boundary})

        body
        |> split_parts(boundary)
        |> Enum.map(fn part ->
          {part_headers, part_body} = split_headers(part)
          walk(part_headers, part_body, depth + 1)
        end)
        |> Enum.reduce({[], [], []}, fn {t, h, a}, {ts, hs, as} -> {ts ++ t, hs ++ h, as ++ a} end)

      type == "message/rfc822" ->
        # A forward sent as an attached message: its bodies are not this
        # message's, so it is kept whole, as a file.
        {[], [],
         [attachment(headers, body, "message/rfc822", params, disp_params, "forwarded.eml")]}

      type in ["text/plain", "text/html"] and disposition != "attachment" and
          not Map.has_key?(disp_params, "filename") ->
        text = body |> transfer_decode(headers) |> to_utf8(params["charset"])
        if type == "text/plain", do: {[text], [], []}, else: {[], [text], []}

      true ->
        {[], [], [attachment(headers, body, type, params, disp_params, nil)]}
    end
  end

  defp attachment(headers, body, type, params, disp_params, default_name) do
    content_id =
      case header(headers, "content-id") do
        nil -> nil
        id -> id |> String.trim() |> String.trim_leading("<") |> String.trim_trailing(">")
      end

    {disposition, _} = disposition(header(headers, "content-disposition"))

    %{
      filename:
        disp_params["filename"] || params["name"] || default_name ||
          default_filename(type, content_id),
      content_type: type,
      data: transfer_decode(body, headers),
      content_id: content_id,
      inline: content_id != nil and disposition != "attachment"
    }
  end

  defp default_filename(type, content_id) do
    ext =
      case String.split(type, "/") do
        [_, sub] -> "." <> sub
        _ -> ""
      end

    (content_id || "attachment") <> ext
  end

  defp split_parts(body, boundary) do
    delimiter = "--" <> boundary

    body
    # A delimiter is the whole line: `--b1` must not match `--b10`.
    |> String.split(~r/(?:\A|\r?\n)#{Regex.escape(delimiter)}(?=--|[ \t]*(?:\r?\n|\z))/)
    # The preamble, before the first delimiter.
    |> Enum.drop(1)
    |> Enum.take_while(&(not String.starts_with?(&1, "--")))
    |> Enum.map(&strip_delimiter_line/1)
  end

  # What follows a delimiter on its own line (transport padding) is not part
  # of the part.
  defp strip_delimiter_line(part) do
    case :binary.match(part, "\n") do
      {at, 1} -> binary_part(part, at + 1, byte_size(part) - at - 1)
      :nomatch -> ""
    end
  end

  ## Headers

  # The header block, unfolded and decoded, and the body after it. Lines may
  # end in CRLF or a bare LF. A line that is not a header ends the block.
  defp split_headers(raw) do
    {head, body} =
      case Regex.run(~r/\r?\n\r?\n/, raw, return: :index) do
        [{at, len}] ->
          {binary_part(raw, 0, at), binary_part(raw, at + len, byte_size(raw) - at - len)}

        nil ->
          {raw, ""}
      end

    lines = head |> String.split(~r/\r?\n/) |> unfold([])

    {headers, rest} =
      Enum.split_while(lines, &Regex.match?(~r/^[\x21-\x39\x3B-\x7E]+:/, &1))

    headers =
      Enum.map(headers, fn line ->
        [name, value] = String.split(line, ":", parts: 2)
        {String.downcase(name), value |> String.trim() |> decode_words()}
      end)

    # A header block that stops early hands the rest back as body.
    body = if rest == [], do: body, else: Enum.join(rest, "\r\n") <> "\r\n\r\n" <> body
    {headers, body}
  end

  defp unfold([], acc), do: Enum.reverse(acc)

  defp unfold([<<c, _::binary>> = line | rest], [prev | acc]) when c in [?\s, ?\t],
    do: unfold(rest, [prev <> " " <> String.trim_leading(line) | acc])

  defp unfold([line | rest], acc), do: unfold(rest, [line | acc])

  # RFC 2047: =?charset?B|Q?text?= — whitespace between two encoded words goes.
  defp decode_words(value) do
    value = to_utf8(value, "utf-8")

    if String.contains?(value, "=?") do
      value
      |> String.replace(~r/(\?=)\s+(=\?)/, "\\1\\2")
      |> then(
        &Regex.replace(~r/=\?([^?\s]+)\?([BbQq])\?([^?]*)\?=/, &1, fn whole, charset, enc, text ->
          case decode_word(enc, text) do
            {:ok, bytes} -> to_utf8(bytes, charset |> String.split("*") |> hd())
            :error -> whole
          end
        end)
      )
    else
      value
    end
  end

  defp decode_word(enc, text) when enc in ["B", "b"], do: Base.decode64(text, padding: false)

  defp decode_word(_q, text),
    do: {:ok, text |> String.replace("_", " ") |> qp_decode()}

  defp content_type(nil), do: {"text/plain", %{}}

  defp content_type(value) do
    {type, params} = value_and_params(value)
    if String.contains?(type, "/"), do: {type, params}, else: {"text/plain", params}
  end

  defp disposition(nil), do: {nil, %{}}
  defp disposition(value), do: value_and_params(value)

  # `type/sub; a=b; c="d; e"`, with RFC 2231's `name*=utf-8''%E2%82%AC` and
  # `name*0=…; name*1=…` folded back into `name`.
  defp value_and_params(value) do
    [main | params] = split_unquoted(value, ?;)

    params =
      params
      |> Enum.flat_map(fn param ->
        case String.split(param, "=", parts: 2) do
          [key, val] ->
            [{key |> String.trim() |> String.downcase(), unquote_value(String.trim(val))}]

          _ ->
            []
        end
      end)
      |> Enum.group_by(fn {key, _} -> key |> String.split("*") |> hd() end)
      |> Map.new(fn {name, pairs} -> {name, param_value(pairs)} end)

    {main |> String.trim() |> String.downcase(), params}
  end

  defp param_value([{key, value}]) do
    if String.ends_with?(key, "*"), do: rfc2231(value), else: value
  end

  defp param_value(pairs) do
    pairs = Enum.sort_by(pairs, fn {key, _} -> continuation_index(key) end)
    encoded? = pairs |> hd() |> elem(0) |> String.ends_with?("*")
    joined = Enum.map_join(pairs, "", &elem(&1, 1))
    if encoded?, do: rfc2231(joined), else: joined
  end

  defp continuation_index(key) do
    case Regex.run(~r/\*(\d+)/, key) do
      [_, n] -> String.to_integer(n)
      nil -> -1
    end
  end

  defp rfc2231(value) do
    case String.split(value, "'", parts: 3) do
      [charset, _lang, text] -> text |> URI.decode() |> to_utf8(charset)
      _ -> URI.decode(value)
    end
  rescue
    ArgumentError -> value
  end

  defp unquote_value(<<?", rest::binary>>),
    do: rest |> String.trim_trailing("\"") |> String.replace(~r/\\(.)/, "\\1")

  defp unquote_value(value), do: value

  # Splits on `sep` outside double quotes and angle brackets.
  defp split_unquoted(value, sep) do
    {parts, current, _} =
      value
      |> String.to_charlist()
      |> Enum.reduce({[], [], nil}, fn
        ?", {parts, cur, nil} -> {parts, [?" | cur], ?"}
        ?", {parts, cur, ?"} -> {parts, [?" | cur], nil}
        ?<, {parts, cur, nil} -> {parts, [?< | cur], ?>}
        ?>, {parts, cur, ?>} -> {parts, [?> | cur], nil}
        ^sep, {parts, cur, nil} -> {[cur | parts], [], nil}
        c, {parts, cur, state} -> {parts, [c | cur], state}
      end)

    [current | parts]
    |> Enum.reverse()
    |> Enum.map(&(&1 |> Enum.reverse() |> List.to_string()))
  end

  ## Addresses

  defp from(nil), do: {nil, nil}

  defp from(value) do
    case parse_address(value |> split_unquoted(?,) |> hd()) do
      nil -> {nil, nil}
      {name, address} -> {name, address}
    end
  end

  defp addresses(nil), do: []

  defp addresses(value) do
    value
    |> split_unquoted(?,)
    |> Enum.map(&parse_address/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&elem(&1, 1))
  end

  defp parse_address(value) do
    value = String.trim(value)

    case Regex.run(~r/^(.*)<\s*([^<>\s]+@[^<>\s]+)\s*>/s, value) do
      [_, name, address] ->
        name = name |> String.trim() |> unquote_value() |> String.trim()
        {if(name == "", do: nil, else: name), String.downcase(address)}

      nil ->
        case Regex.run(~r/([^\s<>()"]+@[^\s<>()"]+)/, value) do
          [_, address] -> {nil, String.downcase(address)}
          nil -> nil
        end
    end
  end

  defp references(nil), do: []
  defp references(value), do: Regex.scan(~r/<[^<>\s]+>/, value) |> List.flatten()

  ## Bodies

  defp transfer_decode(body, headers) do
    case header(headers, "content-transfer-encoding") |> to_string() |> String.downcase() do
      "base64" ->
        body |> String.replace(~r/[^A-Za-z0-9+\/=]/, "") |> base64()

      "quoted-printable" ->
        qp_decode(body)

      _ ->
        body
    end
  end

  # Lenient: mail in the wild has unpadded and over-padded base64.
  defp base64(data) do
    data = String.trim_trailing(data, "=")

    case Base.decode64(data, padding: false) do
      {:ok, bytes} -> bytes
      :error -> throw({:malformed, :bad_base64})
    end
  end

  # Quoted-printable, forgiving of bad escapes (kept as written).
  defp qp_decode(body) do
    body
    |> String.replace(~r/=\r?\n/, "")
    |> then(
      &Regex.replace(~r/=([0-9A-Fa-f]{2})/, &1, fn _, hex ->
        <<String.to_integer(hex, 16)>>
      end)
    )
  end

  @doc false
  # Bytes in `charset`, as UTF-8.
  def to_utf8(bytes, charset) do
    case charset |> to_string() |> String.trim() |> String.downcase() do
      cs when cs in ["iso-8859-1", "latin1", "iso8859-1", "latin-1"] ->
        :unicode.characters_to_binary(bytes, :latin1)

      cs when cs in ["iso-8859-15", "latin-9"] ->
        bytes |> :binary.bin_to_list() |> Enum.map(&latin9/1) |> List.to_string()

      cs when cs in ["windows-1252", "cp1252"] ->
        bytes |> :binary.bin_to_list() |> Enum.map(&cp1252/1) |> List.to_string()

      _ ->
        if String.valid?(bytes), do: bytes, else: scrub(bytes)
    end
  end

  # Invalid UTF-8 in a part that claims UTF-8 (or a charset not handled
  # above): the valid stretches are kept, and each stray byte is read as
  # Windows-1252, which is what it most often really is.
  defp scrub(bytes), do: scrub(bytes, [])

  defp scrub(<<>>, acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp scrub(bytes, acc) do
    case :unicode.characters_to_binary(bytes) do
      good when is_binary(good) ->
        scrub(<<>>, [good | acc])

      {_, good, <<byte, rest::binary>>} ->
        scrub(rest, [<<cp1252(byte)::utf8>>, good | acc])
    end
  end

  @cp1252 %{
    0x80 => 0x20AC,
    0x82 => 0x201A,
    0x83 => 0x0192,
    0x84 => 0x201E,
    0x85 => 0x2026,
    0x86 => 0x2020,
    0x87 => 0x2021,
    0x88 => 0x02C6,
    0x89 => 0x2030,
    0x8A => 0x0160,
    0x8B => 0x2039,
    0x8C => 0x0152,
    0x8E => 0x017D,
    0x91 => 0x2018,
    0x92 => 0x2019,
    0x93 => 0x201C,
    0x94 => 0x201D,
    0x95 => 0x2022,
    0x96 => 0x2013,
    0x97 => 0x2014,
    0x98 => 0x02DC,
    0x99 => 0x2122,
    0x9A => 0x0161,
    0x9B => 0x203A,
    0x9C => 0x0153,
    0x9E => 0x017E,
    0x9F => 0x0178
  }

  defp cp1252(byte), do: Map.get(@cp1252, byte, byte)

  @latin9 %{
    0xA4 => 0x20AC,
    0xA6 => 0x0160,
    0xA8 => 0x0161,
    0xB4 => 0x017D,
    0xB8 => 0x017E,
    0xBC => 0x0152,
    0xBD => 0x0153,
    0xBE => 0x0178
  }

  defp latin9(byte), do: Map.get(@latin9, byte, byte)

  defp first([]), do: nil
  defp first([one | _]), do: one
end
