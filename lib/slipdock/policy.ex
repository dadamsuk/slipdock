defmodule Slipdock.Policy do
  @moduledoc """
  SPIKE #3162, not for merging: where a write asks who is writing.

  Every context function that writes calls `authorize/2` first. It reads who
  the process is acting for (`Slipdock.Actor.current/0` and
  `Slipdock.Actor.principal/0`, which every door already sets), looks the
  action up in one table, reads that person's level from the database now
  (so a level lowered while a page is open counts), narrows it by the token
  (ARCH-8) and answers `:ok` or `{:error, %Slipdock.Policy.Refused{}}`.

  Nobody acting (`Actor.unknown/0`) is refused: a write with no door behind
  it says so with `as_system/2`.
  """
  alias Slipdock.Access
  alias Slipdock.Actor
  alias Slipdock.Boards.Board
  alias Slipdock.Boards.Tag
  alias Slipdock.Repo

  defmodule Refused do
    @moduledoc "Why a write was refused: `by` is `:user`, `:token` or `:nobody`."
    defexception [:action, :need, :by, :message]
  end

  # action => {whose level, the level it needs}
  @rules %{
    create_tag: {:tree_root, :write},
    update_tag: {:tree_root, :write},
    delete_tag: {:tree_root, :write}
  }

  @system {__MODULE__, :system}

  @nobody_ok {__MODULE__, :nobody_ok}

  @doc """
  For a test's own process: a write made with no actor set is a fixture, and
  passes. A request the test makes sets its actor and is checked as itself.
  """
  def allow_nobody, do: Process.put(@nobody_ok, true)

  @doc "The table: what each action needs, and on what."
  def rules, do: @rules

  @doc "Runs `fun` as the server itself (setup, a migration of data, the demo), saying why."
  def as_system(reason, fun) when is_binary(reason) and is_function(fun, 0) do
    previous = Process.get(@system)
    Process.put(@system, reason)

    try do
      fun.()
    after
      if previous, do: Process.put(@system, previous), else: Process.delete(@system)
    end
  end

  @doc "`:ok` if this process's actor may do `action` to `subject`."
  def authorize(action, subject), do: authorize(Actor.current(), action, subject)

  def authorize(actor, action, subject) when is_map_key(@rules, action) do
    {scope, need} = Map.fetch!(@rules, action)

    cond do
      Process.get(@system) -> :ok
      actor.kind == "automation" -> :ok
      is_nil(actor.kind) and Process.get(@nobody_ok) -> :ok
      is_nil(actor.kind) -> refuse(action, need, :nobody)
      true -> decide(action, need, board_for(scope, subject))
    end
  end

  defp decide(action, need, %Board{} = board) do
    {user, token} = Actor.principal()
    level = Access.board_permission_now(user, board)
    {narrowed, reason} = Access.narrow(level, token, board.id)

    cond do
      rank(narrowed) >= rank(need) -> :ok
      reason == :scope -> refuse(action, need, :token)
      true -> refuse(action, need, :user)
    end
  end

  defp rank(level), do: Enum.find_index(~w(none view read comment write owner)a, &(&1 == level))

  defp board_for(:tree_root, %Tag{board_id: id}), do: Repo.get!(Board, id)
  defp board_for(:tree_root, %Board{root_id: nil} = board), do: board
  defp board_for(:tree_root, %Board{root_id: id}), do: Repo.get!(Board, id)

  defp refuse(action, need, by) do
    who = %{user: "you", token: "this token", nobody: "nobody (no actor was set)"}[by]

    {:error,
     %Refused{
       action: action,
       need: need,
       by: by,
       message: "#{action} needs #{need}, which #{who} can't"
     }}
  end
end
