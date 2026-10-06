defmodule Slipdock.OAuth do
  @moduledoc """
  The authorization-server half of signing in from a third-party app (OAuth
  2.1): the clients that have registered themselves, and — with #331 — the
  codes and tokens they are given. What it hands out in the end is an ordinary
  API token, so everything that already guards one guards these.

  The decisions behind it (which RFCs, which redirect URIs, why there is no
  client secret) are on the wiki page W-21.
  """
  import Ecto.Query, warn: false

  alias Slipdock.OAuth.Client
  alias Slipdock.Repo

  @doc """
  Registers a client (RFC 7591). `attrs` takes `client_name`, `redirect_uris`
  and `registered_ip`; anything else a client sent has already been decided by
  the server and is not stored.
  """
  def register_client(attrs) do
    attrs |> Client.registration_changeset() |> Repo.insert()
  end

  @doc "The client with this `client_id`, or nil."
  def get_client(client_id) when is_binary(client_id),
    do: Repo.get_by(Client, client_id: client_id)

  def get_client(_), do: nil
end
