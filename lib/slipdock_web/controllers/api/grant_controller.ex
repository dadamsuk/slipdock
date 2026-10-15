defmodule SlipdockWeb.API.GrantController do
  @moduledoc """
  Sharing wiki pages and folders over HTTP (#820), and what has been shared
  with you:

    * `GET /api/pages/:id/grants`, `/api/folders/:id/grants` — who has it;
    * `POST` the same — share it: `email` or `group` (an id or a name of a
      group of yours), and `level` `read` or `write`. Again with the same
      person changes the level. An address nobody uses gets an invitation;
    * `DELETE` the same with `email` or `group` — take it back;
    * `GET /api/shared` — the Shared with me tree, grouped by owner.

  Only a writer on the item's board shares it. Somebody it was shared with
  is answered `403 {"error": "shared_no_reshare"}`; see
  `Slipdock.Wiki.Sharing`.
  """
  use SlipdockWeb, :controller

  alias Slipdock.Access.Grant
  alias Slipdock.Wiki
  alias Slipdock.Wiki.{Folder, Page, SharedTree, Sharing}

  action_fallback SlipdockWeb.API.FallbackController

  def index(conn, params) do
    with {:ok, item} <- item(conn, params),
         {:ok, grants} <- Sharing.grants(user(conn), item) do
      json(conn, %{grants: Enum.map(grants, &grant/1)})
    end
  end

  def create(conn, params) do
    with {:ok, item} <- item(conn, params),
         {:ok, grant} <- Sharing.share(user(conn), item, who(params), params["level"] || "read") do
      conn |> put_status(:created) |> json(%{grant: grant(grant)})
    end
  end

  def delete(conn, params) do
    with {:ok, item} <- item(conn, params),
         {:ok, _} <- Sharing.unshare(user(conn), item, who(params)) do
      json(conn, %{revoked: true})
    end
  end

  @doc "What has been shared with the caller (see `Slipdock.Wiki.SharedTree`)."
  def shared(conn, _params) do
    json(conn, %{shared: SlipdockWeb.API.SharedJSON.tree(SharedTree.for_user(user(conn)))})
  end

  # The page or folder named: a page by id or code, a folder by id. One the
  # caller can't see at all is not found, as anywhere else.
  defp item(conn, %{"page_id" => ref}) do
    case Wiki.find_page(ref, as: user(conn)) do
      {:ok, %Page{} = page} -> visible(conn, page)
      _ -> {:error, :not_found, "page #{inspect(ref)}"}
    end
  end

  defp item(conn, %{"folder_id" => ref}) do
    with {id, ""} <- Integer.parse(to_string(ref)),
         %Folder{} = folder <- Wiki.get_folder(id) do
      visible(conn, folder)
    else
      _ -> {:error, :not_found, "folder #{inspect(ref)}"}
    end
  end

  defp visible(conn, item) do
    level =
      case item do
        %Page{} -> Slipdock.Access.page_permission(user(conn), item)
        %Folder{} -> Slipdock.Access.folder_permission(user(conn), item)
      end

    {level, why} = Slipdock.Access.narrow(level, conn.assigns[:api_token], item.board_id)

    cond do
      why == :scope -> {:error, :forbidden, "this API token's scope doesn't reach it"}
      Slipdock.Access.can_read?(level) -> {:ok, item}
      true -> {:error, :not_found, "#{kind(item)} #{item.id}"}
    end
  end

  defp kind(%Page{}), do: "page"
  defp kind(%Folder{}), do: "folder"

  defp who(params), do: Map.take(params, ["email", "group"])

  defp grant(%Grant{} = g) do
    %{
      id: g.id,
      level: g.level,
      user: g.user && person(g.user),
      group: g.group && %{id: g.group.id, name: g.group.name},
      granted_by: g.granted_by && person(g.granted_by),
      inserted_at: g.inserted_at
    }
  end

  defp person(user), do: SlipdockWeb.API.SharedJSON.person(user)

  defp user(conn), do: conn.assigns.current_user
end
