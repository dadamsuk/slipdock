defmodule SlipdockWeb.PasskeyController do
  @moduledoc """
  Adding a passkey to the signed-in account (#828), for the account page's
  `Passkey` hook: a challenge, then the authenticator's answer to it. Both are
  POSTs with the page's CSRF token, and the challenge lives in the session
  between them, so it is used once and only by the browser that asked.

  Listing and removing passkeys need no authenticator, so they are the
  account page's own events and the API's (`SlipdockWeb.API.PasskeyController`).
  """
  use SlipdockWeb, :controller

  alias Slipdock.Accounts.Passkeys

  @challenge :passkey_registration_challenge

  @doc "A fresh challenge, and the options for `navigator.credentials.create()`."
  def options(conn, _params) do
    {challenge, options} =
      Passkeys.registration_challenge(
        conn.assigns.current_user,
        SlipdockWeb.BaseURL.from_conn(conn)
      )

    conn
    |> put_session(@challenge, challenge)
    |> json(%{publicKey: options})
  end

  @doc "Checks the authenticator's answer and keeps the passkey."
  def create(conn, params) do
    challenge = get_session(conn, @challenge)
    conn = delete_session(conn, @challenge)

    case Passkeys.register(conn.assigns.current_user, challenge, params, params["name"]) do
      {:ok, passkey} ->
        conn |> put_status(:created) |> json(%{passkey: %{id: passkey.id, name: passkey.name}})

      {:error, reason} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: message(reason)})
    end
  end

  defp message(:no_challenge), do: "That took too long. Try adding the passkey again."
  defp message(:already_added), do: "That passkey is already on an account here."

  defp message(:too_many),
    do: "You already have #{Passkeys.max_per_user()} passkeys. Remove one before adding another."

  defp message(%Ecto.Changeset{}),
    do: "That name is too long. Keep it under #{Slipdock.Accounts.Passkey.name_max()} characters."

  defp message(:invalid), do: "The passkey couldn't be checked, so it wasn't added."
end
