defmodule Slipdock.WaitRoutes do
  @moduledoc """
  Who a question goes to (#1949, W-1944 §Waits). A board's `wait_routes`
  maps each kind of question an agent asks (`product`, `ux`, `security`,
  `release`, `other`) to one or more of the board's users: the first is who
  the wait is on, and the rest are told. The table is empty by default.

  A wait opened with a kind (`question`) goes to the first user its kind
  names, on the card's board or the nearest board above it with a route for
  that kind. A wait with no kind asks as `other`. With no route:

    * a wait given a kind is on the tree's owner;
    * a wait given none waits on anyone, as before routing, which "Waiting
      on you" shows the tree's owner.

  A wait that names its person (`on`) goes to them, routes or not.

  The server's own questions route too: the rejection-limit wait asks as
  `release`, and an audit disagreement's alert is emailed to `release`'s
  users. A routed user who leaves the board (their grant is revoked) is
  taken off its routes, and the open waits on them in the tree go to the
  owner, with a comment saying so (`user_left/2`).

  Set at every door: board settings, `slipdock set-board --route
  KIND=EMAIL[,EMAIL]` / `--no-route KIND`, `PATCH /api/boards/:board`
  `{"wait_routes": {...}}` and MCP `update_board` `wait_routes`.
  """

  import Ecto.Query

  alias Slipdock.{Access, Accounts, Boards, Repo}
  alias Slipdock.Accounts.User
  alias Slipdock.Boards.{Board, Card, Wait}

  @kinds ~w(product ux security release other)

  @doc "The kinds of question, in the order they are shown."
  def kinds, do: @kinds

  @doc "The kind a wait with none asks as."
  def default_kind, do: "other"

  @doc """
  The board's routes as people: `%{kind => [%User{}]}`, every kind present
  (an empty list when it has none), users in order, deleted ones left out.
  """
  def routes(%Board{wait_routes: routes}) do
    routes = routes || %{}
    ids = routes |> Map.values() |> List.flatten() |> Enum.uniq()
    users = Repo.all(from(u in User, where: u.id in ^ids)) |> Map.new(&{&1.id, &1})

    Map.new(@kinds, fn kind ->
      {kind, routes |> Map.get(kind, []) |> Enum.map(&users[&1]) |> Enum.reject(&is_nil/1)}
    end)
  end

  @doc """
  Changes `board`'s routes. `changes` maps a kind to its users, as emails or
  ids: a list, or one comma-separated string. A blank or empty value takes
  the kind's route off; a kind left out is left as it is. Every user must be
  able to read the board. Returns `{:ok, board}` or `{:error, message}`.
  """
  def set(%Board{} = board, changes) when is_map(changes) do
    with {:ok, resolved} <- resolve_changes(board, changes) do
      merged =
        Enum.reduce(resolved, board.wait_routes || %{}, fn
          {kind, []}, acc -> Map.delete(acc, kind)
          {kind, ids}, acc -> Map.put(acc, kind, ids)
        end)

      Boards.set_wait_routes(board, merged)
    end
  end

  def set(_board, _changes),
    do: {:error, "wait_routes is a map of question kinds to users' emails"}

  defp resolve_changes(board, changes) do
    Enum.reduce_while(changes, {:ok, []}, fn {kind, value}, {:ok, acc} ->
      kind = kind |> to_string() |> String.trim() |> String.downcase()

      with :ok <- known_kind(kind),
           {:ok, ids} <- users(board, value) do
        {:cont, {:ok, [{kind, ids} | acc]}}
      else
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp known_kind(kind) do
    if Enum.member?(@kinds, kind),
      do: :ok,
      else:
        {:error, "wait_routes: “#{kind}” isn't a kind of question: #{Enum.join(@kinds, ", ")}"}
  end

  defp users(_board, value) when value in [nil, "", []], do: {:ok, []}

  defp users(board, value) when is_binary(value),
    do: users(board, String.split(value, ",", trim: true))

  defp users(board, value) when is_list(value) do
    value
    |> Enum.map(&(&1 |> to_string() |> String.trim()))
    |> Enum.reject(&(&1 == ""))
    |> Enum.reduce_while({:ok, []}, fn ref, {:ok, acc} ->
      case user_on_board(board, ref) do
        %User{id: id} -> {:cont, {:ok, acc ++ [id]}}
        nil -> {:halt, {:error, "wait_routes: #{ref} isn't a user of this board"}}
      end
    end)
    |> case do
      {:ok, ids} -> {:ok, Enum.uniq(ids)}
      error -> error
    end
  end

  defp users(_board, _value),
    do: {:error, "wait_routes: a kind takes a list of users' emails"}

  # The same answer for an address nobody has and one with no access, so
  # the table can't be used to find out who has an account.
  defp user_on_board(board, ref) do
    user =
      case Integer.parse(ref) do
        {id, ""} -> Repo.get(User, id)
        _ -> Accounts.get_user_by_email(ref)
      end

    if user && Access.can_read?(Access.board_permission(user, board)), do: user
  end

  @doc """
  Where a wait on `card` asking `question` goes: `{on, told}`, the person it
  is on and the others its route names (only those who can read the card).
  `on` is nil when no board from the card's up has a route for it.
  """
  def place(%Card{} = card, question) do
    kind = question || default_kind()

    card
    |> board_chain()
    |> Enum.find_value({nil, []}, fn board ->
      case board |> routes() |> Map.get(kind, []) |> Enum.filter(&reads?(&1, card)) do
        [] -> nil
        [on | told] -> {on, told}
      end
    end)
  end

  @doc "The users `board`'s tree routes `kind` to, nearest board first: [] when none."
  def users_for(%Card{} = card, kind) do
    case place(card, kind) do
      {nil, _} -> []
      {on, told} -> [on | told]
    end
  end

  @doc """
  Emails `subject` and `body` about `card` to the users the tree routes
  `kind` to (an audit disagreement goes to `release`'s, #1949). Nobody when
  there is no route: the alert on the board is how the owner hears.
  """
  def tell(%Card{} = card, kind, subject, body) do
    for %User{email: email} <- users_for(card, kind) do
      Slipdock.Deferred.defer(fn ->
        Slipdock.Automations.Notifier.deliver([email], subject, body, card: card)
      end)
    end

    :ok
  end

  # The card's board, then each board above it, the root last.
  defp board_chain(%Card{board_id: board_id}) do
    ids = Boards.PubSub.ancestor_board_ids(board_id)
    boards = Repo.all(from(b in Board, where: b.id in ^ids)) |> Map.new(&{&1.id, &1})
    ids |> Enum.map(&boards[&1]) |> Enum.reject(&is_nil/1)
  end

  defp reads?(user, card), do: Access.can_read?(Access.card_permission(user, card))

  @doc """
  Somebody's access to `board` was taken away: for each of `user_ids` who
  can no longer read it, their routes on the board's tree come off, and the
  open waits on them in the tree go to the tree's owner, with a comment on
  each card saying why.
  """
  def user_left(%Board{} = board, user_ids) do
    root = root(board)
    tree = Slipdock.Quality.tree_ids(root)

    for id <- Enum.uniq(user_ids),
        %User{} = user <- [Repo.get(User, id)],
        user.id != root.owner_id,
        not Access.can_read?(Access.board_permission(user, board)) do
      drop_from_routes(tree, user.id)
      move_waits(tree, user, root.owner_id)
    end

    :ok
  end

  defp drop_from_routes(tree, user_id) do
    for b <- Repo.all(from(b in Board, where: b.id in ^tree)),
        routes = b.wait_routes || %{},
        Enum.any?(routes, fn {_k, ids} -> Enum.member?(ids, user_id) end) do
      kept =
        routes
        |> Map.new(fn {k, ids} -> {k, List.delete(ids, user_id)} end)
        |> Map.reject(fn {_k, ids} -> ids == [] end)

      Boards.set_wait_routes(b, kept)
    end
  end

  defp move_waits(tree, user, owner_id) do
    from(w in Wait,
      join: c in Card,
      on: c.id == w.card_id,
      where: c.board_id in ^tree and is_nil(w.closed_at) and w.on_user_id == ^user.id
    )
    |> Repo.all()
    |> Enum.each(fn wait ->
      Boards.Waits.move_wait(
        wait,
        owner_id,
        "#{User.display_name(user)} is no longer on the board, so the wait goes to the board's owner"
      )
    end)
  end

  defp root(%Board{root_id: nil} = board), do: board
  defp root(%Board{root_id: id}), do: Repo.get!(Board, id)
end
