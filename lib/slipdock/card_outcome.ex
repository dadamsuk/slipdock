defmodule Slipdock.CardOutcome do
  @moduledoc """
  How a finished card ended (#2022), from its own facts: done when, how it
  was accepted (by whom), what merged (its pull request and the merge
  commit) or which commit it was, and where it has shipped
  (`Slipdock.Deployments.shipped/1`, kept apart as its own lines).

  A finished card shows this in place of a next step: the handoff written
  before it finished (a builder's "accepting will merge it", a verifier's
  job summary) is history by then, so it is told apart from one a person
  left afterwards for what is still to do (`before_finish?/2`). Nothing is
  rewritten: the handoffs stay as they were.
  """

  alias Slipdock.Boards.Card

  @doc """
  The outcome of `card`, or nil while it is open: `done_at`, `accepted_by`
  (who accepted it, when a verifier or a person did), `pr` and `pr_number`,
  `merge_sha` and `commit`.
  """
  def of(%Card{completed: true} = card) do
    merged = if card.verify_state == "accepted", do: card.merge_sha

    %{
      done_at: card.completed_at,
      accepted_by: accepted_by(card),
      pr: if(merged, do: card.evidence_pr),
      pr_number: if(merged, do: pr_number(card.evidence_pr)),
      merge_sha: merged,
      commit: if(is_nil(card.merge_sha), do: card.verify_commit || card.evidence_commit)
    }
  end

  def of(_card), do: nil

  @doc """
  The outcome as one line: `Done 7 Nov 14:32 · accepted by runner verifier
  · merged PR #215 (def5678)`, its time in `zone`.
  """
  def text(nil, _zone), do: nil

  def text(%{} = o, zone) do
    [
      "Done" <>
        if(o.done_at, do: " " <> Slipdock.Deployments.time_text(o.done_at, zone), else: ""),
      o.accepted_by && "accepted by #{o.accepted_by}",
      merged_text(o),
      is_nil(o.merge_sha) && o.commit && "commit #{short(o.commit)}"
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.join(" · ")
  end

  defp merged_text(%{merge_sha: sha} = o) when is_binary(sha) do
    what =
      cond do
        o.pr_number -> "merged PR ##{o.pr_number}"
        o.pr -> "merged its pull request"
        true -> "merged"
      end

    "#{what} (#{short(sha)})"
  end

  defp merged_text(_o), do: nil

  @doc """
  Whether `handoff` was written before `card` finished: a finished card
  folds that one away as the last note before it finished. One left after
  (what is still to do for a person) is current; an open card's is too.
  """
  def before_finish?(%Card{completed: true, completed_at: %DateTime{} = done}, %{
        inserted_at: %DateTime{} = at
      }),
      do: DateTime.compare(at, done) != :gt

  def before_finish?(_card, _handoff), do: false

  defp accepted_by(%Card{verify_state: "accepted", verify_by: by}) when is_map(by),
    do: Slipdock.Verified.who(by)

  defp accepted_by(_card), do: nil

  defp pr_number(url) when is_binary(url) do
    case Regex.run(~r{/pull/(\d+)}, url) do
      [_, n] -> n
      _ -> nil
    end
  end

  defp pr_number(_), do: nil

  defp short(sha), do: String.slice(sha, 0, 7)
end
