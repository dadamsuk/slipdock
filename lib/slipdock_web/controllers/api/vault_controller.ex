defmodule SlipdockWeb.API.VaultController do
  @moduledoc """
  The caller's vault over HTTP (see `Slipdock.Vaults`): reading it, naming it,
  and finding things in it.

  A vault is its owner's alone, so every action looks it up among the
  caller's own; somebody else's is a 404, the same as one that does not
  exist. `:id` takes the vault's id or its name.
  """
  use SlipdockWeb, :controller

  alias Slipdock.Vaults
  alias SlipdockWeb.API.JSON, as: V

  action_fallback SlipdockWeb.API.FallbackController

  def index(conn, _params) do
    json(conn, %{
      vaults: conn |> user() |> Vaults.list_vaults() |> Enum.map(&V.vault(&1, user(conn)))
    })
  end

  def show(conn, %{"id" => ref}) do
    with {:ok, vault} <- Vaults.get_vault(user(conn), ref) do
      json(conn, %{vault: V.vault(vault, user(conn))})
    end
  end

  def update(conn, %{"id" => ref} = params) do
    with {:ok, vault} <- Vaults.get_vault(user(conn), ref),
         {:ok, _} <- hotkey_digit(params),
         {:ok, vault} <- rename(vault, params),
         {:ok, vault} <- shortcut(vault, params),
         {:ok, _} <- hotkey(conn, vault, params),
         {:ok, vault} <- recordings_folder(vault, params) do
      json(conn, described(conn, vault))
    end
  end

  # `/api/wiki` speaks of the caller's wiki; `/api/vaults/:id` as it did.
  defp described(%{assigns: %{own_wiki: true}} = conn, vault),
    do: %{wiki: V.wiki(vault, user(conn))}

  defp described(conn, vault), do: %{vault: V.vault(vault, user(conn))}

  defp rename(vault, params) when is_map_key(params, "name"),
    do: Vaults.update_vault(vault, Map.take(params, ["name"]))

  defp rename(vault, _params), do: {:ok, vault}

  # Its key in the board switcher (#1204); "" takes a fresh one from its name.
  defp shortcut(vault, %{"shortcut" => key}) do
    case Vaults.set_shortcut(vault, key) do
      {:ok, vault} ->
        {:ok, vault}

      {:error, cs} ->
        {message, _} = cs.errors[:shortcut] || {"is invalid", []}
        {:error, :unprocessable_entity, "shortcut #{message}"}
    end
  end

  defp shortcut(vault, _params), do: {:ok, vault}

  # Its Ctrl+Shift digit (#1204), checked before anything is saved.
  defp hotkey_digit(%{"hotkey" => digit}) do
    case Slipdock.Hotkeys.parse(digit) do
      {:ok, digit} -> {:ok, digit}
      {:error, message} -> {:error, :unprocessable_entity, "hotkey #{message}"}
    end
  end

  defp hotkey_digit(_params), do: {:ok, nil}

  defp hotkey(conn, vault, %{"hotkey" => digit}) do
    case Slipdock.Hotkeys.put(user(conn), vault, digit) do
      {:ok, digit} -> {:ok, digit}
      {:error, message} -> {:error, :unprocessable_entity, "hotkey #{message}"}
    end
  end

  defp hotkey(_conn, _vault, _params), do: {:ok, nil}

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

  defp present(ref) when ref in [nil, ""],
    do: {:error, :bad_request, "say which link: ?link="}

  defp present(_ref), do: :ok

  @doc """
  Which board a vault path falls in, and the rest of the path below that
  board: the deepest board wins, a sub-board being inside its parent's folder.
  """
  def locate(conn, %{"id" => ref} = params) do
    with {:ok, vault} <- Vaults.get_vault(user(conn), ref),
         {:ok, board_id, rest} <- Vaults.locate(vault, params["path"] || "") do
      json(conn, %{board: V.vault_board(vault, board_id), rest: rest})
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
