defmodule Slipdock.Visualise do
  @moduledoc """
  The numbers behind a board's Visualise page (`SlipdockWeb.BoardLive.Visualise`)
  that come straight from the database: how many cards each list holds, what
  was archived from them, the cards in the done lists and the doing and ready
  lists, and how long the last answered wait took (#2791 moved them out of
  the LiveView).
  """
  import Ecto.Query

  alias Slipdock.Boards.{Board, Card, CardMove, Wait}
  alias Slipdock.Repo

  @doc "How many cards each of `board`'s lists holds: not archived, never a stand-in."
  def card_counts(%Board{id: board_id}) do
    from(c in Card,
      where: c.board_id == ^board_id and is_nil(c.archived_at) and is_nil(c.stand_in_for_id),
      group_by: c.column_id,
      select: {c.column_id, count(c.id)}
    )
    |> Repo.all()
    |> Map.new()
  end

  @doc "How many cards were archived from each of `board`'s lists since `since`."
  def archived_counts(%Board{id: board_id}, %DateTime{} = since) do
    from(m in CardMove,
      where: m.board_id == ^board_id and m.kind == "archived" and m.inserted_at >= ^since,
      group_by: m.from_column_id,
      select: {m.from_column_id, count(m.id)}
    )
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  The cards in the lists `column_ids` (a board's done lists), with their
  tags: those still there, and those archived from them that were
  completed since `since`. Never a stand-in.
  """
  def done_cards(column_ids, %DateTime{} = since) do
    from(c in Card,
      where:
        c.column_id in ^column_ids and is_nil(c.stand_in_for_id) and
          (is_nil(c.archived_at) or c.completed_at >= ^since),
      preload: :tags
    )
    |> Repo.all()
  end

  @doc """
  The open cards in the lists `column_ids`, not archived and never a
  stand-in, with their tags and their open wait.
  """
  def open_cards(column_ids) do
    from(c in Card,
      where:
        c.column_id in ^column_ids and is_nil(c.archived_at) and is_nil(c.stand_in_for_id) and
          not c.completed,
      preload: [:tags, wait: ^from(w in Wait, where: is_nil(w.closed_at))]
    )
    |> Repo.all()
  end

  @doc """
  When `board`'s most recently answered wait was opened and answered, as
  `{inserted_at, closed_at}`, or nil when none has been.
  """
  def last_answered_wait(%Board{id: board_id}) do
    from(w in Wait,
      join: c in Card,
      on: c.id == w.card_id,
      where: c.board_id == ^board_id and w.close_reason == "answered",
      order_by: [desc: w.closed_at, desc: w.id],
      limit: 1,
      select: {w.inserted_at, w.closed_at}
    )
    |> Repo.one()
  end
end
