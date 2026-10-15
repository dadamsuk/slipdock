defmodule SlipdockWeb.API.PasskeyController do
  @moduledoc """
  The token owner's own passkeys (#828): which there are, and removing one —
  what to do from a terminal when a phone is lost. Adding one needs the
  authenticator, so it is only possible in a browser, on the account page.

  Only ever the caller's: no route here takes a person.
  """
  use SlipdockWeb, :controller

  alias Slipdock.Accounts.Passkeys

  action_fallback SlipdockWeb.API.FallbackController

  @doc "The caller's passkeys, oldest first."
  def index(conn, _params) do
    passkeys = conn.assigns.current_user |> Passkeys.list() |> Enum.map(&entry/1)
    json(conn, %{passkeys: passkeys})
  end

  @doc "Removes one. Somebody else's id is a 404, like one that does not exist."
  def delete(conn, %{"id" => id}) do
    with id when is_integer(id) <- SlipdockWeb.Params.id(id) || {:error, :not_found},
         :ok <- Passkeys.delete(conn.assigns.current_user, id) do
      index(conn, %{})
    end
  end

  defp entry(p) do
    %{id: p.id, name: p.name, created_at: p.inserted_at, last_used_at: p.last_used_at}
  end
end
