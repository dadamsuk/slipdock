defmodule Slipdock.Accounts do
  @moduledoc """
  Users, passwordless sign-in by emailed magic link, browser sessions
  (valid for 30 days), API tokens, and groups of users.
  """
  import Ecto.Query, warn: false

  require Logger
  alias Slipdock.Repo

  alias Slipdock.Accounts.{
    DeviceAuthorization,
    Group,
    SignupRequest,
    SupportSession,
    User,
    UserNotifier,
    UserToken
  }

  alias Slipdock.Boards.Board
  alias Slipdock.RateLimit
  alias Slipdock.Settings

  ## Users

  def get_user!(id), do: Repo.get!(User, id)
  def get_user(id), do: Repo.get(User, id)

  def get_user_by_email(email) when is_binary(email) do
    Repo.get_by(User, email: email |> String.trim() |> String.downcase())
  end

  @doc """
  **Every** user on this server, unscoped. The admin's view.

  This is not the list to put in a people picker, a mention menu, an API
  response or a prompt sent to a model: where strangers share a server it hands
  each of them everybody else's email address. `Slipdock.Access.visible_users/1`
  is the one that answers "who may *this* person see", and it falls back to
  this list when the instance is configured to show everybody.
  """
  def list_users, do: Repo.all(from(u in User, order_by: [asc: u.email]))

  @doc "Finds the user with this email, creating one if needed."
  def get_or_create_user_by_email(email) do
    case get_user_by_email(email) do
      %User{} = user -> {:ok, user}
      nil -> %User{} |> User.email_changeset(%{"email" => email}) |> Repo.insert()
    end
  end

  def update_profile(%User{} = user, attrs) do
    user |> User.profile_changeset(attrs) |> Repo.update()
  end

  @doc """
  Saves the quick add defaults (see `Slipdock.QuickAdd`). A list that isn't on
  the chosen board is dropped rather than saved as a mismatch.
  """
  def update_quick_add(%User{} = user, attrs) do
    user |> User.quick_add_changeset(attrs) |> Repo.update()
  end

  def change_quick_add(%User{} = user, attrs \\ %{}), do: User.quick_add_changeset(user, attrs)

  @doc """
  Saves how this person sees the board index — cards or a compact table, and
  the order boards are listed in. Their own view: it changes nothing for
  anyone else who can see the same boards.
  """
  def update_board_view(%User{} = user, attrs) do
    user |> User.board_view_changeset(attrs) |> Repo.update()
  end

  def change_email(attrs \\ %{}), do: User.email_changeset(%User{}, attrs)
  def change_profile(%User{} = user, attrs \\ %{}), do: User.profile_changeset(user, attrs)

  def count_users, do: Repo.aggregate(User, :count)

  ## Admins, and standing on this server

  @doc """
  Whether this person may administer the server. There is one role and this is
  it: an admin can change who may register, how mail is sent, and other
  people's standing. Nobody else can.
  """
  @spec admin?(User.t() | nil) :: boolean()
  def admin?(%User{admin: true}), do: true
  def admin?(_), do: false

  @doc "Whether this account has been disabled, and so cannot sign in."
  @spec disabled?(User.t() | nil) :: boolean()
  def disabled?(%User{disabled_at: %DateTime{}}), do: true
  def disabled?(_), do: false

  def list_admins, do: Repo.all(from(u in User, where: u.admin == true, order_by: [asc: u.email]))

  @doc """
  How many admins could actually administer this server right now. A disabled
  admin cannot sign in, so does not count: otherwise one admin could disable
  the other and then demote themself, leaving only a locked-out account.
  """
  def count_admins, do: Repo.aggregate(active_admins(), :count)

  defp active_admins, do: from(u in User, where: u.admin == true and is_nil(u.disabled_at))

  @doc """
  Whether this person is the only admin left — in which case demoting,
  disabling or deleting them would leave a server nobody can administer, with
  no way back from inside the app. Every one of those three refuses when this
  is true.
  """
  @spec last_admin?(User.t()) :: boolean()
  def last_admin?(%User{admin: true} = user) do
    ids = Repo.all(from(u in active_admins(), select: u.id))
    ids == [user.id]
  end

  def last_admin?(_), do: false

  # Runs `fun` unless `user` is the only active admin, in one transaction with
  # every active admin row locked. Without the lock, two admins demoting each
  # other at the same moment both see two admins and both go ahead, leaving
  # none. Postgres re-checks the `where` on a row it waited for, so whoever
  # goes second counts the admins the first one left.
  defp unless_last_admin(%User{} = user, fun) do
    Repo.transaction(fn ->
      ids = Repo.all(from(u in active_admins(), select: u.id, lock: "FOR UPDATE"))

      if ids == [user.id] do
        Repo.rollback(:last_admin)
      else
        case fun.() do
          {:ok, value} -> value
          {:error, reason} -> Repo.rollback(reason)
        end
      end
    end)
  end

  @doc """
  Changes somebody's standing: admin or not, and their own card limit.

  Refuses to take the last admin's rights away (`{:error, :last_admin}`), which
  is the one mistake here that cannot be undone from the browser.
  """
  @spec update_standing(User.t(), map()) ::
          {:ok, User.t()} | {:error, :last_admin | Ecto.Changeset.t()}
  def update_standing(%User{} = user, attrs) do
    update = fn -> user |> User.standing_changeset(attrs) |> Repo.update() end

    if attrs_say_not_admin?(attrs) do
      with {:ok, updated} <- unless_last_admin(user, update) do
        # An open admin page re-checks on every event, but disconnecting makes
        # every other tab they have open remount and find out too.
        if user.admin, do: disconnect_sessions(updated)
        {:ok, updated}
      end
    else
      update.()
    end
  end

  @doc "Makes somebody an admin."
  def promote(%User{} = user), do: update_standing(user, %{"admin" => true})

  @doc """
  The recovery route (`setup --make-admin`): an admin, and able to sign in.
  Promoting a disabled account alone would leave the server exactly as
  locked out as it was.
  """
  def restore_admin(%User{} = user) do
    with {:ok, user} <- enable(user), do: promote(user)
  end

  @doc "Takes somebody's admin rights away, unless they are the last admin."
  def demote(%User{} = user), do: update_standing(user, %{"admin" => false})

  @doc """
  Disables an account: no sign-in, and existing sessions and API tokens stop
  working. Preferred over deleting, which would orphan their cards, comments,
  grants and the wiki revisions signed with their name.

  Refuses on the last admin, for the same reason `demote/1` does.
  """
  @spec disable(User.t()) :: {:ok, User.t()} | {:error, :last_admin | Ecto.Changeset.t()}
  def disable(%User{} = user) do
    with {:ok, user} <-
           unless_last_admin(user, fn ->
             user
             |> Ecto.Changeset.change(disabled_at: DateTime.utc_now(:second))
             |> Repo.update()
           end) do
      # Being disabled has to take effect now, not at the end of a 30-day
      # session — and not at the next page load in a tab that is already open.
      delete_all_sessions(user)
      {:ok, user}
    end
  end

  @doc "Lets a disabled account back in. They will need to sign in again."
  def enable(%User{} = user) do
    user |> Ecto.Changeset.change(disabled_at: nil) |> Repo.update()
  end

  @doc "Records that somebody signed in, for the admin users list."
  def touch_last_signed_in(%User{} = user) do
    Repo.update_all(from(u in User, where: u.id == ^user.id),
      set: [last_signed_in_at: DateTime.utc_now(:second)]
    )

    :ok
  end

  # `attrs["admin"] || attrs[:admin]` cannot be used here: the value being
  # looked for *is* false, which `||` would discard.
  defp attrs_say_not_admin?(attrs) do
    case Map.get(attrs, "admin", Map.get(attrs, :admin, :absent)) do
      value when value in [false, "false", "0", 0] -> true
      _ -> false
    end
  end

  ## Magic links

  @doc """
  Emails `email` a one-time sign-in link built with `url_fun.(token)`.

  Returns `{:error, :not_allowed}` when this server will not make an account
  for that address (see `signup_allowed?/1`). The caller should not tell the
  visitor which of the two happened — that would say who has an account here.

  With no mail server the message still goes to the compiled adapter (the
  `/dev/mailbox` in development), and the link and code are also written to
  the sign-in fallback — but only while `Settings.login_fallback_enabled?/0`
  says so. Switched off, they are written nowhere a person could read them.
  """
  def deliver_magic_link(email, url_fun) when is_function(url_fun, 1) do
    with :ok <- check_signup(email),
         {:ok, user} <- get_or_create_user_by_email(email) do
      {token, code} = create_magic_token(user)
      link = url_fun.(token)

      with {:ok, _} = sent <- UserNotifier.deliver_magic_link(user, link, code) do
        if not Settings.smtp_configured?() and Settings.login_fallback_enabled?(),
          do: write_sign_in_fallback(user, link, code)

        sent
      end
    end
  end

  @doc """
  `deliver_magic_link/2` off the caller's back, for the sign-in page.

  Done inline, an address that may sign in costs a database write and an SMTP
  round trip while a refused one returns at once — and that difference answers
  "does this person have an account here?" for anybody with a stopwatch. Run
  from a task, both return as soon as the address is seen to be well formed.

  Returns `:ok`, or `{:error, :invalid_email}` for an address that is not one,
  which says nothing about who is here. Failures to send are logged rather
  than returned: telling the visitor would be the same leak.

  `config :slipdock, :sign_in_mail, async: false` runs it inline, for tests.
  """
  @spec deliver_magic_link_later(String.t(), (String.t() -> String.t())) ::
          :ok | {:error, :invalid_email}
  def deliver_magic_link_later(email, url_fun) when is_function(url_fun, 1) do
    if User.email_changeset(%User{}, %{"email" => to_string(email)}).valid? do
      send_later(fn ->
        case deliver_magic_link(email, url_fun) do
          {:ok, _} -> :ok
          {:error, :not_allowed} -> :ok
          {:error, reason} -> Logger.warning("Sign-in email not sent: #{inspect(reason)}")
        end
      end)
    else
      {:error, :invalid_email}
    end
  end

  # The supervisor has a ceiling; a sign-in that finds it full runs inline
  # rather than being dropped, since a lost link strands somebody.
  defp send_later(fun) do
    if Application.get_env(:slipdock, :sign_in_mail, [])[:async] == false do
      fun.()
    else
      case Task.Supervisor.start_child(Slipdock.TaskSupervisor, fun) do
        {:ok, _pid} -> :ok
        {:error, _} -> fun.()
      end
    end

    :ok
  end

  @doc """
  Gets `user` a way in, by whichever route this server actually has: an emailed
  link when mail is configured, and otherwise a file on the server plus the log.

  Returns `{:ok, :emailed}`, `{:ok, {:written, path}}`, `{:ok, :logged}` when the
  file could not be written but the log has it, or `{:error, reason}`.
  The caller is expected to say which happened — a wizard or an admin page that
  claims to have sent something it did not is how people get stranded.

  `url_fun` builds the sign-in URL from a token, as `deliver_magic_link/2` does.

  Deliberately not gated on `signup_allowed?/1`: the callers are the setup
  wizard and an admin inviting somebody, both of which have already decided.
  """
  @spec deliver_sign_in(User.t(), (String.t() -> String.t())) ::
          {:ok, :emailed | {:written, String.t()} | :logged} | {:error, term()}
  def deliver_sign_in(%User{} = user, url_fun) when is_function(url_fun, 1) do
    {token, code} = create_magic_token(user)
    link = url_fun.(token)

    cond do
      Settings.smtp_configured?() ->
        case UserNotifier.deliver_magic_link(user, link, code) do
          {:ok, _} -> {:ok, :emailed}
          {:error, reason} -> {:error, reason}
        end

      Settings.login_fallback_enabled?() ->
        write_sign_in_fallback(user, link, code)

      true ->
        {:error, :no_delivery}
    end
  end

  @doc """
  Where sign-in links go when no mail server can carry them. One known path, so
  that the instructions on screen can name it, rather than a random file in a
  directory somebody has to go hunting through.

  Anyone who can read this file can sign in as anybody. That is an acceptable
  trade on a server only you can reach and a hole on one you share, which is
  what `Slipdock.Settings.login_fallback_enabled?/0` decides.
  """
  @spec fallback_path() :: String.t()
  def fallback_path do
    Application.get_env(:slipdock, :login_fallback_path) ||
      Path.join(File.cwd!(), "log/sign-in-links.log")
  end

  defp write_sign_in_fallback(%User{} = user, link, code) do
    path = fallback_path()
    stamp = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    # Also logged, so `journalctl` and `docker compose logs` work for somebody
    # who does not know the path. The code comes first on the line: it is the
    # part a person can realistically read off a terminal and retype.
    Logger.info("Sign-in code for #{user.email} is #{code} (no mail server configured): #{link}")

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, "#{stamp}  #{user.email}  #{code}  #{link}\n", [:append]) do
      _ = File.chmod(path, 0o600)
      {:ok, {:written, path}}
    else
      {:error, reason} ->
        Logger.error("Could not write the sign-in fallback file #{path}: #{inspect(reason)}")
        # Not a dead end — the link is in the log either way — but the caller
        # must not tell somebody to read a file that was never written.
        {:ok, :logged}
    end
  end

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
  admin who wants them gone has `disable/1`, which this function does honour.
  """
  def signup_allowed?(email) when is_binary(email) do
    email = email |> String.trim() |> String.downcase()
    existing = get_user_by_email(email)

    cond do
      email == "" -> false
      disabled?(existing) -> false
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
      configured when is_binary(configured) -> String.downcase(String.trim(configured)) == email
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

  `Slipdock.Access.grant/4` and `add_group_member/2` both used to resolve an
  unknown address by calling `get_or_create_user_by_email/1` directly. Three
  things followed, all bad: any signed-in person could mint an account for any
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
    email = email |> String.trim() |> String.downcase()

    case get_user_by_email(email) do
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
        deliver_sign_in(user, &"#{base}/login/#{&1}")
    end
  end

  ## Leaving

  @doc """
  Removes somebody and their work. The answer to "delete my account", which
  `disable/1` is not — a disabled account is still all of their data.

  Refuses on the last admin, like everything else that would leave a server
  nobody can administer.

  ## What happens to the boards they own

  Their own boards go with them, cards and all: Postgres-style cascades are
  already set up for that, and a board nobody else could ever see is theirs
  alone.

  **A board somebody else can still reach is handed over rather than deleted.**
  It goes to whoever holds the strongest remaining grant on it — a writer before
  a reader, the oldest grant breaking ties. Deleting it instead would take other
  people's work with them, and handing it to an admin would quietly give the
  operator a customer's data, which is worse than either.

  ## What survives

  Status updates and wiki revisions they wrote on boards they did not own stay
  where they are with the author nulled — the `nilify_all` already on those
  columns. The words were addressed to other people, and a page history with
  holes in it is unreadable.

  Comments are not mentioned because they carry no author in the first place
  (see `Slipdock.Boards.Comment`): there is nothing to null.
  """
  @spec delete_user(User.t()) :: {:ok, map()} | {:error, :last_admin}
  def delete_user(%User{} = user) do
    email = user.email
    # Their live sockets are keyed by session token, which the delete takes
    # with it.
    sockets = live_socket_ids(user)

    # One transaction, so a delete that fails leaves the account with its
    # boards rather than an account whose boards have already gone to
    # somebody else. The files go after the commit: bytes cannot be rolled
    # back, so they are only removed once the rows are certainly gone.
    with {:ok, {handed_over, keys}} <-
           unless_last_admin(user, fn ->
             handed_over = hand_over_shared_boards(user)
             keys = Slipdock.Boards.file_keys(from(b in Board, where: b.owner_id == ^user.id))
             Repo.delete!(user)
             {:ok, {handed_over, keys}}
           end) do
      broadcast_disconnect(sockets)
      Slipdock.Boards.remove_files(keys)

      Logger.info(
        "Deleted the account #{email}; handed #{length(handed_over)} shared board(s) on."
      )

      {:ok, %{email: email, handed_over: handed_over}}
    end
  end

  @doc """
  What `delete_user/1` would do, without doing it — for a confirmation screen
  that has to be specific to be worth reading.
  """
  @spec deletion_preview(User.t()) :: map()
  def deletion_preview(%User{} = user) do
    owned = Repo.all(from(b in Board, where: b.owner_id == ^user.id and is_nil(b.root_id)))
    {shared, alone} = Enum.split_with(owned, &shared_with_somebody?/1)

    %{
      boards_deleted: Enum.map(alone, & &1.name),
      boards_handed_over:
        Enum.map(shared, fn board ->
          %{name: board.name, to: successor(board) && successor(board).email}
        end),
      # Cards only: this is a list of what goes, and pages and files are
      # counted separately in the item total rather than being "cards".
      cards_deleted: Slipdock.Quota.used(user, :cards),
      last_admin?: last_admin?(user)
    }
  end

  # A board goes with its whole tree: sub-boards carry the root owner's id but
  # are shared through the root's grants, so asking each one for a successor
  # of its own would find nobody and let the cascade take them.
  defp hand_over_shared_boards(%User{} = user) do
    # A sub-board of theirs under somebody else's root belongs with that root.
    Repo.update_all(
      from(b in Board,
        join: r in Board,
        on: r.id == b.root_id,
        where: b.owner_id == ^user.id and r.owner_id != ^user.id,
        update: [set: [owner_id: r.owner_id]]
      ),
      []
    )

    for board <- Repo.all(from(b in Board, where: b.owner_id == ^user.id and is_nil(b.root_id))),
        successor = successor(board),
        successor != nil do
      Repo.update_all(from(b in Board, where: b.id == ^board.id or b.root_id == ^board.id),
        set: [owner_id: successor.id]
      )

      %{board: board.name, to: successor.email}
    end
  end

  defp shared_with_somebody?(%Board{} = board), do: successor(board) != nil

  # The strongest remaining claim: a writer before a reader, the oldest grant
  # breaking ties. Groups are expanded, since a grant to a group is a grant to
  # the people in it.
  defp successor(%Board{} = board) do
    Repo.one(
      from(g in Slipdock.Access.Grant,
        left_join: m in "group_members",
        on: m.group_id == g.group_id,
        join: u in User,
        on: u.id == coalesce(g.user_id, m.user_id),
        where: g.board_id == ^board.id and u.id != ^board.owner_id and is_nil(u.disabled_at),
        order_by: [desc: g.level, asc: g.inserted_at],
        limit: 1,
        select: u
      )
    )
  end

  ## Support access

  @doc """
  Gives `admin` temporary read access to `subject`'s boards, and records it.

  The access is the easy part — whoever runs the server can read the database
  regardless. What makes this worth having is that it is **visible**: it says
  why, it expires, and `support_sessions_for/1` shows the person it is about
  every one that has ever been opened on them.
  """
  @spec open_support_session(User.t(), User.t(), String.t(), keyword()) ::
          {:ok, SupportSession.t()} | {:error, Ecto.Changeset.t() | :not_admin | :self}
  def open_support_session(%User{} = admin, %User{} = subject, reason, opts \\ []) do
    cond do
      not admin?(admin) ->
        {:error, :not_admin}

      admin.id == subject.id ->
        # You can already see your own boards; a record saying otherwise would
        # be noise in the one list that has to stay readable.
        {:error, :self}

      true ->
        attrs = %{
          "admin_id" => admin.id,
          "subject_id" => subject.id,
          "reason" => reason,
          "expires_at" => opts[:expires_at]
        }

        with {:ok, session} <-
               %SupportSession{} |> SupportSession.changeset(attrs) |> Repo.insert() do
          Logger.info(
            "Support access: #{admin.email} may read #{subject.email}'s boards until " <>
              "#{session.expires_at} — #{session.reason}"
          )

          notify_of_support_session(session, admin, subject)
          {:ok, session}
        end
    end
  end

  @doc "Ends one early. Expiry does the same thing on its own."
  def end_support_session(%SupportSession{} = session) do
    session
    |> Ecto.Changeset.change(ended_at: DateTime.utc_now(:second))
    |> Repo.update()
  end

  @doc """
  Whether `admin` currently has support access to `subject`'s things.

  `Slipdock.Access` asks this, so the grant behaves like any other read access
  rather than being a separate way in with separate rules.
  """
  @spec support_access?(User.t() | nil, integer() | nil) :: boolean()
  def support_access?(%User{} = admin, subject_id) when is_integer(subject_id) do
    now = DateTime.utc_now()

    # Joined on the admin as they are now, not as they were when it was
    # opened: demoting or disabling them ends it.
    Repo.exists?(
      from(s in SupportSession,
        join: a in User,
        on: a.id == s.admin_id and a.admin == true and is_nil(a.disabled_at),
        where:
          s.admin_id == ^admin.id and s.subject_id == ^subject_id and is_nil(s.ended_at) and
            s.expires_at > ^now
      )
    )
  end

  def support_access?(_, _), do: false

  @doc "Every support session ever opened on this person, newest first."
  def support_sessions_for(%User{} = subject) do
    SupportSession
    |> where([s], s.subject_id == ^subject.id)
    |> order_by([s], desc: s.inserted_at)
    |> preload(:admin)
    |> Repo.all()
  end

  @doc "The ones in force right now, for an admin's own list."
  def live_support_sessions do
    now = DateTime.utc_now()

    SupportSession
    |> where([s], is_nil(s.ended_at) and s.expires_at > ^now)
    |> order_by([s], desc: s.inserted_at)
    |> preload([:admin, :subject])
    |> Repo.all()
  end

  def get_support_session!(id), do: Repo.get!(SupportSession, id)

  # Telling them is the point. An unannounced look at somebody's boards is the
  # thing this is supposed to make impossible.
  defp notify_of_support_session(session, admin, subject) do
    if Settings.smtp_configured?() do
      UserNotifier.deliver_support_notice(subject, admin, session)
    end
  end

  ## Terms

  @doc """
  Whether this person has yet to agree to the server's terms: true only on a
  server that has terms at all, and only until they sign in under the version
  in force. Signing in is the agreeing — the sign-in page says so — so a
  version bump is recorded at each person's next sign-in.
  """
  @spec terms_outstanding?(User.t() | nil) :: boolean()
  def terms_outstanding?(nil), do: false

  def terms_outstanding?(%User{} = user) do
    Settings.terms?() and user.terms_version != Settings.terms_version()
  end

  @doc "Records that this person agreed to the version currently in force."
  def accept_terms(%User{} = user) do
    user
    |> Ecto.Changeset.change(
      terms_accepted_at: DateTime.utc_now(:second),
      terms_version: Settings.terms_version()
    )
    |> Repo.update()
  end

  ## Changing the admin address

  @admin_email_attempts 5

  @doc """
  Starts a change of the server's admin address: sends a code to the **new**
  address, and tells the old one that somebody is trying.

  Nothing changes until the code comes back. An admin address that nobody reads
  is a silent lock-out — approval notices, invitation failures and warnings all
  go there — and a typo would be indistinguishable from a working address until
  the day it mattered.

  Returns `{:ok, :sent}` or `{:error, message}`.
  """
  @spec request_admin_email_change(String.t(), User.t()) :: {:ok, :sent} | {:error, String.t()}
  def request_admin_email_change(email, %User{} = by) do
    email = email |> String.trim() |> String.downcase()

    cond do
      not Regex.match?(~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/, email) ->
        {:error, "That doesn't look like an email address."}

      email == Settings.get().admin_email ->
        {:error, "That is already the admin address."}

      not Settings.smtp_configured?() ->
        {:error,
         "Set up a mail server first — a new admin address has to prove it can " <>
           "receive mail before it becomes the one everything is sent to."}

      true ->
        code = UserToken.generate_code()

        {_token, user_token} =
          UserToken.build_hashed_token(by, "admin_email", sent_to: email, code: code)

        Repo.insert!(user_token)

        UserNotifier.deliver_admin_email_change(email, code, by)
        warn_old_admin_address(email, by)
        {:ok, :sent}
    end
  end

  @doc """
  Finishes the change, if `code` is the one just sent. Returns
  `{:ok, email}` or `{:error, :invalid}`.
  """
  @spec confirm_admin_email_change(String.t(), User.t()) ::
          {:ok, String.t()} | {:error, :invalid | :too_many_attempts}
  def confirm_admin_email_change(code, %User{} = by) do
    # Eight digits is a lot of guesses, but not so many that an unmetered
    # form can't be ground through. Whoever is guessing is already an admin;
    # what they would win is the address every warning goes to.
    case RateLimit.hit("admin_email:confirm:#{by.id}", @admin_email_attempts, :timer.hours(1)) do
      :ok -> do_confirm_admin_email_change(code, by)
      {:error, _} -> {:error, :too_many_attempts}
    end
  end

  defp do_confirm_admin_email_change(code, by) do
    query =
      from(t in UserToken,
        where:
          t.context == "admin_email" and t.code == ^String.trim(code) and t.user_id == ^by.id and
            t.inserted_at > ago(60, "minute")
      )

    case Repo.one(query) do
      nil ->
        {:error, :invalid}

      token ->
        Repo.delete!(token)
        {:ok, _} = Settings.update(%{"admin_email" => token.sent_to})
        # They are the admin now, so they had better be able to sign in as one.
        with {:ok, user} <- get_or_create_user_by_email(token.sent_to), do: promote(user)
        {:ok, token.sent_to}
    end
  end

  # The address being replaced is told, so that somebody quietly pointing the
  # server at their own address is visible rather than silent.
  defp warn_old_admin_address(new_email, by) do
    case Settings.get().admin_email do
      nil -> :ok
      old -> UserNotifier.deliver_admin_email_warning(old, new_email, by)
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
    email = email |> String.trim() |> String.downcase()

    cond do
      Settings.signup_mode() != :approval ->
        {:error, :not_approval_mode}

      get_user_by_email(email) != nil ->
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

  @doc """
  Approves a request: makes the account and sends them a way in, so that "yes"
  is one action rather than two with a gap in which nothing happens.
  """
  @spec approve_signup(SignupRequest.t(), User.t(), (String.t() -> String.t())) ::
          {:ok, User.t()} | {:error, term()}
  def approve_signup(%SignupRequest{} = request, %User{} = admin, url_fun) do
    with {:ok, user} <- get_or_create_user_by_email(request.email),
         {:ok, _} <-
           request |> SignupRequest.decision_changeset("approved", admin) |> Repo.update() do
      # If this fails they still have an account and can ask for a link
      # themselves, so it is not worth failing the approval over.
      _ = deliver_sign_in(user, url_fun)
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
    case list_admins() do
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

  defp check_signup(email) do
    if signup_allowed?(to_string(email)) do
      :ok
    else
      Logger.info(
        "Refused a sign-in link for #{inspect(email)}: no account here, and " <>
          "registration is #{Settings.signup_mode()}. An address with no account can " <>
          "be given one with: setup --make-admin #{email}"
      )

      {:error, :not_allowed}
    end
  end

  @doc """
  The "Agentic Login" flow: mints a one-time sign-in link for `email` exactly
  like `deliver_magic_link/2`, but writes it to a fresh randomly named file
  under the configured `:agentic_login_dir` instead of emailing it. Returns
  `{:ok, path}` so an agent with shell access can read the link from `path`.

  Only available when `:agentic_login` is enabled (see `agentic_login_enabled?/0`).
  """
  def write_agentic_login(email, url_fun) when is_function(url_fun, 1) do
    with true <- agentic_login_enabled?() || {:error, :disabled},
         :ok <- check_signup(email),
         {:ok, user} <- get_or_create_user_by_email(email) do
      dir = agentic_login_dir()
      name = Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
      path = Path.join(dir, "slipdock-agentic-login-#{name}.txt")
      {token, _code} = create_magic_token(user)
      link = url_fun.(token)

      # The file is a working sign-in link, so nobody but this account may read
      # it: made empty, closed to everyone else, and only then given the link.
      with :ok <- ensure_private_dir(dir),
           :ok <- File.write(path, "", [:exclusive]),
           :ok <- File.chmod(path, 0o600),
           :ok <- File.write(path, link <> "\n") do
        {:ok, path}
      end
    end
  end

  @doc """
  Where Agentic Login writes its files: `:agentic_login_dir`, else a
  `slipdock-agentic-login` directory of its own under the system temp dir.
  """
  def agentic_login_dir do
    Application.get_env(:slipdock, :agentic_login_dir) ||
      Path.join(System.tmp_dir!(), "slipdock-agentic-login")
  end

  # A directory this creates is private to the account running the server. One
  # that already exists is left as it is: it was chosen by whoever configured it,
  # and changing the mode of something like /tmp would be far worse.
  defp ensure_private_dir(dir) do
    if File.dir?(dir) do
      :ok
    else
      with :ok <- File.mkdir_p(dir), do: File.chmod(dir, 0o700)
    end
  end

  @doc "Whether the sign-in page offers the file-based \"Agentic Login\"."
  def agentic_login_enabled?, do: Application.get_env(:slipdock, :agentic_login, false) == true

  # One row, two ways through it: a long token for the link and a short code for
  # typing. Using either consumes the row, so a code cannot outlive its link.
  defp create_magic_token(%User{} = user) do
    code = UserToken.generate_code()

    {token, user_token} =
      UserToken.build_hashed_token(user, "magic", sent_to: user.email, code: code)

    Repo.insert!(user_token)
    {token, code}
  end

  @doc """
  A one-time sign-in token for somebody whose identity has just been proved by
  other means — typing a correct code, or an admin acting deliberately.

  It exists because a LiveView cannot write to the session: the only way to
  turn "this person proved who they are" into a browser session is to send
  them through `/login/:token` like anybody else.
  """
  @spec create_sign_in_token(User.t()) :: String.t()
  def create_sign_in_token(%User{} = user) do
    {token, _code} = create_magic_token(user)
    token
  end

  @doc """
  Exchanges a sign-in code for its user, the way `verify_magic_link/1` exchanges
  a link.

  Returns `{:ok, user}`, `{:error, :invalid}`, or `{:error, :too_many}` once a
  code has been guessed at too often — six digits is a small enough space that
  the attempt counter, not the length, is what makes it safe.

  A wrong guess counts against **every** live code for that address, so asking
  for a second code is not a way to buy more attempts.
  """
  @spec verify_sign_in_code(String.t(), String.t()) ::
          {:ok, User.t()} | {:error, :invalid | :too_many}
  def verify_sign_in_code(email, code) when is_binary(email) and is_binary(code) do
    email = email |> String.trim() |> String.downcase()
    code = String.trim(code)

    case Repo.one(UserToken.verify_code_query(email, code)) do
      {%User{} = user, %UserToken{} = user_token} ->
        Repo.delete!(user_token)
        {:ok, confirm(user)}

      nil ->
        count_wrong_guess(email)
    end
  end

  def verify_sign_in_code(_, _), do: {:error, :invalid}

  defp count_wrong_guess(email) do
    {_, _} =
      Repo.update_all(from(t in UserToken.live_codes_query(email)),
        inc: [code_attempts: 1]
      )

    exhausted? =
      Repo.exists?(
        from(t in UserToken.live_codes_query(email),
          where: t.code_attempts >= ^UserToken.code_attempt_limit()
        )
      )

    if exhausted?, do: {:error, :too_many}, else: {:error, :invalid}
  end

  defp confirm(%User{confirmed_at: nil} = user) do
    user |> Ecto.Changeset.change(confirmed_at: DateTime.utc_now(:second)) |> Repo.update!()
  end

  defp confirm(user), do: user

  @doc "Exchanges a magic-link token for its user (once), confirming the account."
  def verify_magic_link(token) do
    with {:ok, query} <- UserToken.verify_magic_token_query(token),
         {%User{} = user, %UserToken{} = user_token} <- Repo.one(query) do
      Repo.delete!(user_token)

      user = confirm(user)

      {:ok, user}
    else
      _ -> :error
    end
  end

  ## Sessions

  def generate_session_token(%User{} = user) do
    {token, user_token} = UserToken.build_session_token(user)
    Repo.insert!(user_token)
    token
  end

  def get_user_by_session_token(token) do
    {:ok, query} = UserToken.verify_session_token_query(token)

    case Repo.one(query) do
      %User{disabled_at: %DateTime{}} -> nil
      user -> user
    end
  end

  def delete_session_token(token) do
    Repo.delete_all(UserToken.by_token_and_context(token, "session"))
    :ok
  end

  ## API tokens

  @doc """
  Mints an API token. `opts` takes `:scope` ("read" or "write", default
  "write"), `:scope_boards` (board ids, `[]` for the whole account) and
  `:expires_at`. The plaintext token is returned once and never stored.
  """
  def create_api_token(%User{} = user, label, opts \\ []) do
    scope = api_token_scope(user, opts[:scope])

    {token, user_token} =
      UserToken.build_hashed_token(user, "api",
        label: label,
        scope: scope,
        scope_boards: opts[:scope_boards] || [],
        expires_at: opts[:expires_at]
      )

    {token, Repo.insert!(user_token)}
  end

  # An admin-scope token is only ever minted for somebody who is an admin now.
  # One made earlier would sit dormant and wake up the day its owner was
  # promoted, carrying whatever a stolen copy of it had been waiting for.
  defp api_token_scope(user, "admin"), do: if(admin?(user), do: "admin", else: "write")
  defp api_token_scope(_user, scope) when scope in ~w(read write), do: scope
  defp api_token_scope(_user, _), do: "write"

  @doc "Days from now as an expiry, or nil for a token that never expires."
  def expiry_in_days(nil), do: nil
  def expiry_in_days(""), do: nil

  def expiry_in_days(days) when is_binary(days) do
    case Integer.parse(days) do
      {n, ""} -> expiry_in_days(n)
      _ -> nil
    end
  end

  def expiry_in_days(days) when is_integer(days) and days > 0,
    do: DateTime.utc_now(:second) |> DateTime.add(days, :day)

  def expiry_in_days(_), do: nil

  def get_user_by_api_token(token) when is_binary(token) do
    case get_api_token(token) do
      {%User{} = user, _} -> user
      _ -> nil
    end
  end

  @doc """
  The user a token belongs to *and* the token row, whose label names the agent
  holding it. Wiki revisions record that name, so history says which robot
  wrote a paragraph without a separate audit log.
  """
  def get_api_token(token, opts \\ []) when is_binary(token) do
    with {:ok, query} <- UserToken.verify_api_token_query(token),
         {%User{disabled_at: nil} = user, %UserToken{} = user_token} <- Repo.one(query) do
      # Where it was used from, as well as when: a token list that cannot
      # answer "is this still the machine I gave it to" is not much of an
      # audit trail.
      touch = [last_used_at: DateTime.utc_now(:second)]
      touch = if ip = opts[:ip], do: [{:last_used_ip, ip} | touch], else: touch

      from(t in UserToken, where: t.id == ^user_token.id) |> Repo.update_all(set: touch)

      {user, user_token}
    else
      _ -> nil
    end
  end

  def list_api_tokens(%User{} = user) do
    Repo.all(
      from(t in UserToken.by_user_and_contexts(user, ["api"]), order_by: [desc: t.inserted_at])
    )
  end

  ## Device authorization (RFC 8628) ------------------------------------------

  @doc """
  Starts a device-authorization request. Returns
  `{plaintext_device_code, record}`; the client polls with the first and shows
  the record's `user_code` to a person.

  The `admin` scope is refused with `{:error, :admin_scope}`. Whoever starts a
  request is anonymous and chooses its label, so an admin-scope request is a
  code anybody could send an admin with a friendly name on it; admin tokens are
  made on the account page, by an admin, deliberately.
  """
  def request_device_authorization(attrs \\ %{}) do
    if attrs[:scope] == "admin" do
      {:error, :admin_scope}
    else
      # Cheap, and it means the table never accumulates requests nobody
      # finished with. There is no scheduled job to forget to run.
      purge_expired_device_authorizations()

      scope = if attrs[:scope] in ~w(read write), do: attrs[:scope], else: "write"

      {device_code, record} =
        DeviceAuthorization.build(Map.put(Map.new(attrs), :scope, scope))

      {device_code, Repo.insert!(record)}
    end
  end

  @doc """
  The pending request a person's typed code refers to, or nil. Approved,
  denied and expired requests are *not* findable: a code is good once.
  """
  def device_authorization_by_user_code(input) do
    case DeviceAuthorization.normalise_code(input) do
      "" ->
        nil

      code ->
        DeviceAuthorization.pending()
        |> where([d], d.user_code == ^code)
        |> Repo.one()
    end
  end

  @doc """
  Approves a pending request on `user`'s behalf, minting their token.

  The decision is made once. The update only lands on a row that is still
  pending, so two approvals racing each other — or an approval racing a
  refusal — leave the first one standing; the loser gets `{:error, :expired}`,
  as if the code had gone, which for them it has.
  """
  def approve_device_authorization(%DeviceAuthorization{} = request, %User{} = user) do
    decide_device_authorization(request, approved_at: DateTime.utc_now(:second), user_id: user.id)
  end

  @doc "Refuses a pending request. The client is told, rather than left polling."
  def deny_device_authorization(%DeviceAuthorization{} = request) do
    decide_device_authorization(request, denied_at: DateTime.utc_now(:second))
  end

  defp decide_device_authorization(request, changes) do
    query = DeviceAuthorization.pending() |> where([d], d.id == ^request.id)

    case Repo.update_all(query, set: changes) do
      {1, _} -> {:ok, Repo.get!(DeviceAuthorization, request.id)}
      _ -> {:error, :expired}
    end
  end

  @doc """
  What the polling client gets. On approval the token is minted here, once:
  the request is consumed in the same transaction, so a device code that is
  polled twice cannot yield two tokens.

  Every failure is reported as RFC 8628 names them, and an unknown code is
  `:invalid` — the same answer a wrong code gets, so polling cannot be used to
  learn which codes exist.
  """
  def poll_device_authorization(plaintext) do
    with {:ok, hashed} <- DeviceAuthorization.hash_device_code(plaintext),
         %DeviceAuthorization{} = request <-
           Repo.one(from(d in DeviceAuthorization, where: d.device_code == ^hashed)) do
      cond do
        request.denied_at -> {:error, :access_denied}
        DeviceAuthorization.expired?(request) -> {:error, :expired_token}
        is_nil(request.approved_at) -> {:error, :authorization_pending}
        true -> mint_from_device_authorization(request)
      end
    else
      _ -> {:error, :invalid}
    end
  end

  defp mint_from_device_authorization(request) do
    Repo.transaction(fn ->
      # Consume it first. Whoever deletes the row is the one who gets to mint,
      # so a client polling twice in parallel still ends up with one token.
      case Repo.delete_all(from(d in DeviceAuthorization, where: d.id == ^request.id)) do
        {1, _} ->
          user = get_user!(request.user_id)

          {token, _row} =
            create_api_token(user, request.client_label || "Device",
              scope: request.scope,
              scope_boards: request.scope_boards,
              expires_at: expiry_in_days(90)
            )

          token

        _ ->
          Repo.rollback(:invalid)
      end
    end)
  end

  @doc "Clears out requests nobody finished with. Safe to call at any time."
  def purge_expired_device_authorizations do
    now = DateTime.utc_now()
    {count, _} = Repo.delete_all(from(d in DeviceAuthorization, where: d.expires_at <= ^now))
    count
  end

  def delete_api_token(%User{} = user, id) do
    Repo.delete_all(from(t in UserToken.by_user_and_contexts(user, ["api"]), where: t.id == ^id))
    :ok
  end

  def delete_all_sessions(%User{} = user) do
    sockets = live_socket_ids(user)
    Repo.delete_all(UserToken.by_user_and_contexts(user, ["session"]))
    broadcast_disconnect(sockets)
  end

  @doc """
  Drops every LiveView this person has open, without signing them out. Each
  one reconnects and mounts again, which re-runs the checks a mount makes —
  so a demoted admin's open `/users` tab is sent away rather than carrying on.
  """
  def disconnect_sessions(%User{} = user), do: user |> live_socket_ids() |> broadcast_disconnect()

  # The same id `SlipdockWeb.UserAuth` puts in the session at sign-in.
  defp live_socket_ids(%User{} = user) do
    from(t in UserToken.by_user_and_contexts(user, ["session"]), select: t.token)
    |> Repo.all()
    |> Enum.map(&"users_sessions:#{Base.url_encode64(&1)}")
  end

  defp broadcast_disconnect(ids) do
    Enum.each(ids, &SlipdockWeb.Endpoint.broadcast(&1, "disconnect", %{}))
  end

  ## Groups

  def get_group!(id), do: Group |> Repo.get!(id) |> Repo.preload([:owner, :members])

  @doc "Groups the user owns or belongs to."
  def list_groups(%User{} = user) do
    from(g in Group,
      left_join: m in "group_members",
      on: m.group_id == g.id,
      where: g.owner_id == ^user.id or m.user_id == ^user.id,
      distinct: true,
      order_by: [asc: g.name]
    )
    |> Repo.all()
    |> Repo.preload([:owner, :members])
  end

  def group_ids_for(%User{} = user) do
    Repo.all(from(m in "group_members", where: m.user_id == ^user.id, select: m.group_id))
  end

  def create_group(%User{} = owner, attrs) do
    %Group{owner_id: owner.id}
    |> Group.changeset(Map.put(attrs, "owner_id", owner.id))
    |> Repo.insert()
    |> case do
      {:ok, group} -> {:ok, Repo.preload(group, [:owner, :members])}
      error -> error
    end
  end

  def update_group(%Group{} = group, attrs) do
    group |> Group.changeset(attrs) |> Repo.update()
  end

  def delete_group(%Group{} = group), do: Repo.delete(group)

  def change_group(%Group{} = group, attrs \\ %{}), do: Group.changeset(group, attrs)

  @doc """
  Adds the user with `email` to the group, inviting them if this server makes
  accounts for people you share things with.

  The group's owner is the inviter: they are the one doing the sharing, and the
  one an invitation should name.
  """
  def add_group_member(%Group{} = group, email) do
    inviter = group.owner || Repo.get(User, group.owner_id)

    with {:ok, user} <- invite_user(email, inviter, to: "the group “#{group.name}”") do
      Repo.insert_all("group_members", [%{group_id: group.id, user_id: user.id}],
        on_conflict: :nothing
      )

      {:ok, get_group!(group.id)}
    end
  end

  def remove_group_member(%Group{} = group, %User{} = user) do
    Repo.delete_all(
      from(m in "group_members", where: m.group_id == ^group.id and m.user_id == ^user.id)
    )

    {:ok, get_group!(group.id)}
  end

  def group_member?(%Group{} = group, %User{} = user) do
    group.owner_id == user.id or
      Repo.exists?(
        from(m in "group_members", where: m.group_id == ^group.id and m.user_id == ^user.id)
      )
  end
end
