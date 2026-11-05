defmodule Slipdock.Health.Cards do
  @moduledoc """
  What the detectors about cards share: when a card last saw any activity,
  and which cards an agent is driving.
  """

  import Ecto.Query

  alias Slipdock.Boards.{Card, CardMove, Comment}
  alias Slipdock.Repo

  @doc """
  `card_id => DateTime` for each card: the latest of its own update, a
  comment on it and a move of it.
  """
  def last_activity([]), do: %{}

  def last_activity(card_ids) do
    updated =
      Repo.all(from(c in Card, where: c.id in ^card_ids, select: {c.id, c.updated_at}))

    comments =
      Repo.all(
        from(c in Comment,
          where: c.card_id in ^card_ids,
          group_by: c.card_id,
          select: {c.card_id, max(c.inserted_at)}
        )
      )

    moves =
      Repo.all(
        from(m in CardMove,
          where: m.card_id in ^card_ids,
          group_by: m.card_id,
          select: {m.card_id, max(m.inserted_at)}
        )
      )

    (updated ++ comments ++ moves)
    |> Enum.reject(fn {_, at} -> is_nil(at) end)
    |> Enum.group_by(&elem(&1, 0), &utc(elem(&1, 1)))
    |> Map.new(fn {id, ats} -> {id, Enum.max(ats, DateTime)} end)
  end

  @doc """
  The cards among `card_ids` an agent is driving: the last time each was put
  into a list, an agent did it. The health monitor watches these
  (`orphan_in_progress`); the gardener's `stale_in_progress` leaves them to it.
  """
  def agent_driven([]), do: MapSet.new()

  def agent_driven(card_ids) do
    from(m in CardMove,
      where: m.card_id in ^card_ids and m.kind in ^CardMove.entry_kinds(),
      distinct: m.card_id,
      order_by: [asc: m.card_id, desc: m.inserted_at, desc: m.id],
      select: {m.card_id, m.actor_kind}
    )
    |> Repo.all()
    |> Enum.filter(fn {_, kind} -> kind == "agent" end)
    |> MapSet.new(&elem(&1, 0))
  end

  defp utc(%DateTime{} = at), do: DateTime.truncate(at, :second)
  defp utc(%NaiveDateTime{} = at), do: at |> DateTime.from_naive!("Etc/UTC") |> utc()
end
