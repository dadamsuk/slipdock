defmodule SlipdockWeb.CardSignController do
  @moduledoc """
  The owner signing a card's text with a passkey (#3532, `Slipdock.Intent`),
  for the card panel's `CardSign` hook: a challenge, which is SHA-256 of the
  card's canonical text now, then the authenticator's answer to it. Both are
  POSTs with the page's CSRF token, and the challenge lives in the session
  between them, so it is used once and only by the browser that asked.

  The card is `:card_id` in the path: the answer's own `id` is the
  credential's.
  """
  use SlipdockWeb, :controller

  alias Slipdock.Boards.Cards
  alias Slipdock.Intent

  @challenge :card_sign_challenge

  @doc "A challenge over the card's text now, and the options for `navigator.credentials.get()`."
  def options(conn, %{"card_id" => id}) do
    with %Slipdock.Boards.Card{} = card <- card(conn, id),
         {:ok, challenge, signed_at, options} <-
           Intent.signing_challenge(
             conn.assigns.current_user,
             card,
             SlipdockWeb.BaseURL.from_conn(conn)
           ) do
      conn
      |> put_session(@challenge, %{card_id: card.id, challenge: challenge, signed_at: signed_at})
      |> json(%{publicKey: options, signedAt: DateTime.to_iso8601(signed_at)})
    else
      nil -> refuse(conn, :not_found)
      {:error, reason} -> refuse(conn, reason)
    end
  end

  @doc "Checks the authenticator's answer and keeps it on the card."
  def create(conn, %{"card_id" => id} = params) do
    kept = get_session(conn, @challenge)
    conn = delete_session(conn, @challenge)

    with %Slipdock.Boards.Card{} = card <- card(conn, id),
         {:ok, challenge, signed_at} <- kept_for(kept, card),
         {:ok, signed} <-
           Intent.sign(conn.assigns.current_user, card, challenge, signed_at, params) do
      json(conn, %{signed_at: DateTime.to_iso8601(signed.signed_at)})
    else
      nil -> refuse(conn, :not_found)
      {:error, reason} -> refuse(conn, reason)
    end
  end

  # The kept challenge answers only for the card it was made for.
  defp kept_for(%{card_id: card_id, challenge: challenge, signed_at: signed_at}, %{id: card_id}),
    do: {:ok, challenge, signed_at}

  defp kept_for(_kept, _card), do: {:error, :no_challenge}

  # A card the person can't read is no card, as for any other door.
  defp card(conn, id) do
    with id when is_integer(id) <- SlipdockWeb.Params.id(id),
         %Slipdock.Boards.Card{} = card <- Cards.get_card_record(id),
         level when level != :none <-
           Slipdock.Access.card_permission(conn.assigns.current_user, card) do
      card
    else
      _ -> nil
    end
  end

  defp refuse(conn, %Slipdock.Policy.Refused{}), do: refuse(conn, :not_owner)

  defp refuse(conn, reason) do
    conn |> put_status(status(reason)) |> json(%{error: message(reason)})
  end

  defp status(:not_found), do: :not_found
  defp status(:not_owner), do: :forbidden
  defp status(_reason), do: :unprocessable_entity

  defp message(:not_found), do: "There is no such card."
  defp message(:not_owner), do: "Only the owner of the board can sign its cards."
  defp message(:no_passkey), do: "Add a passkey on your account page to sign cards."
  defp message(:no_challenge), do: "That took too long. Sign the card again."

  defp message(:changed),
    do: "The card changed while you were signing it. Read it again, then sign it."

  defp message(:invalid),
    do: "The passkey's signature couldn't be checked, so the card isn't signed."
end
