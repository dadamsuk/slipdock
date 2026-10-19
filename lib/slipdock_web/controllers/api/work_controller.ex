defmodule SlipdockWeb.API.WorkController do
  @moduledoc """
  The caller's own work (#1118): `GET /api/work`, what the My work page
  shows. `waiting` is "Waiting on you" (`Slipdock.Work.waiting_on_me/2`),
  oldest first, with `waiting_count` its length; `sections` are the cards
  assigned to them by when they are due (`Slipdock.Work.grouped/3`).

  `?board=` keeps to one board's tree, `?done=true` adds the completed
  section. A token confined to some boards sees only those boards' trees.
  """
  use SlipdockWeb, :controller

  alias Slipdock.Boards.{Board, Card}
  alias Slipdock.Work
  alias SlipdockWeb.API.Authorize

  action_fallback SlipdockWeb.API.FallbackController

  def index(conn, params) do
    user = conn.assigns.current_user
    roots = token_roots(conn.assigns[:api_token])

    with {:ok, board} <- board(conn, params["board"]) do
      opts = [board_id: board && board.id, roots: roots]
      waiting = Work.waiting_on_me(user, opts)

      sections =
        user
        |> Work.assigned(nil, board_id: board && board.id)
        |> Enum.filter(&(is_nil(roots) or Board.root_id(&1.card.board) in roots))
        |> Work.group(params["done"] in ["true", "1"])

      json(conn, %{
        waiting_count: length(waiting),
        waiting: Enum.map(waiting, &item/1),
        sections:
          Enum.map(sections, fn s ->
            %{key: s.key, label: s.label, cards: Enum.map(s.items, &assigned/1)}
          end)
      })
    end
  end

  @doc "One \"Waiting on you\" item as the API, the CLI and the prompts give it."
  def item(i) do
    %{
      reason: i.reason,
      text: i.text,
      since: i.since,
      card: card(i.card),
      path: i.path,
      wait: i.wait && wait(i.wait),
      job: i.job && %{id: i.job.id, status: i.job.status, pool: i.job.pool}
    }
  end

  defp assigned(%{card: c, path: path}),
    do:
      Map.merge(card(c), %{
        path: path,
        due_date: Card.effective_due(c),
        priority: c.priority,
        completed: c.completed
      })

  defp card(c) do
    %{
      id: c.id,
      title: c.title,
      board_id: c.board_id,
      column: c.column && c.column.name,
      flags: c.flags
    }
  end

  defp wait(w) do
    %{
      id: w.id,
      needs: w.needs,
      choices: w.choices,
      on: w.on_user && (w.on_user.name || w.on_user.email),
      opened_at: w.inserted_at
    }
  end

  defp board(_conn, ref) when ref in [nil, ""], do: {:ok, nil}
  defp board(conn, ref), do: Authorize.fetch_board(conn, ref, :read)

  defp token_roots(%{scope_boards: [_ | _] = ids}), do: ids
  defp token_roots(_), do: nil
end
