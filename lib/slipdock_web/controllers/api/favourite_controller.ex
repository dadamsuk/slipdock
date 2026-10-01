defmodule SlipdockWeb.API.FavouriteController do
  @moduledoc """
  The signed-in user's favourites: the boards, lists, cards, saved views and
  wiki pages they keep going back to (see `Slipdock.Favourites`).

  Favourites are personal, so every action here is about the token's owner
  and nobody else — there is no way to read or change another person's.
  """
  use SlipdockWeb, :controller

  alias Slipdock.Favourites

  action_fallback SlipdockWeb.API.FallbackController

  @doc "Everything the user has favourited and can still read."
  def index(conn, _params) do
    favourites = conn.assigns.current_user |> Favourites.list() |> Enum.map(&entry/1)
    json(conn, %{favourites: favourites})
  end

  @doc "Marks one thing a favourite. Idempotent: favouriting twice is once."
  def create(conn, params) do
    with {:ok, kind, id} <- target(params),
         {:ok, _} <- Favourites.add(conn.assigns.current_user, kind, id) do
      index(conn, %{})
    end
  end

  @doc "Takes one thing off the favourites. Idempotent."
  def delete(conn, params) do
    with {:ok, kind, id} <- target(params),
         {:ok, _} <- Favourites.remove(conn.assigns.current_user, kind, id) do
      index(conn, %{})
    end
  end

  # `kind` and `id` either as a body/query pair or as path segments.
  defp target(%{"kind" => kind, "id" => id}) do
    case {Favourites.kind(kind), Integer.parse(to_string(id))} do
      {{:ok, kind}, {id, ""}} ->
        {:ok, kind, id}

      {:error, _} ->
        {:error, :bad_request,
         "kind must be one of: #{Enum.map_join(Favourites.Favourite.kinds(), ", ", &to_string/1)}"}

      _ ->
        {:error, :bad_request, "id must be a number"}
    end
  end

  defp target(_), do: {:error, :bad_request, "kind and id are required"}

  defp entry(%{kind: kind} = f) do
    %{
      id: f.id,
      kind: to_string(kind),
      resource_id: f.resource_id,
      name: name(f),
      url: web_url(f),
      board:
        f.board &&
          %{id: f.board.id, name: f.board.name, code: f.board.code}
    }
  end

  defp name(%{kind: :card, resource: card}), do: card.title
  defp name(%{kind: :page, resource: page}), do: page.title
  defp name(%{resource: resource}), do: resource.name

  defp web_url(%{kind: :board, board: board}), do: ~p"/boards/#{board.id}"
  defp web_url(%{kind: :column, resource: c, board: b}), do: ~p"/boards/#{b.id}?#{[list: c.id]}"
  defp web_url(%{kind: :card, resource: c, board: b}), do: ~p"/boards/#{b.id}/cards/#{c.id}"

  defp web_url(%{kind: :page, resource: p, board: b}), do: ~p"/boards/#{b.id}/wiki/#{p.slug}"

  defp web_url(%{kind: :view, resource: v, board: b}),
    do: SlipdockWeb.SwimlaneComponents.view_path(b, v)
end
