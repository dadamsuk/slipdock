defmodule SlipdockWeb.Plugs.OwnWiki do
  @moduledoc """
  The `/api/wiki/...` routes (W-2201): each person has one wiki, so its
  address names none. This puts the caller's own in `params["id"]`, which
  the actions behind `/api/vaults/:id/...` read, so both addresses answer
  the same; and `:own_wiki` in the assigns, so a reply can speak of a wiki
  rather than a vault. Their Knowledge Base is made the first time it is
  wanted. A caller with no user is left to the action, which refuses.
  """
  import Plug.Conn

  alias Slipdock.Accounts.User

  def init(opts), do: opts

  def call(%Plug.Conn{assigns: %{current_user: %User{} = user}} = conn, _opts) do
    {:ok, _} = Slipdock.Wiki.KnowledgeBase.ensure(user)
    id = to_string(Slipdock.Vaults.root(user).id)

    %{conn | params: Map.put(conn.params, "id", id), path_params: Map.put(conn.path_params, "id", id)}
    |> assign(:own_wiki, true)
  end

  def call(conn, _opts), do: conn
end
