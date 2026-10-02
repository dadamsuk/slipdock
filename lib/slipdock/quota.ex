defmodule Slipdock.Quota do
  @moduledoc """
  How many cards a free account's own boards may hold.

  Blank on a self-hosted install, which is the default, and the whole mechanism
  is then inert. It exists for running Slipdock for other people: a free
  account gets a limited number of cards and pays for more.

  ## Whose cards

  **The board owner's.** Not the card's creator. Per-creator is simpler to
  explain, but it means an invited colleague hits a wall while working on *your*
  paid board, which reads as broken software. Per-owner means the person who
  would be billed is the person who is counted, and sharing a board with
  somebody never hands them a bill.

  Sub-boards belong to their root board's owner, so a tree counts once, against
  whoever owns the top of it.

  ## Which cards

  Non-archived ones. Archiving frees quota, which is gameable in principle — but
  a limit you can only escape by permanently deleting work generates support
  mail, and the point is a nudge towards subscribing, not a vault.

  Wiki pages do not count. A limit nobody can predict is worse than a generous
  one, and "cards" is what the setting says.
  """
  import Ecto.Query, warn: false

  alias Slipdock.Accounts.User
  alias Slipdock.Boards.{Board, Card, Column}
  alias Slipdock.Repo
  alias Slipdock.Settings

  @doc """
  How many cards count against this person: every non-archived card on a board
  they own, sub-boards included.

  One aggregate query — this runs on every card creation.
  """
  @spec used(User.t() | integer() | nil) :: non_neg_integer()
  def used(nil), do: 0
  def used(%User{id: id}), do: used(id)

  def used(user_id) when is_integer(user_id) do
    Repo.aggregate(
      from(c in Card,
        join: b in Board,
        on: b.id == c.board_id,
        join: root in Board,
        on: root.id == coalesce(b.root_id, b.id),
        where: root.owner_id == ^user_id and is_nil(c.archived_at)
      ),
      :count
    )
  end

  @doc """
  This person's limit, or nil for no limit: their own override if an admin set
  one, else the instance's `free_card_limit`. Admins are never capped —
  somebody has to be able to fix a server that has filled up.
  """
  @spec limit(User.t() | nil) :: pos_integer() | nil
  def limit(nil), do: nil
  def limit(%User{admin: true}), do: nil
  def limit(%User{card_limit_override: n}) when is_integer(n), do: n
  def limit(%User{}), do: Settings.free_card_limit()

  @doc "Whether this person may make another card."
  @spec allows?(User.t() | nil) :: boolean()
  def allows?(user), do: check(user) == :ok

  @doc """
  `:ok`, or `{:error, :card_limit_reached}` with no further explanation — the
  caller phrases it, because the board, the CLI, the API and an automation rule
  each need to say it differently.
  """
  @spec check(User.t() | nil) :: :ok | {:error, :card_limit_reached}
  def check(user) do
    case limit(user) do
      nil -> :ok
      limit -> if used(user) < limit, do: :ok, else: {:error, :card_limit_reached}
    end
  end

  @doc """
  The same question for a board rather than a person: whoever owns the root of
  this tree is the one being counted. This is the form the card-creation path
  wants, since a card knows its column and its column knows its board.
  """
  @spec check_board(Board.t() | Column.t() | integer() | nil) ::
          :ok | {:error, :card_limit_reached}
  def check_board(nil), do: :ok
  def check_board(%Column{board_id: board_id}), do: check_board(board_id)
  def check_board(%Board{} = board), do: check_board(Board.root_id(board))

  def check_board(board_id) when is_integer(board_id) do
    # Nothing to count against on an unowned board — those predate accounts and
    # belong to whoever claims them.
    case owner_of(board_id) do
      nil -> :ok
      owner -> check(owner)
    end
  end

  @doc "Where somebody stands: used, their limit, and what is left."
  @spec status(User.t() | nil) :: %{
          used: non_neg_integer(),
          limit: pos_integer() | nil,
          remaining: non_neg_integer() | nil,
          limited?: boolean()
        }
  def status(user) do
    used = used(user)

    case limit(user) do
      nil -> %{used: used, limit: nil, remaining: nil, limited?: false}
      limit -> %{used: used, limit: limit, remaining: max(limit - used, 0), limited?: true}
    end
  end

  @doc """
  Whether somebody is close enough to the limit to be warned. Being told at the
  wall is being told too late.
  """
  @spec warning?(User.t() | nil) :: boolean()
  def warning?(user) do
    case status(user) do
      %{limited?: false} -> false
      %{limit: limit, remaining: remaining} -> remaining <= max(div(limit, 5), 1)
    end
  end

  @doc "A sentence for somebody who has hit the wall."
  def message(user) do
    case status(user) do
      %{limited?: false} ->
        nil

      %{limit: limit} ->
        "You have used all #{limit} cards on the boards you own. Archive something " <>
          "you have finished with, or subscribe for more."
    end
  end

  @doc """
  Adds the limit to a card changeset, so every creation path refuses the same
  way whatever it is.

  The error is a **changeset** rather than a bare `{:error, :card_limit}`
  because a dozen callers already handle `{:error, %Ecto.Changeset{}}` and
  would have treated an atom as one. It is still machine-readable:
  `limit_reached?/1` matches on the validation key rather than on the wording,
  so the API, the CLI and the UI can each say it their own way.
  """
  @spec enforce(Ecto.Changeset.t(), Column.t() | Board.t() | integer() | nil) ::
          Ecto.Changeset.t()
  def enforce(changeset, scope) do
    case check_board(scope) do
      :ok ->
        changeset

      {:error, :card_limit_reached} ->
        Ecto.Changeset.add_error(
          changeset,
          :base,
          limit_message(scope),
          validation: :card_limit
        )
    end
  end

  @doc "Whether this changeset failed because of the card limit, rather than wording."
  @spec limit_reached?(Ecto.Changeset.t() | term()) :: boolean()
  def limit_reached?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn
      {_field, {_message, opts}} -> opts[:validation] == :card_limit
      _ -> false
    end)
  end

  def limit_reached?(_), do: false

  defp limit_message(scope) do
    owner = owner_for(scope)

    case limit(owner) do
      nil ->
        "This board has reached its card limit."

      limit ->
        "This board's owner has used all #{limit} of their cards. They can archive " <>
          "something finished with, or subscribe for more."
    end
  end

  defp owner_for(%Column{board_id: board_id}), do: owner_of(board_id)
  defp owner_for(%Board{} = board), do: owner_of(Board.root_id(board))
  defp owner_for(board_id) when is_integer(board_id), do: owner_of(board_id)
  defp owner_for(_), do: nil

  defp owner_of(board_id) do
    Repo.one(
      from(b in Board,
        join: root in Board,
        on: root.id == coalesce(b.root_id, b.id),
        join: u in User,
        on: u.id == root.owner_id,
        where: b.id == ^board_id,
        select: u
      )
    )
  end
end
