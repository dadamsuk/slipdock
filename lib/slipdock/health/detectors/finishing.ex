defmodule Slipdock.Health.Detectors.Finishing do
  @moduledoc false
  # What the verification and merge detectors share: the finishing jobs of
  # a set of cards, and when a card last saw one end.

  import Ecto.Query

  alias Slipdock.Boards.Card
  alias Slipdock.Repo
  alias Slipdock.Runners.Job

  @doc "Open cards on `board_ids` in `state` (`pending`, `merging`)."
  def cards(board_ids, state) do
    from(c in Card,
      where:
        c.board_id in ^board_ids and c.verify_state == ^state and c.completed == false and
          is_nil(c.archived_at),
      order_by: c.id,
      preload: [:board]
    )
    |> Repo.all()
  end

  @doc "Every `kind` job on `card_ids`, newest first, grouped by card."
  def jobs(card_ids, kind) do
    from(j in Job, where: j.card_id in ^card_ids and j.kind == ^kind, order_by: [desc: j.id])
    |> Repo.all()
    |> Enum.group_by(& &1.card_id)
  end

  @doc "When the card was last handed on (`verify_at`) or one of `jobs` last ended."
  def quiet_since(%Card{verify_at: at}, jobs) do
    [at | Enum.map(jobs, &(&1.finished_at || &1.updated_at))]
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&utc/1)
    |> Enum.max(DateTime, fn -> nil end)
  end

  defp utc(%DateTime{} = at), do: at
  defp utc(%NaiveDateTime{} = at), do: DateTime.from_naive!(at, "Etc/UTC")

  @doc "How `job` ended, in words."
  def ended(%Job{status: status, error: error}) when is_binary(error) and error != "",
    do: "#{status}: #{error}"

  def ended(%Job{status: status}), do: status
end
