defmodule SlipdockWeb.API.RecurrenceController do
  @moduledoc """
  Recurring cards over HTTP (W-1802). The series lives on its current
  instance: `PUT /api/cards/:id/recurrence` sets or changes it, `GET` reads
  it (from an older instance too), `DELETE` stops it and `POST …/skip` lets
  the next occurrence go. `GET /api/boards/:board/recurring` lists a board's.
  Changing one needs write access to the card; reading, read access.
  """
  use SlipdockWeb, :controller

  alias Slipdock.Recurrence
  alias SlipdockWeb.API.Authorize
  alias SlipdockWeb.API.CardWrites
  alias SlipdockWeb.API.JSON, as: V

  action_fallback SlipdockWeb.API.FallbackController

  @fields ~w(rule at timezone lead_days on_missed ends ends_on count column paused)

  def show(conn, %{"id" => id}) do
    with {:ok, card} <- CardWrites.fetch_card(id),
         :ok <- Authorize.card(conn, card, :read) do
      series = Recurrence.series_of(card)

      json(conn, %{
        card: card.id,
        current: !!series && series.card_id == card.id,
        recurrence: series && V.recurrence(series)
      })
    end
  end

  def update(conn, %{"id" => id} = params) do
    with {:ok, card} <- CardWrites.fetch_card(id),
         :ok <- Authorize.card(conn, card, :write),
         {:ok, attrs} <- known(params),
         {:ok, series} <- set(card, attrs, conn.assigns.current_user) do
      json(conn, %{card: card.id, recurrence: V.recurrence(series)})
    end
  end

  def delete(conn, %{"id" => id}) do
    with {:ok, card} <- CardWrites.fetch_card(id),
         :ok <- Authorize.card(conn, card, :write) do
      case Recurrence.stop(card) do
        {:ok, _} -> json(conn, %{card: card.id, recurrence: nil})
        {:error, :not_found} -> {:error, :not_found, "recurrence on card #{card.id}"}
      end
    end
  end

  def skip(conn, %{"id" => id}) do
    with {:ok, card} <- CardWrites.fetch_card(id),
         :ok <- Authorize.card(conn, card, :write) do
      case Recurrence.skip(card) do
        {:ok, series} -> json(conn, %{card: card.id, recurrence: V.recurrence(series)})
        {:error, :not_found} -> {:error, :not_found, "recurrence on card #{card.id}"}
        {:error, message} when is_binary(message) -> {:error, :unprocessable_entity, message}
        {:error, %Ecto.Changeset{}} = error -> error
      end
    end
  end

  def index(conn, %{"board" => ref}) do
    with {:ok, board} <- Authorize.fetch_board(conn, ref, :read) do
      series =
        board
        |> Recurrence.list_for_board()
        |> Enum.filter(&(Authorize.card(conn, &1.card, :read) == :ok))

      json(conn, %{
        board: board.id,
        recurring:
          Enum.map(series, fn s ->
            s |> V.recurrence() |> Map.put(:card, %{id: s.card.id, title: s.card.title})
          end)
      })
    end
  end

  # Anything the series doesn't take is refused by name rather than ignored:
  # a misspelt "lead" would otherwise be a series made two days late.
  defp known(params) do
    attrs = Map.drop(params, ["id"])

    case Map.keys(attrs) -- @fields do
      [] ->
        {:ok, attrs}

      extra ->
        {:error, :bad_request,
         "unknown field(s): #{Enum.join(Enum.sort(extra), ", ")}; " <>
           "a recurrence takes #{Enum.join(@fields, ", ")}"}
    end
  end

  defp set(card, attrs, user) do
    case Recurrence.set(card, attrs, user) do
      {:ok, series} -> {:ok, series}
      {:error, message} when is_binary(message) -> {:error, :unprocessable_entity, message}
      {:error, %Ecto.Changeset{}} = error -> error
    end
  end
end
