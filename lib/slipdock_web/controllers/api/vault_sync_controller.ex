defmodule SlipdockWeb.API.VaultSyncController do
  @moduledoc """
  The server half of `slipdock sync` over HTTP (see `Slipdock.Vaults.Sync`):
  a vault as a folder of files, listed with their hashes, and read, written
  and archived one file at a time. Every write names the hash it was made
  against; a 409 carries the file as it now stands.
  """
  use SlipdockWeb, :controller

  alias Slipdock.Vaults
  alias Slipdock.Vaults.Sync

  action_fallback SlipdockWeb.API.FallbackController

  @doc "Every file in the vault, with its path and hash, and the feed cursor to follow from."
  def index(conn, %{"id" => ref}) do
    with {:ok, vault} <- Vaults.get_vault(user(conn), ref) do
      json(conn, Sync.listing(vault, user(conn), opts(conn)))
    end
  end

  @doc "One page's file, as sync writes it."
  def show_page(conn, %{"id" => ref, "page" => id}) do
    with {:ok, vault} <- Vaults.get_vault(user(conn), ref),
         {:ok, entry} <- Sync.read_page(vault, user(conn), id, opts(conn)) do
      json(conn, %{page: entry})
    end
  end

  @doc """
  Writes a Markdown file: `path` and `content`, plus `base` (the hash the
  edit was made against) for a page the client knows — `PUT
  /sync/pages/:page` — or neither for a new one, `PUT /sync/pages`.
  """
  def put_page(conn, %{"id" => ref} = params) do
    with {:ok, vault} <- Vaults.get_vault(user(conn), ref),
         {:ok, entry} <-
           Sync.write_page(
             vault,
             user(conn),
             Map.take(params, ["path", "content", "base"]) |> Map.put("id", params["page"]),
             opts(conn)
           ) do
      json(conn, %{page: entry})
    end
  end

  @doc "Archives a page whose file was deleted. `?base=` guards an edit made elsewhere."
  def delete_page(conn, %{"id" => ref, "page" => id} = params) do
    with {:ok, vault} <- Vaults.get_vault(user(conn), ref),
         {:ok, entry} <- Sync.archive_page(vault, user(conn), id, params["base"], opts(conn)) do
      json(conn, %{page: entry})
    end
  end

  defp opts(conn), do: [token: conn.assigns[:api_token]]

  defp user(conn), do: conn.assigns.current_user
end
