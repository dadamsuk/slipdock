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
end
