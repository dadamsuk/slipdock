defmodule SlipdockCLI.HTTP do
  @moduledoc "Tiny JSON client over OTP's :httpc. No dependencies."

  def base_url do
    read_env("SLIPDOCK_URL", "KANBAN_URL") || tailscale_url() || "http://localhost:4000"
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

  @token_file Path.join([System.get_env("HOME") || ".", ".config", "slipdock", "token"])
  # The CLI was called `kanban` until the rename; a token written by the old
  # one still signs you in, so nobody has to re-authenticate.
  @legacy_token_file Path.join([System.get_env("HOME") || ".", ".config", "kanban", "token"])

  @doc """
  The API token: `$SLIPDOCK_TOKEN`, else `~/.config/slipdock/token` (written by
  `slipdock auth`). The pre-rename `$KANBAN_TOKEN` and `~/.config/kanban/token`
  are still read if the new ones are not there.
  """
  def token do
    read_env("SLIPDOCK_TOKEN", "KANBAN_TOKEN") ||
      read_file(@token_file) ||
      read_file(@legacy_token_file)
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
    File.mkdir_p!(Path.dirname(@token_file))
    File.write!(@token_file, String.trim(token) <> "\n")
    File.chmod!(@token_file, 0o600)
    @token_file
  end

  def forget_token, do: File.rm(@token_file)

  def get(path, query \\ []), do: request(:get, path <> encode_query(query), nil)
  def post(path, body \\ %{}), do: request(:post, path, body)
  def patch(path, body), do: request(:patch, path, body)
  def put(path, body), do: request(:put, path, body)
  # A DELETE with a body is awkward across HTTP clients, so anything a delete
  # needs to say beyond the path goes in the query string.
  def delete(path, query \\ []), do: request(:delete, path <> encode_query(query), nil)

  defp request(method, path, body) do
    Application.ensure_all_started(:inets)
    Application.ensure_all_started(:ssl)
    url = String.to_charlist(base_url() <> "/api" <> path)
    # Say which client this is. The server records it against wiki edits, so a
    # page's history can tell a shell session from a web one.
    headers = [{~c"accept", ~c"application/json"}, {~c"x-slipdock-client", ~c"cli"}]

    headers =
      case token() do
        nil -> headers
        t -> [{~c"authorization", String.to_charlist("Bearer " <> t)} | headers]
      end

    req =
      case body do
        nil -> {url, headers}
        body -> {url, headers, ~c"application/json", encode(body)}
      end

    case :httpc.request(method, req, [{:timeout, 15_000}], body_format: :binary) do
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

  def encode_query([]), do: ""

  def encode_query(query) do
    "?" <>
      (query
       |> Enum.reject(fn {_, v} -> is_nil(v) end)
       |> Enum.map(fn {k, v} -> "#{k}=#{URI.encode_www_form(to_string(v))}" end)
       |> Enum.join("&"))
  end

  def seg(value), do: URI.encode(to_string(value), &URI.char_unreserved?/1)
end
