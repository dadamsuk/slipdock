defmodule SlipdockWeb.API.HeaderLinkController do
  @moduledoc """
  The signed-in user's header links (#1205): boards and vaults pinned to the
  top right of every page, left of quick add, each as a chosen icon (see
  `Slipdock.HeaderLinks`).

  Links are personal, like hotkeys, so everything here is about the token's
  owner. A board needs only to be readable, and within a board-scoped
  token's reach; a vault has to be the caller's own.
  """
  use SlipdockWeb, :controller

  alias Slipdock.HeaderLinks
  alias SlipdockWeb.API.Authorize

  action_fallback SlipdockWeb.API.FallbackController

  @doc "Every link the user has, left to right, and the icons a link may wear."
  def index(conn, _params) do
    json(conn, %{
      header_links: entries(conn.assigns.current_user),
      icons: HeaderLinks.icons()
    })
  end

  @doc """
  Pins a board (`board`: id, code or name) or a vault (`vault`: id or name)
  as `icon`. Pinning one already pinned changes its icon.
  """
  def create(conn, params) do
    user = conn.assigns.current_user

    with {:ok, target} <- target(conn, params),
         {:ok, link} <- add(user, target, params["icon"]) do
      conn
      |> put_status(:created)
      |> json(%{header_link: entry(link), header_links: entries(user)})
    end
  end

  @doc "Moves a link one place along: `move` is `left` or `right`."
  def update(conn, %{"id" => id, "move" => direction}) when direction in ["left", "right"] do
    user = conn.assigns.current_user

    with {:ok, id} <- id(id),
         :ok <- HeaderLinks.move(user, id, String.to_existing_atom(direction)) do
      json(conn, %{header_links: entries(user)})
    else
      {:error, :not_found} -> {:error, :not_found, "header link"}
    end
  end

  def update(_conn, _params), do: {:error, :bad_request, "move must be left or right"}

  @doc "Takes a link off the header."
  def delete(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    with {:ok, id} <- id(id),
         :ok <- HeaderLinks.remove(user, id) do
      json(conn, %{header_links: entries(user)})
    else
      {:error, :not_found} -> {:error, :not_found, "header link"}
    end
  end

  defp target(conn, %{"board" => ref}) when ref not in [nil, ""] do
    Authorize.fetch_board(conn, ref, :read)
  end

  defp target(conn, %{"vault" => ref}) when ref not in [nil, ""] do
    case HeaderLinks.resolve(conn.assigns.current_user, :vault, ref) do
      {:ok, vault} -> {:ok, vault}
      {:error, _} -> {:error, :not_found, "vault"}
    end
  end

  defp target(_conn, _params), do: {:error, :bad_request, "board or vault is required"}

  defp add(user, target, icon) do
    case HeaderLinks.add(user, target, icon) do
      {:ok, link} -> {:ok, link}
      {:error, message} -> {:error, :unprocessable_entity, message}
    end
  end

  defp id(value) do
    case Integer.parse(to_string(value)) do
      {id, ""} -> {:ok, id}
      _ -> {:error, :not_found}
    end
  end

  defp entries(user), do: Enum.map(HeaderLinks.list(user), &entry/1)

  defp entry(%{kind: :vault} = link),
    do: %{id: link.id, icon: link.icon, vault: %{id: link.target.id, name: link.name}}

  defp entry(link),
    do: %{
      id: link.id,
      icon: link.icon,
      board: %{id: link.target.id, name: link.name, code: link.target.code}
    }
end
