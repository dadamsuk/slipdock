defmodule Slipdock.GoogleStub do
  @moduledoc """
  Google, for tests: `Slipdock.Google` and `Slipdock.Google.Drive` talk to a
  `Req.Test` stub (see config/test.exs), never to Google. `stub/1` answers
  with a function of the conn; `connect!/2` gives a user a connection
  without the OAuth dance.
  """
  alias Slipdock.Google
  alias Slipdock.Google.Connection
  alias Slipdock.Repo

  @doc "Answers every request to Google with `fun.(conn)`."
  def stub(fun), do: Req.Test.stub(Slipdock.Google, fun)

  @doc """
  A connection for `user`, its access token good for an hour unless
  `expires_in:` (seconds, negative for already expired) says otherwise.
  """
  def connect!(user, opts \\ []) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.insert!(%Connection{
      user_id: user.id,
      email: Keyword.get(opts, :email, "someone@example.com"),
      refresh_token: Google.encrypt(Keyword.get(opts, :refresh_token, "refresh-1")),
      access_token: Google.encrypt(Keyword.get(opts, :access_token, "access-1")),
      access_expires_at: DateTime.add(now, Keyword.get(opts, :expires_in, 3600)),
      revoked_at: if(opts[:revoked], do: now)
    })
  end

  @doc "The request body Google was sent, decoded from its form."
  def form(conn) do
    {:ok, body, _conn} = Plug.Conn.read_body(conn)
    URI.decode_query(body)
  end

  @doc """
  A small Drive to answer from: `files` is a list of maps with `"id"`,
  `"name"`, `"mimeType"`, `"parents"` and, for a file, `"size"` and
  `:content` (its bytes, served with `alt=media`, ranges and all). Each
  request is sent to the test process as `{:drive, method, path, params}`, so
  a test can count them.
  """
  def drive!(files) do
    test = self()
    by_id = Map.new(files, &{&1["id"], &1})

    stub(fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      send(test, {:drive, conn.method, conn.request_path, conn.query_params})

      case conn.request_path do
        "/drive/v3/files" ->
          {name, parent} = parse_q(conn.query_params["q"])

          found =
            files
            |> Enum.filter(&(&1["name"] == name and parent in (&1["parents"] || [])))
            |> Enum.map(&Map.delete(&1, :content))

          Req.Test.json(conn, %{"files" => found})

        "/drive/v3/files/" <> id ->
          case {by_id[id], conn.query_params["alt"]} do
            {nil, _} ->
              conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"error" => %{"code" => 404}})

            {file, "media"} ->
              media(conn, file)

            {file, _} ->
              Req.Test.json(conn, Map.delete(file, :content))
          end
      end
    end)
  end

  defp parse_q(q) do
    [_, name, parent] = Regex.run(~r/^name = '((?:[^'\\]|\\.)*)' and '([^']*)' in parents/, q)
    {String.replace(name, ~r/\\(.)/, "\\1"), parent}
  end

  defp media(conn, file) do
    content = file[:content] || ""
    size = byte_size(content)

    conn = Plug.Conn.put_resp_content_type(conn, file["mimeType"], nil)

    case Plug.Conn.get_req_header(conn, "range") do
      ["bytes=" <> spec] ->
        [from, to] = String.split(spec, "-")
        first = String.to_integer(from)
        last = if to == "", do: size - 1, else: min(String.to_integer(to), size - 1)

        conn
        |> Plug.Conn.put_resp_header("content-range", "bytes #{first}-#{last}/#{size}")
        |> Plug.Conn.put_resp_header("accept-ranges", "bytes")
        |> Plug.Conn.send_resp(206, binary_part(content, first, last - first + 1))

      _ ->
        conn
        |> Plug.Conn.put_resp_header("accept-ranges", "bytes")
        |> Plug.Conn.send_resp(200, content)
    end
  end
end
