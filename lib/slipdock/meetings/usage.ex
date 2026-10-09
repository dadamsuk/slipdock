defmodule Slipdock.Meetings.Usage do
  @moduledoc """
  Meeting capture's usage ledger: every transcription, model call and stored
  recording, written as it happens against the person who sent the meeting,
  the capture and the month (see `Slipdock.Meetings.UsageEntry`).
  """
  import Ecto.Query, warn: false

  alias Slipdock.Meetings.{Capture, UsageEntry}
  alias Slipdock.Repo

  @doc """
  Writes one line. `attrs`: `:kind` (`transcription`, `reading`, `relisten`,
  `context`, `storage`), `:step`, `:seconds`, `:tokens_in`, `:tokens_out`,
  `:bytes`, `:cost`, `:model`, `:own_key`.
  """
  def record(%Capture{} = capture, attrs) do
    now = DateTime.utc_now()

    Repo.insert!(%UsageEntry{
      user_id: capture.owner_id,
      capture_id: capture.id,
      board_id: capture.board_id,
      kind: to_string(attrs[:kind]),
      step: attrs[:step] && to_string(attrs[:step]),
      seconds: attrs[:seconds] && attrs[:seconds] / 1,
      tokens_in: attrs[:tokens_in],
      tokens_out: attrs[:tokens_out],
      bytes: attrs[:bytes],
      cost: number(attrs[:cost]),
      model: attrs[:model],
      own_key: attrs[:own_key] == true,
      month: Date.beginning_of_month(DateTime.to_date(now)),
      inserted_at: now
    })
  end

  @doc """
  An `:on_usage` function for `Slipdock.AI.complete/2` that writes each model
  call to the ledger. A call on the person's own key or endpoint is marked
  `own_key`, which the server's limits leave out.
  """
  def recorder(%Capture{} = capture, kind, step, own_key?) do
    fn info ->
      record(capture, %{
        kind: kind,
        step: step,
        tokens_in: info.tokens_in,
        tokens_out: info.tokens_out,
        cost: info.cost,
        model: info.model,
        own_key: own_key? or info.custom?
      })
    end
  end

  @doc "A capture's ledger lines, oldest first."
  def for_capture(%Capture{id: id}) do
    Repo.all(from(u in UsageEntry, where: u.capture_id == ^id, order_by: [asc: u.id]))
  end

  defp number(nil), do: nil
  defp number(n) when is_number(n), do: n / 1

  defp number(s) when is_binary(s) do
    case Float.parse(s) do
      {n, _} -> n
      :error -> nil
    end
  end
end
