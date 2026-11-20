defmodule Slipdock.Runners.PoolGrants do
  @moduledoc """
  Who takes a runner pool's jobs (#3492; W-1944 §Runners and jobs).

  A pool's jobs are its board tree's: a runner on the pool moves their
  cards, works them and finishes verify and merge jobs. So taking them is
  the root board's owner's, and a writer's only once the owner grants them
  that pool (`grant/4`). Every door that takes a job asks `may_take?/3`
  (through `check/3` or `runner_may_take?/1`): a session's claim, a machine
  runner added to the pool or moved onto it, and every claim and reclaim a
  runner makes, so a runner already in the pool takes nothing once its
  person loses the grant or their write on the board.
  """
  import Ecto.Query

  alias Slipdock.{Access, Accounts, Policy, Repo}
  alias Slipdock.Accounts.User
  alias Slipdock.Boards.Board
  alias Slipdock.Machines.Machine
  alias Slipdock.Runners.{PoolGrant, Runner}

  @doc "A pool's name as it is stored: trimmed and lower case."
  def normalize(pool) when is_binary(pool), do: pool |> String.trim() |> String.downcase()
  def normalize(pool), do: pool |> to_string() |> normalize()

  @doc "Whether `user` takes `pool`'s jobs on `board`'s tree: `Access.may_take_pool?/3`."
  defdelegate may_take?(user, board, pool), to: Access, as: :may_take_pool?

  @doc """
  Whether `runner` may take its pool's jobs, read afresh (a grant can be
  taken back while it waits for one). A runner is its person's: whoever
  made it (a session's), or the owner of its machine. A runner with a token
  of its own and no maker on record was made by the board's owner, the
  only person who can make one.
  """
  def runner_may_take?(%Runner{machine_id: machine_id, board_id: root_id, pool: pool})
      when is_integer(machine_id) do
    owner = Repo.one(from(m in Machine, where: m.id == ^machine_id, select: m.user_id))
    may_take?(owner, root_id, pool)
  end

  def runner_may_take?(%Runner{created_by_id: nil, api_token_id: nil}), do: true

  def runner_may_take?(%Runner{created_by_id: user_id, board_id: root_id, pool: pool}),
    do: may_take?(user_id, root_id, pool)

  @doc """
  `:ok` when `user` takes `pool`'s jobs on `board`'s tree, else
  `{:error, :forbidden, message}` saying why and who can change it.
  """
  def check(user, %Board{} = board, pool) do
    pool = normalize(pool)

    if may_take?(user, board, pool),
      do: :ok,
      else: {:error, :forbidden, refusal(pool)}
  end

  @doc "What a door says to somebody who may not take `pool`'s jobs."
  def refusal(pool),
    do:
      "taking the pool “#{pool}”'s jobs needs the board's owner, or a grant " <>
        "for that pool from them (the board's Runners panel, or `slipdock pool-grant`)"

  @doc "The grants on `board`'s tree, by pool and then email, with their users."
  def list(%Board{} = board) do
    root_id = Board.root_id(board)

    from(g in PoolGrant,
      join: u in assoc(g, :user),
      where: g.board_id == ^root_id,
      order_by: [asc: g.pool, asc: u.email],
      preload: [user: u, granted_by: []]
    )
    |> Repo.all()
  end

  @doc """
  Grants `pool` on `board`'s tree to the person with `email`, as the root
  board's owner (`Slipdock.Policy` `:share_pool`). They must already be
  able to write the root board. Granting it again changes nothing.
  Returns `{:ok, grant}`, `{:error, %Policy.Refused{}}` or
  `{:error, :invalid, message}`.
  """
  def grant(%Board{} = board, pool, email, opts \\ []) do
    root = root(board)
    pool = normalize(pool)

    with :ok <- Policy.authorize(:share_pool, root, opts),
         :ok <- valid_pool(pool),
         {:ok, user} <- writer(root, email) do
      by = Policy.user_id(opts)

      %PoolGrant{board_id: root.id, pool: pool, user_id: user.id, granted_by_id: by}
      |> Ecto.Changeset.change()
      |> Ecto.Changeset.unique_constraint([:board_id, :pool, :user_id],
        name: :runner_pool_grants_board_id_pool_user_id_index
      )
      |> Repo.insert(on_conflict: :nothing)
      |> case do
        {:ok, %PoolGrant{id: nil}} -> {:ok, fetch(root.id, pool, user.id)}
        {:ok, grant} -> {:ok, Repo.preload(grant, [:user, :granted_by])}
        {:error, changeset} -> {:error, :invalid, Slipdock.ChangesetErrors.message(changeset)}
      end
    end
  end

  @doc """
  Takes back the grant of `pool` on `board`'s tree from the person with
  `email`, as the root board's owner. Their runners on the pool stop taking
  its jobs at their next claim; a job one holds now is theirs to finish.
  Returns `:ok`, `{:error, %Policy.Refused{}}` or `{:error, :not_found}`.
  """
  def revoke(%Board{} = board, pool, email, opts \\ []) do
    root = root(board)
    pool = normalize(pool)

    with :ok <- Policy.authorize(:share_pool, root, opts) do
      user = is_binary(email) && Accounts.get_user_by_email(email)

      case user &&
             Repo.delete_all(
               from(g in PoolGrant,
                 where: g.board_id == ^root.id and g.pool == ^pool and g.user_id == ^user.id
               )
             ) do
        {n, _} when n > 0 -> :ok
        _ -> {:error, :not_found}
      end
    end
  end

  defp fetch(root_id, pool, user_id) do
    Repo.one!(
      from(g in PoolGrant,
        where: g.board_id == ^root_id and g.pool == ^pool and g.user_id == ^user_id,
        preload: [:user, :granted_by]
      )
    )
  end

  defp writer(root, email) do
    user = is_binary(email) && Accounts.get_user_by_email(String.trim(email))

    cond do
      not is_struct(user, User) ->
        {:error, :invalid,
         "nobody with that email can write this board: share it with them first"}

      user.id == root.owner_id ->
        {:error, :invalid, "the board's owner takes every pool's jobs already"}

      not Access.can_write?(Access.board_permission(user, root)) ->
        {:error, :invalid, "#{user.email} can't write this board: share it with them first"}

      true ->
        {:ok, user}
    end
  end

  defp valid_pool(pool) do
    if Regex.match?(Runner.name_format(), pool),
      do: :ok,
      else: {:error, :invalid, "pool “#{pool}” must be lower case letters, digits, - or _"}
  end

  defp root(%Board{} = board), do: root(Board.root_id(board))
  defp root(id) when is_integer(id), do: Repo.get(Board, id)
end
