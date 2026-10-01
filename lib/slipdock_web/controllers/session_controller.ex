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
        |> put_flash(
          :info,
          if(claimed > 0,
            do:
              "Welcome! You now own the #{claimed} existing #{if claimed == 1, do: "board", else: "boards"}.",
            else: "Welcome back, #{Accounts.User.display_name(user)}."
          )
        )
        |> UserAuth.log_in_user(user)

      :error ->
        conn
        |> put_flash(:error, "That sign-in link is invalid or has expired. Request a new one.")
        |> redirect(to: ~p"/login")
    end
  end

  def delete(conn, _params) do
    conn
    |> put_flash(:info, "Signed out.")
    |> UserAuth.log_out_user()
  end
end
