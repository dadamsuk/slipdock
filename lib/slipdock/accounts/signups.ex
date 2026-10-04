defmodule Slipdock.Accounts.Signups do
  @moduledoc """
  Who may have an account here, and how a new one comes to exist: the
  registration modes, invitations from somebody sharing a board or a group,
  and the queue of requests an admin approves under `:approval`.

  Kept apart from signing in because the question "may this address be here?"
  is asked at the moment an account is created, not every time it is used —
  see `signup_allowed?/1`. Reached through `Slipdock.Accounts`.
  """
  import Ecto.Query, warn: false

  require Logger
  alias Slipdock.Repo
  alias Slipdock.Accounts
  alias Slipdock.Accounts.{SignupRequest, User, UserNotifier}
  alias Slipdock.Settings

  @doc """
  Whether this address may sign in, which for a new address means whether it
  may have an account at all. In order:

    * a disabled account never can, whatever else is true — that is what
      disabling means, and it is checked before everything else;
    * somebody who already has an account always can;
    * so can anybody at all on a server that has never been set up, because
      the setup wizard is how an instance is claimed and it needs a way in;
    * otherwise it is `signup_mode` (see `Slipdock.Settings`):
      * `:open` — anybody;
      * `:allowlist` — an address or domain an admin listed;
      * `:approval` — nobody *yet*; `request_signup/1` is how one asks;
      * `:closed` — nobody at all.

  The default is `:closed` — a server reachable by strangers does not quietly
  collect accounts.

  ## Why "set up" and not "has no users"

  This used to allow any address on an instance with no users, so that the
  first sign-in claimed the server. That was the bug this whole piece of work
  started from: the first person in became the only person who could ever be
  in, because nothing in the running system could add to an empty allowlist.

  Counting users was also the wrong question. A user can exist without anybody
  having been through setup — sharing a board with an address creates one (see
  `Slipdock.Access.grant/4`) — so an instance with users is not necessarily an
  instance somebody has claimed.

  ## Why "already has an account" is not a way round the mode

  It looks like one. Under `:allowlist`, `:approval` or `:closed`, an address
  that should be refused can be let in by someone sharing a board with it
  first — the account now exists, and the second clause of this function waves
  it through.

  The answer is that the check belongs at the moment an account is **created**,
  not at the moment it signs in. `invite_user/3` is the only path that can
  create one, and it refuses unless `invites_create_accounts` is on. So the
  question "may this address be here?" is asked exactly once, by whoever was
  doing the inviting, and the registration mode governs people who arrive by
  themselves.

  Revoking the sign-in instead would be worse: an account deliberately made for
  somebody, which then cannot be used, is a bug report waiting to happen. An
  admin who wants them gone has `Slipdock.Accounts.disable/1`, which this
  function does honour.
  """
  def signup_allowed?(email) when is_binary(email) do
    email = Slipdock.Email.normalize(email)
    existing = Accounts.get_user_by_email(email)

    cond do
      email == "" -> false
      Accounts.disabled?(existing) -> false
      existing != nil -> true
      not Settings.setup_complete?() -> true
      # The address this server calls its admin is never refused, even with
      # registration closed. It is the one address the person running the
      # server chose on purpose, and refusing it is how an install ends up
      # with nobody who can get in — which is what happened when
      # `SLIPDOCK_ADMIN_EMAIL` marked setup complete without creating an
      # account to go with it.
      admin_address?(email) -> true
      true -> mode_allows?(Settings.signup_mode(), email)
    end
  end

  def signup_allowed?(_), do: false

  defp admin_address?(email) do
    case Settings.get().admin_email do
      configured when is_binary(configured) -> Slipdock.Email.normalize(configured) == email
      _ -> false
    end
  end

  defp mode_allows?(:open, _email), do: true
  defp mode_allows?(:allowlist, email), do: Settings.allowlisted?(email)
  defp mode_allows?(_closed_or_approval, _email), do: false

  @doc """
  How this server would answer a brand-new address right now, for the sign-in
  page's wording: `:open`, `:allowlist`, `:approval`, `:closed`, or `:unclaimed`
  on a server nobody has set up.
  """
  @spec signup_stance() :: :open | :allowlist | :approval | :closed | :unclaimed
  def signup_stance do
    if Settings.setup_complete?(), do: Settings.signup_mode(), else: :unclaimed
  end

  @doc "Whether a brand-new address could sign up right now, for the UI's wording."
  def signups_open?, do: signup_stance() in [:open, :unclaimed]

  ## Inviting

  @doc """
  Brings `email` into this server because `inviter` is sharing something with
  it — the only path by which an address becomes an account without its owner
  asking.

  Returns `{:ok, user}` for somebody who is already here, `{:ok, user}` with a
  freshly made account when `invites_create_accounts` allows it, and
  `{:error, :invites_disabled}` when it does not.

  ## Why this is one function

  `Slipdock.Access.grant/4` and `Slipdock.Accounts.add_group_member/2` both
  used to resolve an unknown address by calling
  `Slipdock.Accounts.get_or_create_user_by_email/1` directly. Three things
  followed, all bad: any signed-in person could mint an account for any
  address in **every** registration mode, making the modes decorative; those
  people were never told; and because `signup_allowed?/1` says yes to anybody
  who already has an account, pre-creation was a standing way round the
  allowlist. Everything that can bring a new address into existence now comes
  through here, so there is one place to say no and one place to send the
  invitation from.

  `opts[:to]` names what they are being given access to, for the email.
  """
  @spec invite_user(String.t(), User.t(), keyword()) ::
          {:ok, User.t()} | {:error, :invites_disabled | Ecto.Changeset.t()}
  def invite_user(email, %User{} = inviter, opts \\ []) when is_binary(email) do
    email = Slipdock.Email.normalize(email)

    case Accounts.get_user_by_email(email) do
      %User{} = user ->
        {:ok, user}

      nil ->
        if Settings.invites_create_accounts?() do
          create_invited_user(email, inviter, opts)
        else
          {:error, :invites_disabled}
        end
    end
  end

  defp create_invited_user(email, inviter, opts) do
    attrs = %{"email" => email}

    changeset =
      %User{}
      |> User.email_changeset(attrs)
      |> Ecto.Changeset.put_change(:invited_by_id, inviter.id)
      |> Ecto.Changeset.put_change(
        :invited_at,
        DateTime.utc_now() |> DateTime.truncate(:second)
      )

    with {:ok, user} <- Repo.insert(changeset) do
      deliver_invitation(user, inviter, opts[:to])
      {:ok, user}
    end
  end

  @doc """
  Tells somebody they have been given an account and what for.

  Returns how it went, because the caller has to say: an account created in
  silence is worse than no account, and when there is no mail the inviter is
  the only one who can pass the code on.
  """
  @spec deliver_invitation(User.t(), User.t(), String.t() | nil) ::
          {:ok, :emailed | {:written, String.t()} | :logged} | {:error, term()}
  def deliver_invitation(%User{} = user, %User{} = inviter, to \\ nil) do
    base = Slipdock.Automations.Runner.base_url()

    cond do
      Settings.smtp_configured?() ->
        with {:ok, _} <- UserNotifier.deliver_invitation(user, inviter, to, base) do
          {:ok, :emailed}
        end

      true ->
        # No mail: the sign-in machinery's fallback is the only way they will
        # ever hear about this, and the inviter has to be told that.
        Accounts.deliver_sign_in(user, &"#{base}/login/#{&1}")
    end
  end

  ## Asking for an account (the `approval` mode)

  @doc """
  Records somebody asking for an account, and tells the admin one is waiting.

  Returns `{:ok, request}`, `{:ok, :already_pending}` when they have asked
  before, or `{:error, reason}`. Asking twice refreshes rather than duplicating:
  an approval queue full of the same impatient address is a queue nobody reads.

  A rejected address asking again is **not** a new request. Otherwise "no"
  means "no until you ask again", and the queue becomes a way to pester an
  admin indefinitely.
  """
  @spec request_signup(String.t(), keyword()) ::
          {:ok, SignupRequest.t() | :already_pending} | {:error, atom() | Ecto.Changeset.t()}
  def request_signup(email, opts \\ []) when is_binary(email) do
    email = Slipdock.Email.normalize(email)

    cond do
      Settings.signup_mode() != :approval ->
        {:error, :not_approval_mode}

      Accounts.get_user_by_email(email) != nil ->
        # They already have an account; there is nothing to approve.
        {:error, :already_a_user}

      true ->
        do_request_signup(email, opts)
    end
  end

  defp do_request_signup(email, opts) do
    case Repo.get_by(SignupRequest, email: email) do
      %SignupRequest{status: "pending"} ->
        {:ok, :already_pending}

      %SignupRequest{status: "rejected"} ->
        {:error, :rejected}

      %SignupRequest{status: "approved"} = request ->
        {:ok, request}

      nil ->
        attrs = %{"email" => email, "note" => opts[:note], "requested_ip" => opts[:ip]}

        with {:ok, request} <- %SignupRequest{} |> SignupRequest.changeset(attrs) |> Repo.insert() do
          notify_admins_of_request(request)
          {:ok, request}
        end
    end
  end

  @doc "Requests waiting on an admin, oldest first — they have waited longest."
  def list_signup_requests(status \\ "pending") do
    SignupRequest
    |> where([r], r.status == ^status)
    |> order_by([r], asc: r.inserted_at)
    |> preload(:decided_by)
    |> Repo.all()
  end

  def count_pending_signups, do: Repo.aggregate(where(SignupRequest, status: "pending"), :count)

  def get_signup_request!(id), do: Repo.get!(SignupRequest, id)
  def get_signup_request(nil), do: nil
  def get_signup_request(id), do: Repo.get(SignupRequest, id)

  @doc """
  Approves a request: makes the account and sends them a way in, so that "yes"
  is one action rather than two with a gap in which nothing happens.
  """
  @spec approve_signup(SignupRequest.t(), User.t(), (String.t() -> String.t())) ::
          {:ok, User.t()} | {:error, term()}
  def approve_signup(%SignupRequest{} = request, %User{} = admin, url_fun) do
    with {:ok, user} <- Accounts.get_or_create_user_by_email(request.email),
         {:ok, _} <-
           request |> SignupRequest.decision_changeset("approved", admin) |> Repo.update() do
      # If this fails they still have an account and can ask for a link
      # themselves, so it is not worth failing the approval over.
      _ = Accounts.deliver_sign_in(user, url_fun)
      {:ok, user}
    end
  end

  @doc "Turns a request down. They cannot simply ask again."
  def reject_signup(%SignupRequest{} = request, %User{} = admin) do
    request |> SignupRequest.decision_changeset("rejected", admin) |> Repo.update()
  end

  @doc """
  Forgets old decided requests. Keeping every address anybody ever typed is
  hoarding other people's data for no purpose.
  """
  def purge_signup_requests(older_than_days \\ 90) do
    cutoff = DateTime.utc_now() |> DateTime.add(-older_than_days, :day)

    {count, _} =
      Repo.delete_all(
        from(r in SignupRequest, where: r.status != "pending" and r.decided_at < ^cutoff)
      )

    count
  end

  defp notify_admins_of_request(%SignupRequest{} = request) do
    case Accounts.list_admins() do
      [] ->
        Logger.warning(
          "#{request.email} asked for an account, but this server has no admin to tell."
        )

      admins ->
        for admin <- admins do
          UserNotifier.deliver_signup_request(admin, request)
        end
    end
  end
end
