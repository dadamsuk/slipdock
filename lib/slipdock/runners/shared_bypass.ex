defmodule Slipdock.Runners.SharedBypass do
  @moduledoc """
  The riskiest way to set a machine's runner, flagged where it is set
  (#3482): permission mode `bypassPermissions` with the `me` executor, on a
  board that someone besides the machine's owner can write or comment on.

  Such a runner's agent runs any command without asking, as the machine's
  own user, and the people who write on its board write its prompt. Nothing
  is refused: the machine's ceiling decides what a runner may be. The
  warning is on the runner's JSON (`warnings`, which `machine add-runner`,
  `set-runner` and `show` print) and on the Machines page. The daemon logs
  its own warning for the same settings when it starts the runner, since it
  can't see who shares the board.

  A board is shared when anyone but the machine's owner owns it, holds a
  `comment` or `write` grant on it, a board in its tree or a card on one
  (a group's grant counts whoever is in it), or may mail it
  (`inbound_senders`).
  """

  import Ecto.Query

  alias Slipdock.Access.Grant
  alias Slipdock.Boards.{Board, Card}
  alias Slipdock.Repo
  alias Slipdock.Runners.{Config, Runner}

  @warning "This runner lets its agent run any command without asking (`bypassPermissions`), " <>
             "as this machine's own user with nothing in the way (executor `me`), on a board " <>
             "other people can write or comment on: what they write can have it run commands " <>
             "here as you. Use `acceptEdits` or lower, or the `user`, `confined` or " <>
             "`container` executor, unless you trust everyone who can write on the board."

  @doc "The warning's text."
  def warning, do: @warning

  @doc "The warnings for a machine's runner as it is set now: `[]` or the one above."
  @spec warnings(Runner.t()) :: [String.t()]
  def warnings(%Runner{machine_id: nil}), do: []

  def warnings(%Runner{} = runner) do
    if risky?(runner.config) and shared?(runner.board_id, runner.created_by_id),
      do: [@warning],
      else: []
  end

  @doc "Whether a runner's config is `bypassPermissions` under the `me` executor."
  @spec risky?(map | nil) :: boolean
  def risky?(config) do
    case Config.load(config || %{}) do
      %Config{permission_mode: "bypassPermissions", executor: "me"} -> true
      _ -> false
    end
  end

  @doc """
  Whether anyone but `owner_id` can write or comment on the tree under the
  root board `board_id`, or mail it.
  """
  @spec shared?(integer, integer | nil) :: boolean
  def shared?(_board_id, nil), do: true

  def shared?(board_id, owner_id) do
    case Repo.get(Board, board_id) do
      nil -> false
      %Board{} = board -> board_shared?(board, owner_id)
    end
  end

  defp board_shared?(board, owner_id) do
    root = Board.root_id(board)

    board.owner_id != owner_id or (board.inbound_senders || []) != [] or
      Repo.exists?(
        from(g in Grant,
          left_join: b in Board,
          on: b.id == g.board_id,
          left_join: c in Card,
          on: c.id == g.card_id,
          left_join: cb in Board,
          on: cb.id == c.board_id,
          where: g.level in ["comment", "write"],
          where: is_nil(g.user_id) or g.user_id != ^owner_id,
          where: b.id == ^root or b.root_id == ^root or cb.id == ^root or cb.root_id == ^root
        )
      )
  end
end
