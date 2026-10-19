defmodule SlipdockCLI.HTTP do
  @moduledoc "Tiny JSON client over OTP's :httpc. No dependencies."

  @doc """
  Which server to talk to: `$SLIPDOCK_URL`, else the one saved by
  `slipdock url` (or by `/install.sh`), else this machine's own tailnet
  address, else localhost.

  The saved file matters for agents. An agent is usually a long-lived session
  somewhere else — a cloud sandbox, a chat client, a cron — and nobody is there
  to export an environment variable into it, so the address has to be something
  the machine remembers. The env var still wins, for a one-off against another
  install.
  """
  def base_url do
    read_env("SLIPDOCK_URL", "KANBAN_URL") ||
      read_file(url_file()) ||
      tailscale_url() ||
      "http://localhost:4000"
  end

  defp url_file, do: config_path("slipdock", "url")

  @doc "Remember a server address. Returns the path written."
  def save_url(url) do
    path = url_file()
    write_private(path, String.trim_trailing(url, "/") <> "\n")
    path
  end

  @doc "Forget it, falling back to the tailnet address or localhost."
  def forget_url, do: File.rm(url_file())

  @doc "Where the address came from, for `slipdock url` to explain itself."
  def url_source do
    cond do
      read_env("SLIPDOCK_URL", "KANBAN_URL") -> "$SLIPDOCK_URL"
      read_file(url_file()) -> url_file()
      tailscale_url() -> "this machine's tailnet address"
      true -> "the default"
    end
  end

  defp tailscale_url do
    with exe when is_binary(exe) <- System.find_executable("tailscale"),
         {out, 0} <- System.cmd(exe, ["ip", "-4"], stderr_to_stdout: true),
         [ip | _] <- String.split(out, "\n", trim: true) do
      "http://#{ip}:4000"
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  # Functions, not module attributes: an attribute would freeze $HOME at the
  # moment the escript was *built*, so a binary built by one user and run by
  # another would read and write somebody else's token file.
  defp tokens_dir, do: config_path("slipdock", "tokens")

  # One token per server. A token is only ever sent to the server it was
  # issued by: pointing the CLI somewhere else — `slipdock url`, `--url`, or
  # another install's `install.sh` rewriting the url file — finds no token
  # there, rather than handing that server your write token.
  defp token_file(url), do: Path.join(tokens_dir(), origin_key(url))

  # The single file every token used to live in, still written alongside the
  # per-server one for the curl-based skills that read it.
  defp shared_token_file, do: config_path("slipdock", "token")

  # The CLI was called `kanban` until the rename; a token written by the old
  # one still signs you in, so nobody has to re-authenticate.
  defp legacy_token_file, do: config_path("kanban", "token")

  defp config_path(dir, name), do: Path.join([home(), ".config", dir, name])

  @doc """
  The home folder the config and the skills live under: `$HOME`, else
  `%USERPROFILE%`. Windows sets no HOME, and falling straight back to "."
  would scatter a token into whichever folder the command was run from.
  """
  def home do
    Enum.find_value(~w(HOME USERPROFILE), fn name ->
      case System.get_env(name) do
        nil -> nil
        "" -> nil
        dir -> dir
      end
    end) || System.user_home() || "."
  end

  @doc "scheme://host:port, the part of an address a token is bound to."
  def origin(url) do
    uri = URI.parse(url)
    "#{uri.scheme}://#{String.downcase(uri.host || "")}:#{uri.port}"
  end

  defp origin_key(url),
    do: url |> origin() |> String.replace(~r/[^A-Za-z0-9.\-]+/, "_")

  @doc """
  The API token: `$SLIPDOCK_TOKEN`, else the one saved by `slipdock auth` for
  the server being talked to. `$KANBAN_TOKEN` is still read.
  """
  def token do
    Process.get(:slipdock_token_override) ||
      read_env("SLIPDOCK_TOKEN", "KANBAN_TOKEN") ||
      (
        migrate_shared_token()
        read_file(token_file(base_url()))
      )
  end

  @doc """
  Runs `fun` with `token` in place of the API token: a deploy token
  (`slipdock deploy`) is sent to its own endpoints and never saved.
  """
  def with_token(token, fun) do
    previous = Process.put(:slipdock_token_override, token)

    try do
      fun.()
    after
      if previous,
        do: Process.put(:slipdock_token_override, previous),
        else: Process.delete(:slipdock_token_override)
    end
  end

  # Before tokens were kept per server there was one file, and it belonged to
  # whichever server the url file named. Bind it to that server, once; after
  # that the shared file is never read by the CLI.
  defp migrate_shared_token do
    with false <- File.dir?(tokens_dir()),
         token when is_binary(token) <-
           read_file(shared_token_file()) || read_file(legacy_token_file()) do
      owner = read_file(url_file()) || tailscale_url() || "http://localhost:4000"
      write_private(token_file(owner), token <> "\n")
    end
  end

  defp read_env(name, legacy) do
    case System.get_env(name) || System.get_env(legacy) do
      nil -> nil
      "" -> nil
      value -> String.trim(value)
    end
  end

  defp read_file(path) do
    if File.exists?(path), do: String.trim(File.read!(path)), else: nil
  end

  def save_token(token) do
    path = token_file(base_url())
    write_private(path, String.trim(token) <> "\n")
    write_private(shared_token_file(), String.trim(token) <> "\n")
    path
  end

  def forget_token do
    File.rm(token_file(base_url()))
    File.rm(shared_token_file())
  end

  @doc """
  Write a file only its owner can read, in a folder only its owner can
  change. The file is made 0600 before anything goes in it and renamed into
  place, so there is no moment when the token sits there at the umask's mode,
  and nobody else can swap the url or the token underneath us.
  """
  def write_private(path, content) do
    for dir <- Enum.uniq([Path.dirname(url_file()), Path.dirname(path)]) do
      File.mkdir_p!(dir)
      File.chmod!(dir, 0o700)
    end

    tmp = "#{path}.#{System.unique_integer([:positive])}.tmp"
    File.touch!(tmp)
    File.chmod!(tmp, 0o600)
    File.write!(tmp, content)
    File.rename!(tmp, path)
  end

  @doc """
  True when plain http to this address does not cross the open internet:
  loopback, the private ranges, Tailscale's 100.64/10 and its .ts.net names.
  """
  def local_host?(host) when is_binary(host) do
    host = host |> String.trim_leading("[") |> String.trim_trailing("]") |> String.downcase()

    cond do
      host in ["localhost", ""] -> true
      String.ends_with?(host, [".localhost", ".ts.net", ".local"]) -> true
      true -> private_ip?(:inet.parse_address(String.to_charlist(host)))
    end
  end

  def local_host?(_), do: false

  defp private_ip?({:ok, {127, _, _, _}}), do: true
  defp private_ip?({:ok, {10, _, _, _}}), do: true
  defp private_ip?({:ok, {172, b, _, _}}) when b in 16..31, do: true
  defp private_ip?({:ok, {192, 168, _, _}}), do: true
  defp private_ip?({:ok, {100, b, _, _}}) when b in 64..127, do: true
  defp private_ip?({:ok, {0, 0, 0, 0, 0, 0, 0, 1}}), do: true
  defp private_ip?({:ok, {a, _, _, _, _, _, _, _}}) when a in 0xFC00..0xFDFF, do: true
  defp private_ip?(_), do: false

  @doc "Plain http to somewhere that isn't local — a token sent there can be read on the way."
  def insecure?(url) do
    uri = URI.parse(url)
    uri.scheme == "http" and not local_host?(uri.host)
  end

  # Said once a run, on stderr, so it never ends up in piped output.
  defp warn_insecure(url) do
    if insecure?(url) and Process.get(:slipdock_warned) == nil do
      Process.put(:slipdock_warned, true)

      IO.puts(
        :stderr,
        "warning: sending your token to #{origin(url)} over plain http — anyone on the way can read it. Use https."
      )
    end
  end

  @doc """
  Which client this is, sent on every request. The server records it against
  wiki edits and card moves, so a history can tell a shell session from a web
  one. Run by an agent — under Claude Code (`CLAUDECODE`) or a runner job
  (`SLIPDOCK_JOB_ID`) — it says so too, with the job when there is one, so
  the agent's moves aren't filed as the person's whose token it borrows.
  """
  def client_headers do
    job = env("SLIPDOCK_JOB_ID")
    agent? = env("CLAUDECODE") != nil or job != nil

    [{~c"x-slipdock-client", ~c"cli"}] ++
      if(agent?, do: [{~c"x-slipdock-agent", ~c"1"}], else: []) ++
      if(job, do: [{~c"x-slipdock-job", String.to_charlist(job)}], else: [])
  end

  # Set and not blank, or nil.
  defp env(name) do
    case System.get_env(name) do
      nil -> nil
      value -> if String.trim(value) == "", do: nil, else: String.trim(value)
    end
  end

  def get(path, query \\ []), do: request(:get, path <> encode_query(query), nil)
  def post(path, body \\ %{}), do: request(:post, path, body)
  def patch(path, body), do: request(:patch, path, body)
  def put(path, body), do: request(:put, path, body)
  # A DELETE with a body is awkward across HTTP clients, so anything a delete
  # needs to say beyond the path goes in the query string.
  def delete(path, query \\ []), do: request(:delete, path <> encode_query(query), nil)

  @doc """
  A multipart POST: `fields` as `{name, value}`, `files` as `{name, filename,
  content_type, content}`, where `content` is the bytes or `{:path, path}`.
  A path is streamed from disk a megabyte at a time rather than read whole,
  so a 250 MB attachment or a long recording is never held in memory. It is
  given ten minutes rather than the usual fifteen seconds.
  """
  def post_multipart(path, fields, files) do
    boundary = "slipdock-" <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)

    parts =
      Enum.map(fields, fn {name, value} ->
        [
          "--",
          boundary,
          "\r\n",
          ~s(content-disposition: form-data; name="#{name}"\r\n\r\n),
          to_string(value),
          "\r\n"
        ]
      end) ++
        Enum.map(files, fn {name, filename, type, content} ->
          [
            "--",
            boundary,
            "\r\n",
            ~s(content-disposition: form-data; name="#{name}"; filename="#{filename}"\r\n),
            "content-type: #{type}\r\n\r\n",
            content,
            "\r\n"
          ]
        end)

    request(:post, path, {:multipart, boundary, segments([parts, "--", boundary, "--\r\n"])})
  end

  @doc """
  A GET whose body goes straight to `dest` rather than into memory: `:ok`,
  or the error a request would give. Ten minutes, as an upload gets.
  """
  def download(path, dest) do
    Application.ensure_all_started(:inets)
    Application.ensure_all_started(:ssl)
    url = String.to_charlist(base_url() <> "/api" <> path)

    headers =
      case token() do
        nil -> client_headers()
        t -> [{~c"authorization", String.to_charlist("Bearer " <> t)} | client_headers()]
      end

    case :httpc.request(:get, {url, headers}, [{:timeout, 600_000}],
           stream: String.to_charlist(dest),
           body_format: :binary
         ) do
      {:ok, :saved_to_file} ->
        :ok

      # Anything but a 200 is not streamed: it comes back as a body.
      {:ok, {{_, status, _}, _headers, body}} ->
        if status in 200..299,
          do: File.write!(dest, body),
          else: {:error, status, try_decode(body)}

      {:error, reason} ->
        {:error, :connect, reason}
    end
  end

  # The body as a list of binaries and `{:path, path}`s, neighbouring
  # binaries run together.
  defp segments(iodata) do
    iodata
    |> List.flatten()
    |> Enum.chunk_by(&match?({:path, _}, &1))
    |> Enum.flat_map(fn
      [{:path, _} | _] = paths -> paths
      binaries -> [IO.iodata_to_binary(binaries)]
    end)
  end

  # All bytes: send them as they are. Any file in it: stream, which
  # :httpc does from a {fun, acc} body once it is told the length.
  defp multipart_body([bytes]) when is_binary(bytes), do: {bytes, []}
  defp multipart_body([]), do: {"", []}

  defp multipart_body(segments) do
    length =
      Enum.reduce(segments, 0, fn
        {:path, path}, n -> n + File.stat!(path).size
        bytes, n -> n + byte_size(bytes)
      end)

    {{&stream_body/1, {segments, nil}},
     [{~c"content-length", String.to_charlist(Integer.to_string(length))}]}
  end

  defp stream_body({[], nil}), do: :eof
  defp stream_body({[bytes | rest], nil}) when is_binary(bytes), do: {:ok, bytes, {rest, nil}}

  defp stream_body({[{:path, path} | rest], nil}) do
    {:ok, device} = File.open(path, [:read, :binary])
    stream_body({rest, device})
  end

  defp stream_body({rest, device}) do
    case IO.binread(device, 1_048_576) do
      data when is_binary(data) ->
        {:ok, data, {rest, device}}

      _eof ->
        File.close(device)
        stream_body({rest, nil})
    end
  end

  defp request(method, path, body) do
    Application.ensure_all_started(:inets)
    Application.ensure_all_started(:ssl)
    url = String.to_charlist(base_url() <> "/api" <> path)
    headers = [{~c"accept", ~c"application/json"} | client_headers()]

    headers =
      case token() do
        nil ->
          headers

        t ->
          warn_insecure(base_url())
          [{~c"authorization", String.to_charlist("Bearer " <> t)} | headers]
      end

    {req, timeout} =
      case body do
        nil ->
          {{url, headers}, 15_000}

        {:multipart, boundary, segments} ->
          {body, length} = multipart_body(segments)

          {{url, length ++ headers,
            String.to_charlist("multipart/form-data; boundary=" <> boundary), body}, 600_000}

        body ->
          {{url, headers, ~c"application/json", encode(body)}, 15_000}
      end

    case :httpc.request(method, req, [{:timeout, timeout}], body_format: :binary) do
      {:ok, {{_, status, _}, _headers, resp_body}} ->
        decoded =
          case resp_body do
            "" -> %{}
            b -> try_decode(b)
          end

        if status in 200..299, do: {:ok, decoded}, else: {:error, status, decoded}

      {:error, reason} ->
        {:error, :connect, reason}
    end
  end

  # OTP's :json maps JSON null to the atom :null; we want Elixir's nil.
  defp try_decode(b) do
    {value, _acc, ""} = :json.decode(b, :ok, %{null: nil})
    value
  rescue
    _ -> %{"raw" => b}
  end

  # ...and encodes the atom nil as the string "nil", so translate on the way out.
  def encode(term) do
    term
    |> :json.encode(fn
      nil, _enc -> "null"
      other, enc -> :json.encode_value(other, enc)
    end)
    |> IO.iodata_to_binary()
  end

  # Options left unset are left out, and a query with nothing left in it is
  # no query at all rather than a stray "?".
  def encode_query(query) do
    case Enum.reject(query, fn {_, v} -> is_nil(v) end) do
      [] ->
        ""

      set ->
        "?" <>
          Enum.map_join(set, "&", fn {k, v} ->
            "#{URI.encode_www_form(to_string(k))}=#{URI.encode_www_form(to_string(v))}"
          end)
    end
  end

  def seg(value), do: URI.encode(to_string(value), &URI.char_unreserved?/1)
end
