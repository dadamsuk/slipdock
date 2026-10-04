defmodule SlipdockWeb.SessionController do
  use SlipdockWeb, :controller

  alias Slipdock.{Accounts, Onboarding}
  alias SlipdockWeb.UserAuth

  @doc """
  The magic link lands here: a button that signs in, if the link still works.
  Nothing is used up until it is pressed.
  """
  def confirm(conn, %{"token" => token}) do
    if Accounts.magic_link_valid?(token) do
      render(conn, :confirm, token: token, page_title: "Sign in")
    else
      expired(conn)
    end
  end

  @doc "The confirm page's button posts here."
  def create(conn, %{"token" => token}) do
    case Accounts.verify_magic_link(token) do
      {:ok, user} ->
        tour = Onboarding.ensure_for(user)

        # The sign-in page says that signing in means agreeing to the terms,
        # so this is where the agreement is recorded.
        if Accounts.terms_outstanding?(user), do: {:ok, _} = Accounts.accept_terms(user)

        conn
        |> put_flash(:info, welcome(user, tour))
        |> UserAuth.log_in_user(user, to: landing(tour))

      :error ->
        expired(conn)
    end
  end

  defp expired(conn) do
    conn
    |> put_flash(:error, "That sign-in link is invalid or has expired. Request a new one.")
    |> redirect(to: ~p"/login")
  end

  defp welcome(_user, {:ok, board}) do
    "Welcome to Slipdock. “#{board.name}” is a tour of it: work down the To Do " <>
      "list, then archive the board."
  end

  defp welcome(user, :skipped) do
    "Welcome back, #{Accounts.User.display_name(user)}."
  end

  # Nowhere in particular: `log_in_user/3` falls back to the board index.
  defp landing({:ok, board}), do: ~p"/boards/#{board}"
  defp landing(:skipped), do: nil

  def delete(conn, _params) do
    conn
    |> put_flash(:info, "Signed out.")
    |> UserAuth.log_out_user()
  end
end
