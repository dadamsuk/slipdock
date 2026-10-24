defmodule Slipdock.Gardener.Checks.HandbookGap do
  @moduledoc """
  Cards that skipped the handbook's docs gate (#1267, W-1934 §Drift): on a
  board whose tree keeps a handbook (`Slipdock.Handbook`), a card completed
  since the handbook was installed with no `Handbook:` line in any comment
  (`Slipdock.Handbook.gate_line/1`). `Handbook: no change (…)` counts: the
  gate was run and nothing needed writing.

  Off by itself on a board without a handbook; cards done before it was
  installed are never asked about. The fix asks on the card for the line;
  reopening it is the other choice. Adding the line clears the suggestion
  at the next run.

  The other half of the spec's drift check — pages whose `covers:` paths
  changed since they were edited — needs commits' file paths, which the
  deployment ledger doesn't keep yet (#1278).
  """
  @behaviour Slipdock.Gardener.Check

  import Ecto.Query

  alias Slipdock.Boards.{Card, Comment}
  alias Slipdock.Handbook
  alias Slipdock.Repo

  @impl true
  def key, do: "handbook_gap"
  @impl true
  def label, do: "Closed without a Handbook line"
  @impl true
  def defaults, do: %{"enabled" => true}

  @nudge """
  **Handbook gate skipped.** This card closed on a handbook board without a `Handbook:` line.

  - Run the docs gate against its diff (the table in the agent guide's `handbook` section).
  - Then comment one line: `Handbook: updated W-… §…`, or `Handbook: no change (why)`.
  """

  @impl true
  def find(ctx, _settings) do
    case Handbook.find(ctx.board) do
      nil -> []
      handbook -> skipped(ctx, handbook)
    end
  end

  defp skipped(ctx, handbook) do
    cards =
      from(c in Card,
        where: c.board_id in ^ctx.board_ids and c.completed and is_nil(c.archived_at),
        where: is_nil(c.stand_in_for_id) and c.completed_at >= ^handbook.installed_at,
        select: struct(c, [:id, :title, :completed_at])
      )
      |> Repo.all()

    gated = gated(Enum.map(cards, & &1.id))

    for card <- cards, not MapSet.member?(gated, card.id) do
      %{
        subject: %{"cards" => [card.id]},
        state: card.completed_at,
        proposal: [%{"op" => "comment", "card" => card.id, "body" => String.trim(@nudge)}],
        alternatives: %{"reopen" => [%{"op" => "reopen", "card" => card.id}]},
        explanation: "##{card.id} closed without a Handbook line"
      }
    end
  end

  # The cards with a `Handbook:` line in any comment.
  defp gated([]), do: MapSet.new()

  defp gated(ids) do
    from(c in Comment,
      where: c.card_id in ^ids and ilike(c.body, "%handbook:%"),
      select: {c.card_id, c.body}
    )
    |> Repo.all()
    |> Enum.filter(fn {_id, body} -> Handbook.gate_line(body) end)
    |> MapSet.new(&elem(&1, 0))
  end
end
