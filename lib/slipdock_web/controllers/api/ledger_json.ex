defmodule SlipdockWeb.API.LedgerJSON do
  @moduledoc """
  How the ledger reads over HTTP and MCP (see `Slipdock.Ledger`): the window,
  then the days, newest first, each with its lines.
  """

  alias Slipdock.Boards.Board

  def ledger(%Board{} = board, ledger) do
    %{
      board: %{id: board.id, code: board.code, name: board.name},
      since: ledger.since,
      until: ledger.until,
      timezone: ledger.timezone,
      count: ledger.count,
      days: Enum.map(ledger.days, &day(board, &1))
    }
  end

  defp day(board, %{date: date, items: items}),
    do: %{date: Date.to_iso8601(date), items: Enum.map(items, &item(board, &1))}

  defp item(board, i) do
    i
    |> Map.take(~w(at events accepted_by audit evidence evidence_commit should_broken pr merge_sha
                   deploys subcards waiting_for not_verified)a)
    |> Map.merge(%{
      card: Map.put(i.card, :url, card_url(i.card)),
      lead_time: %{
        seconds: i.lead_time.seconds,
        ends: i.lead_time.ends,
        phases: i.lead_time.phases,
        cost: Slipdock.Runners.JobCost.json(i.lead_time[:cost])
      },
      on_board: i.card.board_id == board.id
    })
  end

  @doc "Where a line's \"Look closer\" goes: the card's panel, at its chat."
  def card_url(%{id: id, board_id: board_id}),
    do: "/boards/#{board_id}/cards/#{id}#card-ai-#{id}"
end
