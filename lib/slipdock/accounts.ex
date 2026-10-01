defmodule Slipdock.Accounts do
  @moduledoc """
  Users, passwordless sign-in by emailed magic link, browser sessions
  (valid for 30 days), API tokens, and groups of users.
  """
  import Ecto.Query, warn: false

  require Logger
  alias Slipdock.Repo
  alias Slipdock.Accounts.{DeviceAuthorization, Group, User, UserNotifier, UserToken}

  ## Users

  def get_user!(id), do: Repo.get!(User, id)
  def get_user(id), do: Repo.get(User, id)

  def get_user_by_email(email) when is_binary(email) do
    Repo.get_by(User, email: email |> String.trim() |> String.downcase())
  end

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

  ## Magic links

  @doc """
  Emails `email` a one-time sign-in link built with `url_fun.(token)`.

  Returns `{:error, :not_allowed}` when this server will not make an account
  for that address (see `signup_allowed?/1`). The caller should not tell the
  visitor which of the two happened — that would say who has an account here.
  """
  def deliver_magic_link(email, url_fun) when is_function(url_fun, 1) do
    with :ok <- check_signup(email),
         {:ok, user} <- get_or_create_user_by_email(email) do
      UserNotifier.deliver_magic_link(user, url_fun.(create_magic_token(user)))
    end
  end

  @doc """
  Whether this address may sign in, which for a new address means whether it
  may have an account at all. In order:

    * somebody who already has an account always can;
    * so can the very first address, on an instance with no users — the first
      sign-in claims the server;
    * `config :slipdock, :signups, open: true` (`SLIPDOCK_OPEN_SIGNUP=true`) lets
      anyone in, which is what this did before and is only sensible behind a
      network boundary of your own;
    * otherwise the address must match `:allow` (`SLIPDOCK_SIGNUP_ALLOW`): a
      list of addresses and of domains, where `example.com` means anybody
      there.

  The default is therefore "the owner, and nobody else" — a server reachable
  by strangers does not quietly collect accounts.
  """
  def signup_allowed?(email) when is_binary(email) do
    email = email |> String.trim() |> String.downcase()

    cond do
      email == "" -> false
      get_user_by_email(email) != nil -> true
      count_users() == 0 -> true
      signups()[:open] == true -> true
      true -> allowed_by_list?(email, signups()[:allow] || [])
    end
  end

  def signup_allowed?(_), do: false

  @doc "Whether a brand-new address could sign up right now, for the UI's wording."
  def signups_open?, do: signups()[:open] == true or count_users() == 0

  defp check_signup(email) do
    if signup_allowed?(to_string(email)) do
      :ok
    else
      Logger.info("Refused a sign-in link for #{inspect(email)}: not allowed to sign up here")
      {:error, :not_allowed}
    end
  end

  defp allowed_by_list?(email, allow) do
    domain = email |> String.split("@") |> List.last()

    Enum.any?(allow, fn entry ->
      entry =
        entry |> to_string() |> String.trim() |> String.downcase() |> String.trim_leading("@")

      entry != "" and (entry == email or entry == domain)
    end)
  end

  defp signups, do: Application.get_env(:slipdock, :signups, [])

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
      dir = Application.get_env(:slipdock, :agentic_login_dir, "/tmp")
      name = Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
      path = Path.join(dir, "slipdock-agentic-login-#{name}.txt")
      link = url_fun.(create_magic_token(user))

      with :ok <- File.mkdir_p(dir),
           :ok <- File.write(path, link <> "\n", [:exclusive]) do
        {:ok, path}
      end
    end
  end

  @doc "Whether the sign-in page offers the file-based \"Agentic Login\"."
  def agentic_login_enabled?, do: Application.get_env(:slipdock, :agentic_login, false) == true

  defp create_magic_token(%User{} = user) do
    {token, user_token} = UserToken.build_hashed_token(user, "magic", sent_to: user.email)
    Repo.insert!(user_token)
    token
  end

  @doc "Exchanges a magic-link token for its user (once), confirming the account."
  def verify_magic_link(token) do
    with {:ok, query} <- UserToken.verify_magic_token_query(token),
         {%User{} = user, %UserToken{} = user_token} <- Repo.one(query) do
      Repo.delete!(user_token)

      user =
        if user.confirmed_at,
          do: user,
          else:
            user
            |> Ecto.Changeset.change(confirmed_at: DateTime.utc_now(:second))
            |> Repo.update!()

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
    Repo.one(query)
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
    scope = if opts[:scope] in UserToken.scopes(), do: opts[:scope], else: "write"

    {token, user_token} =
      UserToken.build_hashed_token(user, "api",
        label: label,
        scope: scope,
        scope_boards: opts[:scope_boards] || [],
        expires_at: opts[:expires_at]
      )

    {token, Repo.insert!(user_token)}
  end

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
         {%User{} = user, %UserToken{} = user_token} <- Repo.one(query) do
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
  """
  def request_device_authorization(attrs \\ %{}) do
    # Cheap, and it means the table never accumulates requests nobody
    # finished with. There is no scheduled job to forget to run.
    purge_expired_device_authorizations()

    scope = if attrs[:scope] in UserToken.scopes(), do: attrs[:scope], else: "write"

    {device_code, record} =
      DeviceAuthorization.build(Map.put(Map.new(attrs), :scope, scope))

    {device_code, Repo.insert!(record)}
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

  @doc "Approves a pending request on `user`'s behalf, minting their token."
  def approve_device_authorization(%DeviceAuthorization{} = request, %User{} = user) do
    if DeviceAuthorization.expired?(request) do
      {:error, :expired}
    else
      request
      |> Ecto.Changeset.change(
        approved_at: DateTime.utc_now(:second),
        user_id: user.id
      )
      |> Repo.update()
    end
  end

  @doc "Refuses a pending request. The client is told, rather than left polling."
  def deny_device_authorization(%DeviceAuthorization{} = request) do
    request
    |> Ecto.Changeset.change(denied_at: DateTime.utc_now(:second))
    |> Repo.update()
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
    Repo.delete_all(UserToken.by_user_and_contexts(user, ["session"]))
    :ok
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

  @doc "Adds the user with `email` (created if needed) to the group."
  def add_group_member(%Group{} = group, email) do
    with {:ok, user} <- get_or_create_user_by_email(email) do
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
