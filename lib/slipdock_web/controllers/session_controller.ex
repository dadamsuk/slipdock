defmodule SlipdockWeb.SessionController do
  use SlipdockWeb, :controller

  alias Slipdock.{Access, Accounts}
  alias SlipdockWeb.UserAuth

  @doc "The magic link lands here."
  def create(conn, %{"token" => token}) do
    case Accounts.verify_magic_link(token) do
      {:ok, user} ->
        # A server nobody has set up yet lets any address in, because the way it
        # gets claimed is somebody signing in. This is where it stops being
        # open: the first person through becomes the admin and registration
        # follows the configured mode from then on.
        claimed_server = Accounts.claim_server(user)
        claimed = Access.claim_unowned_boards(user)

        conn
        |> put_flash(:info, welcome(user, claimed_server, claimed))
        |> UserAuth.log_in_user(user)

      :error ->
        conn
        |> put_flash(:error, "That sign-in link is invalid or has expired. Request a new one.")
        |> redirect(to: ~p"/login")
    end
  end

  # Whoever claims the server needs to be told that they did, and what it means
  # — otherwise the single most consequential moment in running this thing
  # passes without comment.
  defp welcome(_user, :claimed, _boards) do
    "Welcome — this server is yours. You are the admin: nobody else can sign up " <>
      "until you allow it, under Admin."
  end

  defp welcome(_user, _claimed_server, boards) when boards > 0 do
    "Welcome! You now own the #{boards} existing #{if boards == 1, do: "board", else: "boards"}."
  end

  defp welcome(user, _claimed_server, _boards) do
    "Welcome back, #{Accounts.User.display_name(user)}."
  end

  def delete(conn, _params) do
    conn
    |> put_flash(:info, "Signed out.")
    |> UserAuth.log_out_user()
  end
end
