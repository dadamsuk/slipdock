defmodule Slipdock.Gardener.Checks.Cards do
  @moduledoc """
  What the card checks share (W-1807): the open cards of a run's tree, when
  each last saw any activity, and how to say a date.
  """

  import Ecto.Query

  alias Slipdock.Boards.{Activity, Card, Comment}
  alias Slipdock.Gardener.Context
  alias Slipdock.Repo
  alias Slipdock.Rollup

  @doc """
  Every card on the run's boards that a check may look at: not archived, not
  a stand-in (the rollup leaves both out) and not snoozed — a snoozed card is
  somebody having already decided when to look again.
  """
  def cards(%Context{} = ctx) do
    cards = Enum.flat_map(ctx.board_ids, &Rollup.board_cards(ctx.rollup, &1))
    snoozed = snoozed_ids(Enum.map(cards, & &1.id), ctx.now)
    Enum.reject(cards, &MapSet.member?(snoozed, &1.id))
  end

  defp snoozed_ids([], _now), do: MapSet.new()

  defp snoozed_ids(ids, now) do
    from(c in Card,
      where: c.id in ^ids and not is_nil(c.snoozed_until) and c.snoozed_until > ^now,
      select: c.id
    )
    |> Repo.all()
    |> MapSet.new()
  end

  @doc "The card's subcard board in the tree, or nil."
  def sub_board(%Context{rollup: rollup}, card), do: Map.get(rollup.sub_board, card.id)

  @doc """
  When each card last saw activity — its own `updated_at`, a line in the
  activity log, or a comment, whichever is latest — and the last comment's
  author: `%{id => {datetime, author name or nil}}`.
  """
  def last_activity([]), do: %{}

  def last_activity(cards) do
    ids = Enum.map(cards, & &1.id)

    logged =
      from(a in Activity,
        where: a.card_id in ^ids,
        group_by: a.card_id,
        select: {a.card_id, max(a.inserted_at)}
      )
      |> Repo.all()
      |> Map.new()

    comments =
      from(c in Comment,
        where: c.card_id in ^ids,
        distinct: c.card_id,
        order_by: [asc: c.card_id, desc: c.inserted_at, desc: c.id],
        preload: [:user]
      )
      |> Repo.all()
      |> Map.new(&{&1.card_id, &1})

    Map.new(cards, fn card ->
      comment = comments[card.id]

      times =
        Enum.reject([card.updated_at, logged[card.id], comment && comment.inserted_at], &is_nil/1)

      latest = Enum.max(times, DateTime)
      {card.id, {latest, comment && author(comment.user)}}
    end)
  end

  defp author(nil), do: nil
  defp author(user), do: Slipdock.Accounts.User.display_name(user)

  @doc "Whole days from `dt` to `now`."
  def days_since(%DateTime{} = dt, %DateTime{} = now), do: div(DateTime.diff(now, dt), 86_400)

  @doc "A date the way a person writes it: `2 Aug 2026`."
  def day(%DateTime{} = dt), do: dt |> DateTime.to_date() |> day()
  def day(%Date{} = d), do: Calendar.strftime(d, "%-d %b %Y")

  @doc "A list's name in quotes, for an explanation."
  def list_name(%Context{columns: columns}, %{column_id: id}) do
    case Map.get(columns, id) do
      nil -> "its list"
      col -> "“#{col.name}”"
    end
  end
end
