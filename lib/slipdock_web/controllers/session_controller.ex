defmodule SlipdockWeb.SessionController do
  use SlipdockWeb, :controller

  alias Slipdock.{Access, Accounts}
  alias SlipdockWeb.UserAuth

  @doc "The magic link lands here."
  def create(conn, %{"token" => token}) do
    case Accounts.verify_magic_link(token) do
      {:ok, user} ->
        claimed = Access.claim_unowned_boards(user)

        conn
        |> put_flash(:info, welcome(user, claimed))
        |> UserAuth.log_in_user(user)

      :error ->
        conn
        |> put_flash(:error, "That sign-in link is invalid or has expired. Request a new one.")
        |> redirect(to: ~p"/login")
    end
  end

  defp welcome(_user, boards) when boards > 0 do
    "Welcome! You now own the #{boards} existing #{if boards == 1, do: "board", else: "boards"}."
  end

  defp welcome(user, _boards) do
    "Welcome back, #{Accounts.User.display_name(user)}."
  end

  def delete(conn, _params) do
    conn
    |> put_flash(:info, "Signed out.")
    |> UserAuth.log_out_user()
  end
end
