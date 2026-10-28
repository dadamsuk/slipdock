defmodule SlipdockWeb.API.MultiboardController do
  @moduledoc """
  The multiboard overview (#1479): `GET /api/multiboard`, what the
  Multiboard page shows. The top `top` cards of each list in `lists`, laid
  out `by` board, list or as one grid section (see `Slipdock.Multiboard`).

  `lists` is comma-separated, each a list id or `board/list` (the board's
  code or name, the list's name). Anything left out comes from the caller's
  remembered view; this never changes it. A token confined to some boards
  sees only their lists.
  """
  use SlipdockWeb, :controller

  alias Slipdock.Multiboard

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

      entries = Multiboard.entries(view, choices)

      json(conn, %{
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
      })
    end
  end

  defp lists(nil, user, _choices), do: {:ok, Multiboard.prefs(user).lists}

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
