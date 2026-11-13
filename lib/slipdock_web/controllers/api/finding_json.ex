defmodule SlipdockWeb.API.FindingJSON do
  @moduledoc "How a finding reads over HTTP (see `Slipdock.Findings.Finding`)."

  alias Slipdock.Findings.Finding

  def finding(%Finding{} = f) do
    %{
      id: f.id,
      board_id: f.board_id,
      card: card(f.card),
      comment_id: f.comment_id,
      job_id: f.job_id,
      kind: f.kind,
      source: f.source,
      status: f.status,
      text: f.text,
      cause: f.cause,
      count: f.count,
      by: f.by,
      note: f.note,
      merged_into_id: f.merged_into_id,
      scope: f.scope,
      # The garden proposal drafted for it (#1942) and the rule it proposes.
      proposal_id: f.proposal_id,
      proposed_rule: f.proposed_rule,
      # Open, but named by an open proposal (its id): it waits on the person
      # deciding that, not on triage (#2767). Nil otherwise.
      waiting: f.waiting,
      runner: runner(f.runner),
      cards: Enum.map(f.cards || [], &card/1),
      created_at: f.inserted_at,
      updated_at: f.updated_at
    }
  end

  defp card(%Slipdock.Boards.Card{} = c), do: %{id: c.id, title: c.title, board_id: c.board_id}
  defp card(_), do: nil

  defp runner(%Slipdock.Runners.Runner{} = r), do: %{id: r.id, name: r.name}
  defp runner(_), do: nil
end
