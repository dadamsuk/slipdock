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

  alias Slipdock.Access
  alias Slipdock.Boards.Board
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
  root board `board_id`, or mail it (`Slipdock.Access.others_write_on_tree?/2`).
  """
  @spec shared?(integer, integer | nil) :: boolean
  def shared?(board_id, owner_id) do
    case Repo.get(Board, board_id) do
      nil -> false
      %Board{} = board -> Access.others_write_on_tree?(board, owner_id)
    end
  end
end
