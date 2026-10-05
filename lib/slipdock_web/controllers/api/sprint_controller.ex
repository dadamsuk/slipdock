defmodule SlipdockWeb.API.SprintController do
  @moduledoc """
  Sprints over the API (see `Slipdock.Sprints`): make the next one on a
  sprint board, choose the boards and lists its sprints are planned from,
  read the plan for one, move cards into one, and chart them — a sprint's
  burndown and a sprint board's velocity.
  """
  use SlipdockWeb, :controller

  alias Slipdock.{Boards, Sprints}
  alias Slipdock.Boards.Card
  alias SlipdockWeb.API.Authorize
  alias SlipdockWeb.API.JSON, as: V

  action_fallback SlipdockWeb.API.FallbackController

  # Body (all optional): {"name", "start": "2026-10-05", "days": 14, "goal"}.
  def create(conn, %{"board" => ref} = params) do
    with {:ok, board} <- Authorize.fetch_board(conn, ref, :write),
         {:ok, sprint} <-
           sprint_result(
             Sprints.create_sprint(board, Map.take(params, ~w(name start days goal)),
               by: conn.assigns.current_user
             )
           ) do
      conn |> put_status(:created) |> json(%{card: V.card(Authorize.visible(conn, sprint))})
    end
  end

  # What New sprint would fill in, without making anything.
  def next(conn, %{"board" => ref}) do
    with {:ok, board} <- Authorize.fetch_board(conn, ref, :read) do
      if Slipdock.Boards.Board.sprints?(board) do
        json(conn, %{next: Sprints.next_sprint(board)})
      else
        {:error, :unprocessable_entity, "#{board.name} is not a sprint board"}
      end
    end
  end

  # Committed and completed per sprint, oldest first, and the average.
  def velocity(conn, %{"board" => ref}) do
    with {:ok, board} <- Authorize.fetch_board(conn, ref, :read) do
      if Slipdock.Boards.Board.sprints?(board) do
        json(conn, %{velocity: Sprints.velocity(board)})
      else
        {:error, :unprocessable_entity, "#{board.name} is not a sprint board"}
      end
    end
  end

  # Where the board's sprints are planned from.
  def sources(conn, %{"board" => ref}) do
    with {:ok, board} <- Authorize.fetch_board(conn, ref, :read) do
      json(conn, %{sources: sources_json(Sprints.sources(board, conn.assigns.current_user))})
    end
  end

  # Body: {"sources": [{"board": ref, "lists": [id or name, ...]}, ...]}; no
  # lists means every list that is not done or dropped, and [] clears them.
  def put_sources(conn, %{"board" => ref} = params) do
    user = conn.assigns.current_user

    with {:ok, board} <- Authorize.fetch_board(conn, ref, :write),
         {:ok, wanted} <- fetch_sources(conn, params["sources"]),
         {:ok, board} <- sprint_result(Sprints.put_sources(board, user, wanted)) do
      json(conn, %{sources: sources_json(Sprints.sources(board, user))})
    end
  end

  # The planning view: the open cards on every source list, with their
  # priority, scores, votes and estimates, and what the sprint holds already.
  # `?sort=` is position (default), score, priority or estimate.
  def plan(conn, %{"id" => id} = params) do
    user = conn.assigns.current_user

    with {:ok, sprint} <- fetch_card(id),
         :ok <- Authorize.card(conn, sprint, :read) do
      if Sprints.sprint?(sprint) do
        sources =
          sprint
          |> Sprints.planning_board()
          |> Sprints.sources(user)
          |> Enum.filter(&(Authorize.board(conn, &1.board, :read) == :ok))

        plan = Sprints.plan(sprint, sources, params["sort"] || "position")
        json(conn, %{plan: plan_json(sprint, plan)})
      else
        {:error, :unprocessable_entity, "card #{id} is not a sprint"}
      end
    end
  end

  defp fetch_sources(conn, sources) when is_list(sources) do
    Enum.reduce_while(sources, {:ok, []}, fn
      %{"board" => ref} = source, {:ok, acc} ->
        case Authorize.fetch_board(conn, ref, :write) do
          {:ok, board} -> {:cont, {:ok, [{board, List.wrap(source["lists"])} | acc]}}
          error -> {:halt, error}
        end

      _, _ ->
        {:halt, {:error, :bad_request, "each source is {\"board\": ref, \"lists\": [...]}"}}
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp fetch_sources(_conn, _),
    do: {:error, :bad_request, "pass sources: a list of {board, lists}, or [] to clear them"}

  defp sources_json(sources) do
    Enum.map(sources, fn %{board: b, columns: columns, all: all} ->
      %{
        board: %{id: b.id, name: b.name, code: b.code},
        all_open_lists: all,
        lists: Enum.map(columns, &%{id: &1.id, name: &1.name})
      }
    end)
  end

  defp plan_json(sprint, plan) do
    %{
      sprint: %{
        id: sprint.id,
        title: sprint.title,
        start: sprint.start_date,
        due: sprint.due_date
      },
      committed: plan.committed,
      boards:
        Enum.map(plan.boards, fn group ->
          %{
            board: %{id: group.board.id, name: group.board.name, code: group.board.code},
            scores: Enum.map(group.formulas, &%{key: &1.key, name: &1.name}),
            lists:
              Enum.map(group.lists, fn list ->
                %{id: list.id, name: list.name, cards: Enum.map(list.cards, &entry_json/1)}
              end)
          }
        end)
    }
  end

  defp entry_json(e) do
    %{
      id: e.id,
      title: e.title,
      priority: e.priority,
      due_date: e.due_date,
      estimate_minutes: e.estimate,
      estimate_from_subcards: e.estimate_derived,
      scores: Map.new(e.scores, fn {field, value} -> {field.key, value} end),
      votes: e.votes,
      subcards: %{done: e.done, total: e.total},
      sub_board_id: e.sub_board_id,
      pickable: e.pickable
    }
  end

  # The work left at the end of each day of the sprint, against the ideal.
  def burndown(conn, %{"id" => id}) do
    with {:ok, sprint} <- fetch_card(id),
         :ok <- Authorize.card(conn, sprint, :read) do
      if Sprints.sprint?(sprint) do
        json(conn, %{burndown: Sprints.burndown(sprint)})
      else
        {:error, :unprocessable_entity, "card #{id} is not a sprint"}
      end
    end
  end

  # Body: {"cards": [id, ...]}. Every card has to be one the caller can
  # change; any that cannot go in for a reason of their own (already in, the
  # sprint itself, archived) come back under `skipped` rather than failing
  # the rest.
  def add(conn, %{"id" => id} = params) do
    with {:ok, sprint} <- fetch_card(id),
         :ok <- Authorize.card(conn, sprint, :write),
         {:ok, cards} <- fetch_cards(conn, params["cards"]),
         {:ok, %{added: added, skipped: skipped}} <-
           sprint_result(Sprints.add_cards(sprint, cards)) do
      json(conn, %{
        card: V.card(Authorize.visible(conn, Boards.get_card!(sprint.id))),
        added: Enum.map(added, &%{id: &1.id, title: &1.title}),
        skipped:
          Enum.map(skipped, fn {card, reason} -> %{id: card && card.id, reason: reason} end)
      })
    end
  end

  defp fetch_cards(conn, ids) when is_list(ids) and ids != [] do
    Enum.reduce_while(ids, {:ok, []}, fn id, {:ok, acc} ->
      with {:ok, card} <- fetch_card(id),
           :ok <- Authorize.card(conn, card, :write) do
        {:cont, {:ok, [card | acc]}}
      else
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, cards} -> {:ok, Enum.reverse(cards)}
      error -> error
    end
  end

  defp fetch_cards(_conn, _),
    do: {:error, :bad_request, "pass cards: a list of card ids to add to the sprint"}

  defp sprint_result({:ok, value}), do: {:ok, value}
  defp sprint_result({:error, %Ecto.Changeset{} = changeset}), do: {:error, changeset}
  defp sprint_result({:error, message}), do: {:error, :unprocessable_entity, message}

  defp fetch_card(id) do
    with {int, ""} <- Integer.parse(to_string(id)),
         %Card{} = card <- Boards.get_card(int) do
      {:ok, card}
    else
      _ -> {:error, :not_found, "card #{id}"}
    end
  end
end
