defmodule Slipdock.Boards.Milestones do
  @moduledoc """
  Milestones on a board.
  """

  import Ecto.Query, warn: false

  alias Slipdock.Boards
  alias Slipdock.Boards.Board
  alias Slipdock.Boards.Milestone
  alias Slipdock.Repo

  ## Milestones

  @doc "The milestones of the tree rooted at `root_id`, by date."
  def list_milestones(root_id) do
    Repo.all(
      from(m in Milestone, where: m.board_id == ^root_id, order_by: [asc: m.date, asc: m.id])
    )
  end

  def get_milestone!(id), do: Repo.get!(Milestone, id)

  @doc """
  The milestone `id` if it is on the tree rooted at `root_id`, or nil: for ids
  a client sent.
  """
  def get_board_milestone(root_id, id) do
    case Boards.Shared.to_id(id) do
      nil -> nil
      id -> Repo.one(from(m in Milestone, where: m.id == ^id and m.board_id == ^root_id))
    end
  end

  @doc "Adds a milestone to the tree `board` belongs to."
  def create_milestone(%Board{} = board, attrs) do
    root_id = Board.root_id(board)

    %Milestone{board_id: root_id}
    |> Milestone.changeset(attrs)
    |> Repo.insert()
    |> Boards.Shared.tap_ok(fn m ->
      Boards.ActivityLog.log(
        Repo,
        root_id,
        m.card_id,
        "milestone",
        "added milestone “#{m.name}” on #{m.date}"
      )

      Boards.PubSub.broadcast_tree(root_id)
    end)
  end

  def update_milestone(%Milestone{} = milestone, attrs) do
    milestone
    |> Milestone.changeset(attrs)
    |> Repo.update()
    |> Boards.Shared.tap_ok(fn m ->
      Boards.ActivityLog.log(
        Repo,
        m.board_id,
        m.card_id,
        "milestone",
        "updated milestone “#{m.name}” (#{m.date})"
      )

      Boards.PubSub.broadcast_tree(m.board_id)
    end)
  end

  def delete_milestone(%Milestone{} = milestone) do
    Repo.delete(milestone)
    |> Boards.Shared.tap_ok(fn m ->
      Boards.ActivityLog.log(Repo, m.board_id, nil, "milestone", "removed milestone “#{m.name}”")
      Boards.PubSub.broadcast_tree(m.board_id)
    end)
  end

  def change_milestone(%Milestone{} = m, attrs \\ %{}), do: Milestone.changeset(m, attrs)
end
