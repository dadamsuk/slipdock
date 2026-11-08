defmodule Slipdock.Overseer.Checks.Looping do
  @moduledoc """
  Work going round (#2068): a card rejected a second time and still not
  accepted (the same test as `Slipdock.Verified.Circling.circling?/1`, so
  a rule id failed twice is one of these too, #2047), or a card on its
  third runner pass and still open. Clears when the card is accepted or
  done, or a person takes its `review` flag off.
  """
  @behaviour Slipdock.Overseer.Check

  import Ecto.Query

  alias Slipdock.Overseer.Check
  alias Slipdock.Repo
  alias Slipdock.Runners.Job
  alias Slipdock.Verified.Circling

  @passes 3

  @doc "The runner passes on one card that make it looping."
  def passes, do: @passes

  @impl true
  def key, do: "looping"

  @impl true
  def label, do: "Going round"

  @impl true
  def find(ctx), do: circling(ctx) ++ passes(ctx)

  defp circling(ctx) do
    ctx
    |> Check.live_cards()
    |> where([c], c.verify_rejections >= ^Circling.threshold())
    |> where([c], c.verify_state in ["rejected", "pending"])
    |> where([c], fragment("? = ANY(?)", "review", c.flags))
    |> select([c], %{id: c.id, title: c.title, rejections: c.verify_rejections})
    |> Repo.all()
    |> Enum.map(fn c ->
      %{
        subject: "card:#{c.id}:rejections",
        card_id: c.id,
        title: "##{c.id} is going round in circles: rejected #{c.rejections} times",
        why: "#{Check.ref(c)} has been rejected #{c.rejections} times and is still not accepted.",
        todo:
          "Read the rejections before another round of fixes: the card may need a " <>
            "different approach or a reworded bar. Taking its review flag off says you have seen it."
      }
    end)
  end

  defp passes(ctx) do
    kinds = Slipdock.Verified.finishing_kinds() ++ [Slipdock.Overseer.kind()]

    ctx
    |> Check.live_cards()
    |> join(:inner, [c], j in Job, on: j.card_id == c.id)
    |> where([_c, j], j.kind not in ^kinds and j.status != "cancelled")
    |> group_by([c], [c.id, c.title])
    |> having([_c, j], count(j.id) >= @passes)
    |> select([c, j], %{id: c.id, title: c.title, jobs: count(j.id)})
    |> Repo.all()
    |> Enum.map(fn c ->
      %{
        subject: "card:#{c.id}:passes",
        card_id: c.id,
        title: "##{c.id} is on its #{ordinal(c.jobs)} runner pass",
        why: "#{c.jobs} runner jobs have worked #{Check.ref(c)} and it is still open.",
        todo:
          "Read why each pass stopped (its handoffs and job steps) before it goes again; " <>
            "split it or reword its bar if it is more than one pass can do."
      }
    end)
  end

  defp ordinal(n) when rem(div(n, 10), 10) == 1, do: "#{n}th"
  defp ordinal(n) when rem(n, 10) == 1, do: "#{n}st"
  defp ordinal(n) when rem(n, 10) == 2, do: "#{n}nd"
  defp ordinal(n) when rem(n, 10) == 3, do: "#{n}rd"
  defp ordinal(n), do: "#{n}th"
end
