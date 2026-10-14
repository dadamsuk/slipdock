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

  @doc """
  Makes a vault: `name`. With `with_board`, a board named after it comes
  too, mapped at `/` and kept inside the vault (#757).
  """
  def create(conn, params) do
    attrs = Map.take(params, ["name"])

    result =
      if truthy?(params["with_board"]),
        do: Vaults.create_vault_with_board(user(conn), attrs),
        else: Vaults.create_vault(user(conn), attrs)

    case result do
      {:ok, vault} ->
        conn |> put_status(:created) |> json(%{vault: V.vault(vault)})

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, changeset}

      {:error, reason} ->
        {:error, :unprocessable_entity, "that vault couldn't be made: #{inspect(reason)}"}
    end
  end

  def show(conn, %{"id" => ref}) do
    with {:ok, vault} <- Vaults.get_vault(user(conn), ref) do
      json(conn, %{vault: V.vault(vault)})
    end
  end

  def update(conn, %{"id" => ref} = params) do
    with {:ok, vault} <- Vaults.get_vault(user(conn), ref),
         {:ok, vault} <- rename(vault, params),
         {:ok, vault} <- recordings_folder(vault, params) do
      json(conn, %{vault: V.vault(vault)})
    end
  end

  defp rename(vault, params) when is_map_key(params, "name"),
    do: Vaults.update_vault(vault, Map.take(params, ["name"]))

  defp rename(vault, _params), do: {:ok, vault}

  # The folder on the owner's Google Drive its meeting recordings are in
  # (W-1690); "" or null clears it. Saving checks it is a folder there.
  defp recordings_folder(vault, %{"recordings_folder" => folder}) do
    case Vaults.set_recordings_folder(vault, folder) do
      {:ok, vault} ->
        {:ok, vault}

      {:error, :not_connected} ->
        {:error, :conflict, "connect Google Drive first (Account → Settings)"}

      {:error, :revoked} ->
        {:error, :conflict, "Google no longer accepts your Drive connection: connect it again"}

      {:error, :invalid} ->
        {:error, :unprocessable_entity, "recordings_folder is not a folder path"}

      {:error, :not_found} ->
        {:error, :unprocessable_entity, "there is no folder #{inspect(folder)} in your My Drive"}

      {:error, _} ->
        {:error, :conflict, "Google Drive could not be asked just now; try again"}
    end
  end

  defp recordings_folder(vault, _params), do: {:ok, vault}

  def delete(conn, %{"id" => ref}) do
    with {:ok, vault} <- Vaults.get_vault(user(conn), ref),
         # Rendered first, so the reply still counts what it held.
         deleted = V.vault(vault),
         {:ok, _} <- Vaults.delete_vault(vault) do
      json(conn, %{deleted: deleted})
    end
  end

  @doc """
  Maps a vault path onto a board's wiki: `path` (default `/`), `board` (id,
  code or name; you must be able to write to it) and optionally `folder` (a
  folder on that board, by id, slug, name or path). With `dry_run`, only
  says what the mapping would bring in and take over (`Vaults.preview_mapping/3`).
  """
  def map(conn, %{"id" => ref} = params) do
    if dry_run?(params), do: preview_map(conn, ref, params), else: do_map(conn, ref, params)
  end

  # `dry_run`: what the mapping would bring into the vault, and take over
  # from the mappings already there, without making it.
  defp preview_map(conn, ref, params) do
    with {:ok, vault} <- Vaults.get_vault(user(conn), ref),
         {:ok, board} <- Authorize.fetch_board(conn, params["board"], :write),
         {:ok, folder} <- folder(board, params["folder"]),
         {:ok, preview} <-
           Vaults.preview_mapping(vault, user(conn), %{
             path: params["path"],
             board: board,
             folder: folder
           }) do
      json(conn, %{dry_run: true, preview: preview})
    end
  end

  defp do_map(conn, ref, params) do
    with {:ok, vault} <- Vaults.get_vault(user(conn), ref),
         {:ok, board} <- Authorize.fetch_board(conn, params["board"], :write),
         {:ok, folder} <- folder(board, params["folder"]),
         {:ok, _mapping} <-
           Vaults.add_mapping(vault, user(conn), %{
             path: params["path"],
             board: board,
             folder: folder,
             inside: truthy?(params["inside"])
           }),
         {:ok, vault} <- Vaults.get_vault(user(conn), vault.id) do
      conn |> put_status(:created) |> json(%{vault: V.vault(vault)})
    end
  end

  @doc """
  Gives the folder at vault `path` its own board: what is in it moves to
  `board` (id, code or name; one you can write to) — or to a board made for
  it, `new_board` naming it — and `path` is mapped onto that board, in one
  step. The notes keep their vault paths. `dry_run` reports it all
  (`Slipdock.Vaults.Split`) and changes nothing.
  """
  def split(conn, %{"id" => ref} = params) do
    with {:ok, vault} <- Vaults.get_vault(user(conn), ref),
         {:ok, target} <- split_target(conn, params) do
      if dry_run?(params) do
        with {:ok, preview} <- Vaults.Split.preview(vault, user(conn), params["path"], target),
             do: json(conn, %{dry_run: true, preview: preview})
      else
        with {:ok, result} <- Vaults.Split.run(vault, user(conn), params["path"], target),
             {:ok, vault} <- Vaults.get_vault(user(conn), vault.id) do
          {board, result} = Map.pop(result, :board)

          json(conn, %{
            result: result,
            board: %{id: board.id, code: board.code, name: board.name},
            vault: V.vault(vault)
          })
        end
      end
    end
  end

  defp split_target(_conn, %{"new_board" => name}) when is_binary(name) and name != "",
    do: {:ok, {:new, name}}

  defp split_target(conn, %{"board" => ref}) when is_binary(ref) and ref != "",
    do: Authorize.fetch_board(conn, ref, :write)

  defp split_target(_conn, _params),
    do: {:error, :bad_request, "say which board: board, or new_board to make one"}

  defp folder(_board, ref) when ref in [nil, ""], do: {:ok, nil}
  defp folder(board, ref), do: Wiki.find_folder(board, ref)

  @doc """
  Takes a mapping out, by its id (`/mappings/12`) or its path (`?path=/Projects`).
  With `dry_run`, only says which pages would leave the vault and which
  would move to another path.
  """
  def unmap(conn, %{"id" => ref} = params) do
    mapping = params["mapping"] || params["path"]

    with {:ok, vault} <- Vaults.get_vault(user(conn), ref),
         :ok <- present(mapping) do
      if dry_run?(params) do
        with {:ok, preview} <- Vaults.preview_unmapping(vault, mapping),
             do: json(conn, %{dry_run: true, preview: preview})
      else
        with {:ok, _} <- Vaults.remove_mapping(vault, mapping),
             {:ok, vault} <- Vaults.get_vault(user(conn), vault.id),
             do: json(conn, %{vault: V.vault(vault)})
      end
    end
  end

  @doc """
  Changes a mapping, by its id (`/mappings/12`) or its path (`?path=/`):
  `inside` keeps a board mapped whole inside the vault, named on its tile
  rather than among the owner's boards, or (false) lets it out (#757).
  """
  def update_mapping(conn, %{"id" => ref} = params) do
    mapping = params["mapping"] || params["path"]

    with {:ok, vault} <- Vaults.get_vault(user(conn), ref),
         :ok <- present(mapping),
         :ok <- given(params, "inside"),
         {:ok, _} <- Vaults.set_inside(vault, mapping, truthy?(params["inside"])),
         {:ok, vault} <- Vaults.get_vault(user(conn), vault.id) do
      json(conn, %{vault: V.vault(vault)})
    end
  end

  defp given(params, key) do
    if Map.has_key?(params, key),
      do: :ok,
      else: {:error, :bad_request, "say what to change: inside (true or false)"}
  end

  defp truthy?(value), do: value in [true, "true", "1", "yes"]

  defp dry_run?(params), do: params["dry_run"] in [true, "true", "1"]

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
      Vaults.touch_mirror(vault, conn.assigns[:api_token])

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
