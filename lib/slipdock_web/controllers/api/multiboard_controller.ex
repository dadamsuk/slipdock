defmodule SlipdockWeb.API.MultiboardController do
  @moduledoc """
  The multiboard overview (#1479): `GET /api/multiboard`, what the
  Multiboard page shows. The top `top` cards of each list in `lists`, laid
  out `by` board, list or as one grid section (see `Slipdock.Multiboard`).

  `lists` is comma-separated, each a list id or `board/list` (the board's
  code or name, the list's name). Anything left out comes from the caller's
  remembered view; this never changes it. A token confined to some boards
  sees only their lists.

  Saved multiboards (#1482), the caller's own named views listed on their
  home page:

    * `GET /api/multiboards` — them all, by name
    * `POST /api/multiboards` — `name`, `color`, and the view (`lists`,
      `top`, `by`; what is left out comes from the remembered view)
    * `GET /api/multiboards/:id` — one, by id or name, with its cards, as
      `index/2` answers
    * `PATCH /api/multiboards/:id` — any of `name`, `color`, `lists`,
      `top`, `by`
    * `DELETE /api/multiboards/:id`
  """
  use SlipdockWeb, :controller

  alias Slipdock.Multiboard
  alias Slipdock.Multiboard.Saved

  action_fallback SlipdockWeb.API.FallbackController

  def index(conn, params) do
    user = conn.assigns.current_user
    choices = Multiboard.choices(user, token: conn.assigns[:api_token])

    with {:ok, lists} <- lists(params["lists"], user, choices) do
      view =
        Multiboard.normalize(
          Map.put(Map.take(params, ~w(top by)), "lists", lists),
          user.multiboard
        )

      json(conn, answer(view, choices))
    end
  end

  def saved(conn, _params) do
    saved = Multiboard.list_saved(conn.assigns.current_user)
    json(conn, %{multiboards: Enum.map(saved, &summary/1)})
  end

  def create(conn, params) do
    user = conn.assigns.current_user
    choices = Multiboard.choices(user, token: conn.assigns[:api_token])

    with {:ok, lists} <- lists(params["lists"], user, choices),
         view =
           Multiboard.normalize(
             Map.put(Map.take(params, ~w(top by)), "lists", lists),
             user.multiboard
           ),
         {:ok, saved} <- Multiboard.create_saved(user, Map.take(params, ~w(name color)), view) do
      conn |> put_status(:created) |> json(%{multiboard: summary(saved)})
    end
  end

  def show(conn, %{"id" => id}) do
    user = conn.assigns.current_user
    choices = Multiboard.choices(user, token: conn.assigns[:api_token])

    with {:ok, saved} <- fetch(user, id) do
      json(conn, Map.put(answer(Saved.view(saved), choices), :multiboard, summary(saved)))
    end
  end

  def update(conn, %{"id" => id} = params) do
    user = conn.assigns.current_user
    choices = Multiboard.choices(user, token: conn.assigns[:api_token])

    with {:ok, saved} <- fetch(user, id),
         {:ok, lists} <- update_lists(params["lists"], saved, choices),
         {:ok, saved} <- Multiboard.update_saved(saved, Map.take(params, ~w(name color))),
         view =
           Multiboard.normalize(
             Map.put(Map.take(params, ~w(top by)), "lists", lists),
             %{"top" => saved.top, "by" => saved.by}
           ),
         {:ok, saved} <- Multiboard.save_view(saved, view) do
      json(conn, %{multiboard: summary(saved)})
    end
  end

  def delete(conn, %{"id" => id}) do
    with {:ok, saved} <- fetch(conn.assigns.current_user, id),
         {:ok, _} <- Multiboard.delete_saved(saved) do
      json(conn, %{deleted: summary(saved)})
    end
  end

  defp fetch(user, id) do
    case Multiboard.get_saved(user, id) do
      nil -> {:error, :not_found, "multiboard #{inspect(id)}"}
      saved -> {:ok, saved}
    end
  end

  defp update_lists(nil, saved, _choices), do: {:ok, saved.lists}
  defp update_lists(refs, _saved, choices), do: lists(refs, nil, choices)

  defp summary(%Saved{} = s) do
    %{
      id: s.id,
      name: s.name,
      color: s.color,
      lists: s.lists,
      top: s.top,
      by: s.by,
      position: s.position
    }
  end

  defp answer(view, choices) do
    entries = Multiboard.entries(view, choices)

    %{
      top: view.top,
      by: view.by,
      lists:
        Enum.map(entries, fn e ->
          %{id: e.column.id, name: e.column.name, board: board(e.board)}
        end),
      sections:
        entries
        |> Multiboard.group(view.by)
        |> Enum.map(fn s ->
          %{key: s.key, label: s.label, cards: Enum.map(s.items, &card/1)}
        end)
    }
  end

  defp lists(nil, user, _choices), do: {:ok, Multiboard.prefs(user).lists}

  defp lists(refs, user, choices) when is_list(refs),
    do: lists(Enum.map_join(refs, ",", &to_string/1), user, choices)

  defp lists(refs, _user, choices) do
    case Multiboard.resolve(String.split(refs, ",", trim: true), choices) do
      {:ok, ids} -> {:ok, ids}
      {:error, ref} -> {:error, :not_found, "list #{inspect(ref)}"}
    end
  end

  defp board(b), do: %{id: b.id, code: b.code, name: b.name}

  defp card(%{card: c, board: b, column: col}) do
    %{
      id: c.id,
      title: c.title,
      board_id: c.board_id,
      board: b.code || b.name,
      column: col.name,
      flags: c.flags,
      priority: c.priority,
      due_date: c.due_date,
      completed: c.completed,
      tags: Enum.map(c.tags, & &1.name)
    }
  end
end
