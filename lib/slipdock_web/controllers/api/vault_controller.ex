defmodule SlipdockWeb.API.VaultController do
  @moduledoc """
  Vaults over HTTP (see `Slipdock.Vaults`): making them, naming them, and
  mapping vault paths onto board wikis.

  A vault is its owner's alone, so every action looks it up among the
  caller's own; somebody else's is a 404, the same as one that does not
  exist. `:id` takes the vault's id or its name.
  """
  use SlipdockWeb, :controller

  alias Slipdock.{Vaults, Wiki}
  alias SlipdockWeb.API.Authorize
  alias SlipdockWeb.API.JSON, as: V

  action_fallback SlipdockWeb.API.FallbackController

  def index(conn, _params) do
    json(conn, %{vaults: conn |> user() |> Vaults.list_vaults() |> Enum.map(&V.vault/1)})
  end

  def create(conn, params) do
    with {:ok, vault} <- Vaults.create_vault(user(conn), Map.take(params, ["name"])) do
      conn |> put_status(:created) |> json(%{vault: V.vault(vault)})
    end
  end

  def show(conn, %{"id" => ref}) do
    with {:ok, vault} <- Vaults.get_vault(user(conn), ref) do
      json(conn, %{vault: V.vault(vault)})
    end
  end

  def update(conn, %{"id" => ref} = params) do
    with {:ok, vault} <- Vaults.get_vault(user(conn), ref),
         {:ok, vault} <- Vaults.update_vault(vault, Map.take(params, ["name"])) do
      json(conn, %{vault: V.vault(vault)})
    end
  end

  def delete(conn, %{"id" => ref}) do
    with {:ok, vault} <- Vaults.get_vault(user(conn), ref),
         {:ok, _} <- Vaults.delete_vault(vault) do
      json(conn, %{deleted: V.vault(vault)})
    end
  end

  @doc """
  Maps a vault path onto a board's wiki: `path` (default `/`), `board` (id,
  code or name; you must be able to write to it) and optionally `folder` (a
  folder on that board, by id, slug, name or path).
  """
  def map(conn, %{"id" => ref} = params) do
    with {:ok, vault} <- Vaults.get_vault(user(conn), ref),
         {:ok, board} <- Authorize.fetch_board(conn, params["board"], :write),
         {:ok, folder} <- folder(board, params["folder"]),
         {:ok, _mapping} <-
           Vaults.add_mapping(vault, user(conn), %{
             path: params["path"],
             board: board,
             folder: folder
           }),
         {:ok, vault} <- Vaults.get_vault(user(conn), vault.id) do
      conn |> put_status(:created) |> json(%{vault: V.vault(vault)})
    end
  end

  defp folder(_board, ref) when ref in [nil, ""], do: {:ok, nil}
  defp folder(board, ref), do: Wiki.find_folder(board, ref)

  @doc "Takes a mapping out, by its id (`/mappings/12`) or its path (`?path=/Jobs`)."
  def unmap(conn, %{"id" => ref} = params) do
    mapping = params["mapping"] || params["path"]

    with {:ok, vault} <- Vaults.get_vault(user(conn), ref),
         :ok <- present(mapping),
         {:ok, _} <- Vaults.remove_mapping(vault, mapping),
         {:ok, vault} <- Vaults.get_vault(user(conn), vault.id) do
      json(conn, %{vault: V.vault(vault)})
    end
  end

  defp present(ref) when ref in [nil, ""],
    do: {:error, :bad_request, "say which one: a mapping's id or ?path=, or a ?link="}

  defp present(_ref), do: :ok

  @doc """
  Where a vault path lands: the mapping that holds it (longest prefix wins)
  and the rest of the path below that mapping.
  """
  def locate(conn, %{"id" => ref} = params) do
    with {:ok, vault} <- Vaults.get_vault(user(conn), ref),
         {:ok, mapping, rest} <- Vaults.locate(vault, params["path"] || "") do
      json(conn, %{mapping: V.vault_mapping(mapping), rest: rest})
    end
  end

  @doc """
  The page a link's words name in the vault — `?link=Note` or
  `?link=Folder/Note` — as a `[[link]]` on one of its boards finds it once
  its own board has nothing: by name, the shortest vault path winning.
  """
  def resolve(conn, %{"id" => ref} = params) do
    with {:ok, vault} <- Vaults.get_vault(user(conn), ref),
         :ok <- present(params["link"]),
         {:ok, page, path} <- Vaults.resolve_link(vault, params["link"], user(conn)) do
      json(conn, %{page: V.page_summary(page), path: "/" <> path})
    end
  end

  @doc "Pages linked to but never written, across every board in the vault."
  def wanted(conn, %{"id" => ref}) do
    with {:ok, vault} <- Vaults.get_vault(user(conn), ref) do
      json(conn, %{wanted: vault |> Vaults.wanted(user(conn)) |> Enum.map(&V.wanted/1)})
    end
  end

  @doc """
  What changed in the vault after `?since=` (a cursor): pages, folders and
  attachments on every board of it, each once, as they are now. Without
  `since`, just the cursor to start following from. `limit` (default 500,
  at most 1000); `more: true` means ask again at once. A websocket on
  `/socket` (channel `vault:<id>`) says when to ask.
  """
  def changes(conn, %{"id" => ref} = params) do
    with {:ok, vault} <- Vaults.get_vault(user(conn), ref),
         {:ok, since} <- cursor(params["since"]),
         {:ok, limit} <- cursor(params["limit"]) do
      json(
        conn,
        Slipdock.Wiki.Changes.since(vault, since, user(conn),
          limit: limit || 500,
          token: conn.assigns[:api_token]
        )
      )
    end
  end

  defp cursor(nil), do: {:ok, nil}
  defp cursor(""), do: {:ok, nil}

  defp cursor(value) do
    case Integer.parse(to_string(value)) do
      {n, ""} when n >= 0 -> {:ok, n}
      _ -> {:error, :bad_request, "since and limit are whole numbers"}
    end
  end

  defp user(conn), do: conn.assigns.current_user
end
