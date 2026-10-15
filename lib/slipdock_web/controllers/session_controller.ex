defmodule SlipdockWeb.SessionController do
  use SlipdockWeb, :controller

  alias Slipdock.{Accounts, Onboarding}
  alias Slipdock.Accounts.Passkeys
  alias SlipdockWeb.UserAuth

  # Where a passkey sign-in keeps its challenge between the two requests.
  @passkey_challenge :passkey_login_challenge

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
      {:ok, user} -> signed_in(conn, user)
      :error -> expired(conn)
    end
  end

  @doc """
  The first half of a passkey sign-in (#828): a fresh challenge, kept in this
  browser's session so it is used once and only here, and the options the
  sign-in page hands to `navigator.credentials.get()`. A POST, with CSRF, so
  another site cannot have a browser mint one.
  """
  def passkey_options(conn, _params) do
    {challenge, options} = Passkeys.authentication_challenge(SlipdockWeb.BaseURL.from_conn(conn))

    conn
    |> put_session(@passkey_challenge, challenge)
    |> json(%{publicKey: options})
  end

  @doc """
  The second half: the sign-in page posts what the authenticator said, as an
  ordinary form, so signing in is the same redirect a magic link ends in.
  The challenge goes whatever the answer, so a failed try cannot be retried
  against it.
  """
  def passkey(conn, params) do
    challenge = get_session(conn, @passkey_challenge)
    conn = delete_session(conn, @passkey_challenge)

    case Passkeys.authenticate(challenge, Map.get(params, "passkey", %{})) do
      {:ok, user} ->
        signed_in(conn, user)

      {:error, :no_challenge} ->
        passkey_refused(conn, "That passkey sign-in took too long. Try again.")

      {:error, :cloned} ->
        passkey_refused(
          conn,
          "That passkey looks like a copy of another, so it can't sign in. " <>
            "Sign in with an email link and remove it from your account."
        )

      {:error, :invalid} ->
        passkey_refused(
          conn,
          "That passkey can't sign in here. It may have been removed — sign in with an email link instead."
        )
    end
  end

  defp passkey_refused(conn, message) do
    conn
    |> put_flash(:error, message)
    |> redirect(to: ~p"/login")
  end

  # Whichever door was used. A first sign-in builds the tour, and the sign-in
  # page says that signing in means agreeing to the terms, so this is where
  # the agreement is recorded.
  defp signed_in(conn, user) do
    tour = Onboarding.ensure_for(user)

    if Accounts.terms_outstanding?(user), do: {:ok, _} = Accounts.accept_terms(user)

    conn
    |> put_flash(:info, welcome(user, tour))
    |> UserAuth.log_in_user(user, to: landing(tour))
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
