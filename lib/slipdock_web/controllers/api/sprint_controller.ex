defmodule SlipdockWeb.API.SprintController do
  @moduledoc """
  Sprints over the API (see `Slipdock.Sprints`): make the next one on a
  sprint board, move cards into one, and chart them — a sprint's burndown
  and a sprint board's velocity.
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
      conn |> put_status(:created) |> json(%{card: V.card(sprint)})
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
        card: V.card(Boards.get_card!(sprint.id)),
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
