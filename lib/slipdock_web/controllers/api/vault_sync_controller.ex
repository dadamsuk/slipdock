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
  alias Slipdock.Wiki.Files

  action_fallback SlipdockWeb.API.FallbackController

  @doc "Every file in the vault, with its path and hash, and the feed cursor to follow from."
  def index(conn, %{"id" => ref}) do
    with {:ok, vault} <- Vaults.get_vault(user(conn), ref) do
      Vaults.touch_mirror(vault, conn.assigns[:api_token])
      # `stubs=1`: a client that writes stubs of what is shared with the
      # reader (#819). One from before them would take them for pages.
      stubs = conn.params["stubs"] in ["1", "true"]

      listing =
        Sync.listing(
          vault,
          user(conn),
          opts(conn) ++ [stubs: stubs, base_url: SlipdockWeb.BaseURL.from_conn(conn)]
        )

      json(conn, listing)
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

  @doc "A file's bytes, streamed from disk, with its hash in `x-slipdock-hash`."
  def show_file(conn, %{"id" => ref, "file" => id}) do
    with {:ok, vault} <- Vaults.get_vault(user(conn), ref),
         {:ok, file, entry} <- Sync.read_file(vault, user(conn), id, opts(conn)) do
      conn
      |> put_resp_header("x-slipdock-hash", entry.hash)
      |> put_resp_header("x-slipdock-path", URI.encode(entry.path))
      |> put_resp_header("x-content-type-options", "nosniff")
      |> send_download({:file, Files.disk_path(file)},
        filename: file.name,
        content_type: "application/octet-stream"
      )
    end
  end

  @doc """
  Stores a file: multipart `file`, `path`, and `base` for one the client
  knows (`POST /sync/files/:file`), or neither for a new one (`POST
  /sync/files`). Up to the 250 MB attachments take.
  """
  def post_file(conn, %{"id" => ref} = params) do
    with {:ok, vault} <- Vaults.get_vault(user(conn), ref),
         {:ok, source} <- upload(params["file"]),
         {:ok, entry} <-
           Sync.write_file(
             vault,
             user(conn),
             Map.take(params, ["path", "base"]) |> Map.put("id", params["file_id"]),
             source,
             opts(conn)
           ) do
      json(conn, %{file: entry})
    end
  end

  @doc "Renames or moves a file: `path`, `base`."
  def patch_file(conn, %{"id" => ref, "file_id" => id} = params) do
    with {:ok, vault} <- Vaults.get_vault(user(conn), ref),
         {:ok, entry} <-
           Sync.move_file(vault, user(conn), id, Map.take(params, ["path", "base"]), opts(conn)) do
      json(conn, %{file: entry})
    end
  end

  @doc "Archives a file whose copy was deleted. `?base=` guards a change made elsewhere."
  def delete_file(conn, %{"id" => ref, "file_id" => id} = params) do
    with {:ok, vault} <- Vaults.get_vault(user(conn), ref),
         {:ok, entry} <- Sync.archive_file(vault, user(conn), id, params["base"], opts(conn)) do
      json(conn, %{file: entry})
    end
  end

  defp upload(%Plug.Upload{path: path}), do: {:ok, path}
  defp upload(_), do: {:error, :bad_request, "send the file as multipart `file`"}

  defp opts(conn), do: [token: conn.assigns[:api_token]]

  defp user(conn), do: conn.assigns.current_user
end
