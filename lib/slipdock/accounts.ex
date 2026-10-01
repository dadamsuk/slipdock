defmodule Slipdock.Accounts do
  @moduledoc """
  Users, passwordless sign-in by emailed magic link, browser sessions
  (valid for 30 days), API tokens, and groups of users.
  """
  import Ecto.Query, warn: false

  require Logger
  alias Slipdock.Repo
  alias Slipdock.Accounts.{Group, User, UserNotifier, UserToken}

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
      path = Path.join(dir, "kanban-agentic-login-#{name}.txt")
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

  @doc "Creates a labelled API token; the plain token is returned once."
  def create_api_token(%User{} = user, label) do
    {token, user_token} = UserToken.build_hashed_token(user, "api", label: label)
    {token, Repo.insert!(user_token)}
  end

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
  def get_api_token(token) when is_binary(token) do
    with {:ok, query} <- UserToken.verify_api_token_query(token),
         {%User{} = user, %UserToken{} = user_token} <- Repo.one(query) do
      from(t in UserToken, where: t.id == ^user_token.id)
      |> Repo.update_all(set: [last_used_at: DateTime.utc_now(:second)])

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
