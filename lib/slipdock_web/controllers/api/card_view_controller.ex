defmodule SlipdockWeb.API.CardViewController do
  @moduledoc """
  The caller's own card views (#2031, see `Slipdock.CardViews`): what they
  see of a card, by global, board and list.

  Card views are personal, so every action is about the token's owner. A
  level is named by `board` (an id or code) and `list` (an id, or a name on
  that board): neither is global, `board` alone is the board's, both is the
  list's. Agents' own output never follows card views.
  """
  use SlipdockWeb, :controller

  alias Slipdock.CardViews
  alias SlipdockWeb.API.Authorize

  action_fallback SlipdockWeb.API.FallbackController

  @doc "The caller's named card views, and every element a card view can set."
  def index(conn, _params) do
    views = CardViews.list(conn.assigns.current_user)
    json(conn, %{card_views: Enum.map(views, &view_json/1), elements: elements_json()})
  end

  @doc "One named card view, by id or name."
  def show(conn, %{"id" => ref}) do
    with {:ok, view} <- fetch_view(conn, ref), do: json(conn, %{card_view: view_json(view)})
  end

  @doc "Saves a named card view: `name`, and `elements`, `show` or `hide`."
  def create(conn, params) do
    with {:ok, view} <- conn.assigns.current_user |> CardViews.create(params) |> result() do
      conn |> put_status(:created) |> json(%{card_view: view_json(view)})
    end
  end

  @doc "Renames a named card view or changes its elements (`inherit`, `reset` too)."
  def update(conn, %{"id" => ref} = params) do
    with {:ok, view} <- fetch_view(conn, ref),
         {:ok, view} <-
           conn.assigns.current_user
           |> CardViews.update(view, Map.delete(params, "id"))
           |> result() do
      json(conn, %{card_view: view_json(view)})
    end
  end

  @doc "Deletes a named card view. Levels that applied it keep their own elements."
  def delete(conn, %{"id" => ref}) do
    user = conn.assigns.current_user

    with {:ok, view} <- fetch_view(conn, ref),
         used = CardViews.levels_using(user, view),
         {:ok, _} <- CardViews.delete(user, view) do
      # The levels that applied it now inherit instead (#2036).
      json(conn, %{deleted: view_json(view), levels_now_inheriting: used})
    end
  end

  @doc "What the caller states at one level."
  def show_level(conn, params) do
    with {:ok, scope} <- scope(conn, params) do
      json(conn, %{level: level_json(scope, CardViews.level(conn.assigns.current_user, scope))})
    end
  end

  @doc """
  Changes one level: `card_view` (a named view's id or name to apply, or
  null to apply none), `elements` (element: true | false | null), `show`,
  `hide`, `inherit`, `reset`, and on a board's level `show_all`.
  """
  def update_level(conn, params) do
    user = conn.assigns.current_user

    with {:ok, scope} <- scope(conn, params),
         {:ok, level} <- user |> CardViews.update_level(scope, params) |> result() do
      json(conn, %{level: level_json(scope, level)})
    end
  end

  @doc "Clears one level, so it inherits everything."
  def clear_level(conn, params) do
    user = conn.assigns.current_user

    with {:ok, scope} <- scope(conn, params),
         {:ok, _} <- CardViews.clear_level(user, scope) do
      json(conn, %{level: level_json(scope, CardViews.level(user, scope))})
    end
  end

  @doc """
  The view that applies to a card on `board` (in `list`, if given), each
  element with where its value comes from. `view` names a saved view whose
  card view goes on top, as it does while that view is open.
  """
  def applied(conn, %{"board" => _} = params) do
    user = conn.assigns.current_user

    with {:ok, scope} <- scope(conn, params) do
      {board, column} = place(scope)
      name = saved_view_card_view(board, params["view"])
      explained = CardViews.explain(user, board, column, card_view: name)

      json(conn, %{
        board: board && %{id: board.id, code: board.code, name: board.name},
        list: column && %{id: column.id, name: column.name},
        saved_view_card_view: name,
        show_all: CardViews.level(user, {:board, board}).show_all,
        elements: explained
      })
    end
  end

  def applied(conn, _params) do
    explained = CardViews.explain(conn.assigns.current_user, nil)
    json(conn, %{board: nil, list: nil, show_all: false, elements: explained})
  end

  ## Helpers

  defp fetch_view(conn, ref) do
    case CardViews.get(conn.assigns.current_user, to_string(ref)) do
      {:ok, view} -> {:ok, view}
      {:error, :not_found} -> {:error, :not_found, "card view"}
    end
  end

  defp scope(conn, params) do
    user = conn.assigns.current_user

    with {:ok, board} <- board(conn, params["board"]),
         {:ok, column} <- column(board, params["list"]) do
      case CardViews.scope(user, board, column) do
        {:ok, scope} -> {:ok, scope}
        {:error, :not_found} -> {:error, :not_found, "board"}
      end
    end
  end

  defp board(_conn, blank) when blank in [nil, ""], do: {:ok, nil}

  defp board(conn, ref) do
    with {:ok, board} <- Authorize.fetch_board(conn, ref, :read),
         do: {:ok, CardViews.with_lists(board)}
  end

  defp column(_board, blank) when blank in [nil, ""], do: {:ok, nil}
  defp column(nil, _), do: {:error, :bad_request, "list needs a board"}

  defp column(board, ref) do
    ref = to_string(ref)

    case Enum.find(board.columns, &(to_string(&1.id) == ref)) ||
           Enum.find(board.columns, &(String.downcase(&1.name) == String.downcase(ref))) do
      nil -> {:error, :not_found, "list"}
      column -> {:ok, column}
    end
  end

  defp place(:global), do: {nil, nil}
  defp place({:board, board}), do: {board, nil}
  defp place({:list, board, column}), do: {board, column}

  # The card view a saved view names, by the saved view's id or name.
  defp saved_view_card_view(_board, blank) when blank in [nil, ""], do: nil

  defp saved_view_card_view(board, ref) do
    ref = to_string(ref)

    case Enum.find(board.saved_views, &(to_string(&1.id) == ref or &1.name == ref)) do
      %{config: %{"card_view" => name}} when is_binary(name) -> name
      _ -> nil
    end
  end

  defp result({:ok, _} = ok), do: ok
  defp result({:error, %Ecto.Changeset{}} = error), do: error
  defp result({:error, :not_found}), do: {:error, :not_found, "card view"}

  defp result({:error, message}) when is_binary(message),
    do: {:error, :unprocessable_entity, message}

  defp view_json(view), do: SlipdockWeb.API.JSON.card_view(view)
  defp level_json(scope, level), do: SlipdockWeb.API.JSON.card_view_level(place(scope), level)
  defp elements_json, do: SlipdockWeb.API.JSON.card_view_elements()
end
