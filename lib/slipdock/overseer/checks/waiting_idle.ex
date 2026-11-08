defmodule Slipdock.Overseer.Checks.WaitingIdle do
  @moduledoc """
  Waiting while idle (#2068): something on the tree is waiting on a person
  (an open wait, a card flagged `review`, a card awaiting verification)
  and no runner job is open anywhere on it, so the person is the only
  thing holding the board up. One condition for the tree; it clears when
  a job is open again or nothing is waiting.
  """
  @behaviour Slipdock.Overseer.Check

  import Ecto.Query

  alias Slipdock.Boards.Wait
  alias Slipdock.Overseer.Check
  alias Slipdock.Repo
  alias Slipdock.Runners.Job

  @impl true
  def key, do: "waiting_idle"

  @impl true
  def label, do: "Waiting while idle"

  @impl true
  def find(ctx) do
    if jobs_open?(ctx), do: [], else: waiting(ctx)
  end

  defp jobs_open?(%{root: root}) do
    Repo.exists?(
      from(j in Job,
        where: j.root_board_id == ^root.id and j.status in ^Job.open_statuses(),
        where: j.kind != ^Slipdock.Overseer.kind()
      )
    )
  end

  defp waiting(ctx) do
    waits =
      ctx
      |> Check.live_cards()
      |> join(:inner, [c], w in Wait, on: w.card_id == c.id and is_nil(w.closed_at))
      |> select([c, w], %{id: c.id, title: c.title, since: w.inserted_at, what: "a wait"})
      |> Repo.all()

    flagged =
      ctx
      |> Check.live_cards()
      |> where([c], fragment("? = ANY(?)", "review", c.flags) or c.verify_state == "pending")
      |> select([c], %{
        id: c.id,
        title: c.title,
        since: coalesce(c.verify_at, c.updated_at),
        what: "review"
      })
      |> Repo.all()

    case (waits ++ flagged)
         |> Enum.sort_by(&DateTime.to_unix(&1.since))
         |> Enum.uniq_by(& &1.id) do
      [] ->
        []

      [oldest | _] = cards ->
        [
          %{
            subject: "tree",
            card_id: oldest.id,
            title:
              String.slice(
                "Only you can move #{ctx.root.name} on: #{length(cards)} waiting, nothing running",
                0,
                200
              ),
            why:
              "No runner job is open on the board, and these wait on a person: " <>
                Check.refs(cards) <>
                ". The oldest has waited #{Check.duration(DateTime.diff(ctx.now, oldest.since))}.",
            todo:
              "Answer the waits and decide the cards flagged review or awaiting " <>
                "verification: until then nothing on this board moves."
          }
        ]
    end
  end
end
