defmodule SlipdockWeb.SessionController do
  use SlipdockWeb, :controller

  alias Slipdock.{Access, Accounts, Onboarding}
  alias SlipdockWeb.UserAuth

  @doc "The magic link lands here."
  def create(conn, %{"token" => token}) do
    case Accounts.verify_magic_link(token) do
      {:ok, user} ->
        # Order matters: claiming the boards of an install that had none makes
        # this account an owner, and an owner is not somebody who needs a
        # tutorial board (see `Slipdock.Onboarding`).
        claimed = Access.claim_unowned_boards(user)
        tour = Onboarding.ensure_for(user)

        # The sign-in page says that signing in means agreeing to the terms,
        # so this is where the agreement is recorded.
        if Accounts.terms_outstanding?(user), do: {:ok, _} = Accounts.accept_terms(user)

        conn
        |> put_flash(:info, welcome(user, claimed, tour))
        |> UserAuth.log_in_user(user, to: landing(tour))

      :error ->
        conn
        |> put_flash(:error, "That sign-in link is invalid or has expired. Request a new one.")
        |> redirect(to: ~p"/login")
    end
  end

  defp welcome(_user, boards, _tour) when boards > 0 do
    "Welcome! You now own the #{boards} existing #{if boards == 1, do: "board", else: "boards"}."
  end

  defp welcome(_user, _boards, {:ok, board}) do
    "Welcome to Slipdock. “#{board.name}” is a tour of it: work down the To Do " <>
      "list, then archive the board."
  end

  defp welcome(user, _boards, :skipped) do
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
