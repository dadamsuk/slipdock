defmodule SlipdockWeb.API.WorkController do
  @moduledoc """
  The caller's own work (#1118): `GET /api/work`, what the My work page
  shows. `waiting` is "Waiting on you" (`Slipdock.Work.waiting_on_me/2`),
  oldest first, with `waiting_count` its length; `sections` are the cards
  assigned to them by when they are due (`Slipdock.Work.grouped/3`).

  `?board=` keeps to one board's tree, `?done=true` adds the completed
  section. A token confined to some boards sees only those boards' trees.

  What the person hid from it is counted beside it (#2069): `dismissed_count`
  (items dismissed whose cause still stands), `muted_count` (cards their
  muted boards keep off) and `muted_boards`. `GET /api/work/dismissed` lists
  the dismissed items, `POST /api/work/dismissed` (`card`) dismisses one,
  `DELETE /api/work/dismissed/:card` undoes it; `POST /api/work/muted`
  (`board`) mutes a board's tree, `DELETE /api/work/muted/:board` unmutes it.
  All of it is the caller's own: nobody else's list changes.
  """
  use SlipdockWeb, :controller

  alias Slipdock.Boards.{Board, Card}
  alias Slipdock.Work
  alias SlipdockWeb.API.{Authorize, CardWrites}

  action_fallback SlipdockWeb.API.FallbackController

  def index(conn, params) do
    user = conn.assigns.current_user
    roots = token_roots(conn.assigns[:api_token])

    with {:ok, board} <- board(conn, params["board"]) do
      opts = [board_id: board && board.id, roots: roots]
      %{items: waiting} = found = Work.waiting(user, opts)

      sections =
        user
        |> Work.assigned(nil, board_id: board && board.id)
        |> Enum.filter(&(is_nil(roots) or Board.root_id(&1.card.board) in roots))
        |> Work.group(params["done"] in ["true", "1"])

      json(conn, %{
        waiting_count: length(waiting),
        waiting: Enum.map(waiting, &item/1),
        dismissed_count: length(found.dismissed),
        muted_count: found.muted,
        muted_boards: muted_boards(user, roots),
        sections:
          Enum.map(sections, fn s ->
            %{key: s.key, label: s.label, cards: Enum.map(s.items, &assigned/1)}
          end)
      })
    end
  end

  @doc "The items the caller dismissed whose cause still stands, newest cause last."
  def dismissed(conn, params) do
    with {:ok, board} <- board(conn, params["board"]) do
      opts = [board_id: board && board.id, roots: token_roots(conn.assigns[:api_token])]

      json(conn, %{
        dismissed: conn.assigns.current_user |> Work.dismissed(opts) |> Enum.map(&item/1)
      })
    end
  end

  @doc "Takes one card's item off the caller's own list, held on its cause."
  def dismiss(conn, params) do
    with {:ok, card} <- readable_card(conn, params["card"]) do
      case Work.dismiss(conn.assigns.current_user, card) do
        {:ok, item} ->
          json(conn, %{dismissed: item(Map.put(item, :path, Work.path(item.card)))})

        {:error, :not_waiting} ->
          {:error, :unprocessable_entity, "card ##{card.id} isn't waiting on you"}
      end
    end
  end

  @doc "Undoes the caller's dismissals of a card: it shows again while its cause stands."
  def undismiss(conn, %{"card" => ref}) do
    with {:ok, card} <- readable_card(conn, ref) do
      case Work.undismiss(conn.assigns.current_user, card) do
        {:ok, n} -> json(conn, %{undismissed: %{card_id: card.id, count: n}})
        {:error, :not_dismissed} -> {:error, :not_found, "dismissal of card ##{card.id}"}
      end
    end
  end

  @doc "Keeps a board's tree off the caller's own list."
  def mute(conn, params) do
    with {:ok, board} <- Authorize.fetch_board(conn, params["board"], :read),
         {:ok, board} <- Work.mute(conn.assigns.current_user, board) do
      json(conn, %{muted: board_ref(board)})
    end
  end

  @doc "Lifts the caller's mute of a board."
  def unmute(conn, %{"board" => ref}) do
    with {:ok, board} <- Authorize.fetch_board(conn, ref, :read) do
      case Work.unmute(conn.assigns.current_user, board) do
        {:ok, board} -> json(conn, %{unmuted: board_ref(board)})
        {:error, :not_muted} -> {:error, :not_found, "mute of board #{board.name}"}
      end
    end
  end

  defp readable_card(conn, ref) do
    with {:ok, card} <- CardWrites.fetch_card(ref |> to_string() |> String.trim_leading("#")),
         :ok <- Authorize.card(conn, card, :read),
         do: {:ok, card}
  end

  defp muted_boards(user, roots) do
    user
    |> Work.muted_boards()
    |> Enum.filter(&(is_nil(roots) or Enum.member?(roots, Board.root_id(&1))))
    |> Enum.map(&board_ref/1)
  end

  @doc "A muted board as the API and MCP give it."
  def board_ref(b), do: %{id: b.id, name: b.name, code: b.code}

  @doc "One \"Waiting on you\" item as the API, the CLI and the prompts give it."
  def item(i) do
    %{
      reason: i.reason,
      cause: i.cause,
      text: i.text,
      since: i.since,
      card: card(i.card),
      path: i.path,
      wait: i.wait && wait(i.wait),
      job: i.job && %{id: i.job.id, status: i.job.status, pool: i.job.pool},
      condition: i[:condition] && SlipdockWeb.API.OverseerJSON.condition(i.condition)
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
