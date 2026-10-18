defmodule SlipdockWeb.API.SnoozeController do
  @moduledoc """
  Snooze over HTTP (W-1803). `POST /api/cards/:id/snooze {until, note?,
  notify?, wake_on_activity?}` hides a card until a moment; `DELETE` wakes
  it now. Both need write access to the card and answer the card.
  """
  use SlipdockWeb, :controller

  alias Slipdock.{Boards, Snooze}
  alias SlipdockWeb.API.{Authorize, CardWrites}
  alias SlipdockWeb.API.JSON, as: V

  action_fallback SlipdockWeb.API.FallbackController

  @fields ~w(until note notify wake_on_activity)

  def create(conn, %{"id" => id} = params) do
    user = conn.assigns.current_user

    with {:ok, card} <- CardWrites.fetch_card(id),
         :ok <- Authorize.card(conn, card, :write),
         :ok <- known(params),
         {:ok, until} <- required(params["until"]),
         {:ok, opts} <- options(params),
         {:ok, card} <- refused(Snooze.snooze(card, user, until, opts)) do
      answer(conn, card)
    end
  end

  def delete(conn, %{"id" => id}) do
    with {:ok, card} <- CardWrites.fetch_card(id),
         :ok <- Authorize.card(conn, card, :write),
         {:ok, card} <- refused(Snooze.wake(card, by: conn.assigns.current_user)) do
      answer(conn, card)
    end
  end

  defp answer(conn, card),
    do: json(conn, %{card: V.card(Authorize.visible(conn, Boards.get_card!(card.id)))})

  # A misspelt "notfy" would otherwise be a snooze that never says it woke.
  defp known(params) do
    case Map.keys(Map.drop(params, ["id"])) -- @fields do
      [] ->
        :ok

      extra ->
        {:error, :bad_request,
         "unknown field(s): #{Enum.join(Enum.sort(extra), ", ")}; " <>
           "a snooze takes #{Enum.join(@fields, ", ")}"}
    end
  end

  defp required(value) when is_binary(value) and value != "", do: {:ok, value}

  defp required(_),
    do: {:error, :bad_request, "until is required: " <> Snooze.error_message(:bad_date)}

  defp options(params) do
    with {:ok, notify} <- boolean(params, "notify", false),
         {:ok, wake} <- boolean(params, "wake_on_activity", true) do
      {:ok, [note: params["note"], notify: notify, wake_on_activity: wake]}
    end
  end

  defp boolean(params, key, default) do
    case Map.get(params, key) do
      nil -> {:ok, default}
      v when v in [true, "true"] -> {:ok, true}
      v when v in [false, "false"] -> {:ok, false}
      _ -> {:error, :bad_request, "#{key} must be true or false"}
    end
  end

  defp refused({:ok, _} = ok), do: ok

  defp refused({:error, reason}) when is_atom(reason),
    do: {:error, :unprocessable_entity, Snooze.error_message(reason)}

  defp refused({:error, %Ecto.Changeset{}} = error), do: error
end
