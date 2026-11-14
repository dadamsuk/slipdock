defmodule Slipdock.Policy do
  @moduledoc """
  Where a write asks who is writing (#3162, #3167; W-1945 §Permissions,
  *Where authorisation lives*).

  A context function that writes calls `authorize/2` before it writes and
  answers `{:error, %Slipdock.Policy.Refused{}}` when it is refused. Nothing
  above the context can skip it, so a door that forgets its own check is
  refused anyway.

  It reads who the process is acting for (`Slipdock.Actor.current/0`, and
  the user and API token kept beside it, `Slipdock.Actor.principal/0`),
  looks the action up in one table (`rules/0`: `action => {scope, level}`),
  reads that person's level on the scope from the database now, so a level
  lowered while a page is open counts, and narrows it by the token (ARCH-8).
  The refusal says which of the two was short.

  Who passes without a level:

    * a rule's write, as the board's own (`:automation_depth`);
    * the server's own write, when it says so: `as_system/2`, with why.

  Nobody acting (no actor on the process, as in a `Task` nobody told) is
  refused. A test's own process may write as nobody (`allow_nobody/0`, which
  `Slipdock.DataCase` sets): those writes are its fixtures.

  Contexts not yet migrated are listed in `test/support/unchecked_writes.txt`;
  `test/slipdock/unchecked_writes_test.exs` holds the rest to asking.
  """

  alias Slipdock.Access
  alias Slipdock.Accounts
  alias Slipdock.Accounts.User
  alias Slipdock.Actor
  alias Slipdock.Boards.Board
  alias Slipdock.Boards.Card
  alias Slipdock.Boards.Tag
  alias Slipdock.Repo

  defmodule Refused do
    @moduledoc """
    Why a write was refused. `by` is who was short: `:user` (the person's
    level), `:token` (the API token's scope narrowed it, ARCH-8) or `:nobody`
    (no actor was set). `need` is the level the action needs on `scope`.
    """
    defexception [:action, :scope, :need, :by, :message]
  end

  # action => {whose level counts, the level it needs}
  #
  # Scopes: `:tree_root` is the root of the subject's board tree (tags are
  # the tree's, DATA-9); `:card` is the card itself, raised by a grant on it.
  @rules %{
    create_tag: {:tree_root, :write},
    update_tag: {:tree_root, :write},
    delete_tag: {:tree_root, :write},
    toggle_card_tag: {:card, :write}
  }

  @what %{
    create_tag: "Making a tag",
    update_tag: "Changing a tag",
    delete_tag: "Deleting a tag",
    toggle_card_tag: "Tagging a card"
  }

  @where %{tree_root: "the top board of its tree", card: "the card"}

  @system {__MODULE__, :system}
  @nobody_ok {__MODULE__, :nobody_ok}

  @doc "The table: what each action needs, and on what."
  def rules, do: @rules

  @doc """
  `:ok` if this process's actor may do `action` to `subject`, else
  `{:error, %Refused{}}`. `opts[:actor]` asks for that actor instead.
  """
  def authorize(action, subject, opts \\ []) when is_map_key(@rules, action) do
    {scope, need} = Map.fetch!(@rules, action)
    actor = opts[:actor] || Actor.current()

    cond do
      Process.get(@system) -> :ok
      actor.kind == "automation" -> :ok
      true -> decide(action, scope, need, subject, actor)
    end
  end

  @doc """
  Whether this process's actor may do `action` to `subject`: what a door
  draws a button from, asked of the same table as the write, so the two
  can't disagree.
  """
  def can?(action, subject, opts \\ []), do: authorize(action, subject, opts) == :ok

  @doc """
  Runs `fun` as the server itself, saying why: a write no person or token is
  behind (setup, the demo, a carrier whose own gate has decided). Nested
  calls keep the outer reason.
  """
  def as_system(reason, fun) when is_binary(reason) and reason != "" and is_function(fun, 0) do
    previous = Process.get(@system)
    Process.put(@system, previous || reason)

    try do
      fun.()
    after
      if previous, do: Process.put(@system, previous), else: Process.delete(@system)
    end
  end

  @doc "Why this process is writing as the server, or nil (see `as_system/2`)."
  def system_reason, do: Process.get(@system)

  @doc """
  For a test's own process: a write made with no actor set is a fixture, and
  passes. A request the test makes sets its actor and is checked as itself.
  `Slipdock.DataCase` calls it for every test; a test of the refusal itself
  calls `forbid_nobody/0`.
  """
  def allow_nobody, do: Process.put(@nobody_ok, true)

  @doc "Undoes `allow_nobody/0`: nobody acting is refused again, as outside a test."
  def forbid_nobody, do: Process.delete(@nobody_ok)

  ## Deciding ------------------------------------------------------------------

  defp decide(action, scope, need, subject, actor) do
    case user_for(actor) do
      nil ->
        if Process.get(@nobody_ok), do: :ok, else: refuse(action, scope, need, :nobody)

      %User{} = user ->
        token = token_for(user)
        {level, board_id} = level(scope, user, subject)
        {narrowed, reason} = Access.narrow(level, token, board_id)

        cond do
          rank(narrowed) >= rank(need) -> :ok
          reason == :scope -> refuse(action, scope, need, :token)
          true -> refuse(action, scope, need, :user)
        end
    end
  end

  @ranks ~w(none view read comment write owner)a
  defp rank(level), do: Enum.find_index(@ranks, &(&1 == level)) || 0

  # The person behind the actor: the one the door kept beside it, else the
  # actor's own user id (a door that set only the actor, or `opts[:actor]`).
  defp user_for(%{user_id: nil}), do: nil

  defp user_for(%{user_id: id}) do
    case Actor.principal() do
      {%User{id: ^id} = user, _token} -> user
      _ -> Accounts.get_user(id)
    end
  end

  defp user_for(_), do: nil

  # The token narrows only the user it was issued to.
  defp token_for(%User{id: id}) do
    case Actor.principal() do
      {%User{id: ^id}, token} -> token
      _ -> nil
    end
  end

  # {the level, the board the token's scope is checked against}
  defp level(:tree_root, user, subject) do
    case root_board(subject) do
      nil -> {:none, nil}
      root -> {Access.board_permission(user, root), root.id}
    end
  end

  defp level(:card, user, %Card{id: id}) do
    case Repo.get(Card, id) do
      nil -> {:none, nil}
      card -> {Access.card_permission(user, card), card.board_id}
    end
  end

  # Read again: the root a struct names can have moved (a board moved into
  # another tree) or gone.
  defp root_board(%Tag{board_id: id}), do: Repo.get(Board, id)

  defp root_board(%Board{id: id}) do
    case Repo.get(Board, id) do
      nil -> nil
      %Board{root_id: nil} = board -> board
      %Board{root_id: root_id} -> Repo.get(Board, root_id)
    end
  end

  defp refuse(action, scope, need, by) do
    what = Map.fetch!(@what, action)
    where = Map.fetch!(@where, scope)

    message =
      case by do
        :user ->
          "#{what} needs #{need} access to #{where}, and you don't have it."

        :token ->
          "#{what} needs #{need} access to #{where}, and this API token's scope doesn't allow it."

        :nobody ->
          "#{what} was asked with nobody acting: no person, token or rule is behind it."
      end

    {:error, %Refused{action: action, scope: scope, need: need, by: by, message: message}}
  end
end
