defmodule Slipdock.Verified.Rejections do
  @moduledoc """
  A card's rejections, read back: how many its tree allows, the reason and
  failing parts of each from its comments, the last one for whoever takes
  the card up again, and the verdict a resubmission follows.
  """

  import Ecto.Query, only: [from: 2]

  alias Slipdock.Boards.{Board, Card}
  alias Slipdock.Repo
  alias Slipdock.Verified.{Actors, Util}

  @doc """
  The verdict a pending card's submission follows (#1944): the last
  decision's parts and the commit they judged, `%{checks, sha, reason,
  rejections, accepted}`, when the card was decided before (a rejection, or
  an acceptance whose merge failed) and that verdict named its commit. nil
  for a first submission, or a verdict kept without its commit.
  """
  def previous_verdict(%Card{verify_checks: %{"judged_at" => sha} = checks} = card)
      when is_binary(sha) and sha != "" do
    accepted = checks["decision"] == "accept"

    %{
      checks: checks,
      sha: sha,
      accepted: accepted,
      reason: if(accepted, do: nil, else: card |> rejection_reasons() |> List.last()),
      rejections: card.verify_rejections || 0
    }
  end

  def previous_verdict(_card), do: nil

  @doc """
  How many rejections a card on `card`'s tree may have before the next goes
  to a person (#1779): its root board's `verify_rejection_limit`. 0 is no
  limit.
  """
  def rejection_limit(%Card{} = card) do
    board = Util.board(card)
    root = if board.root_id, do: Repo.get(Board, board.root_id) || board, else: board
    root.verify_rejection_limit || 0
  end

  # Each rejection's reason, oldest first, from the cards' own comments.
  defp rejection_reasons(card), do: card |> rejection_comments() |> Enum.map(&elem(&1, 0))

  # Each rejection, oldest first, as `{reason, failing parts}`: the parts
  # from its comment's `Checks:` block, else the ones its reason cites.
  @doc false
  def rejection_comments(%Card{id: id}) do
    from(c in Slipdock.Boards.Comment,
      where: c.card_id == ^id and like(c.body, "**Rejected** by%"),
      order_by: [asc: c.id],
      select: c.body
    )
    |> Repo.all()
    |> Enum.map(fn body ->
      [reason | checks] =
        body
        |> String.split("\n\n", parts: 2)
        |> Enum.at(1, "(no reason given)")
        |> String.split("\n\nChecks:", parts: 2)

      failed =
        case checks do
          [lines] ->
            failing_labels(lines)

          [] ->
            reason |> Slipdock.Verified.Checks.from_reason() |> Slipdock.Verified.Checks.failing()
        end

      {reason |> String.replace(~r/\s+/, " ") |> String.slice(0, 400), failed}
    end)
  end

  # The failing parts of a decision comment's `Checks:` lines
  # (`- bar 2: fail — why`), by label.
  defp failing_labels(lines) do
    for line <- String.split(lines, "\n"),
        [_, label, result] <- [Regex.run(~r/^\s*-\s+(.+?):\s+(.+?)(?:\s+—\s.*)?\s*$/u, line)],
        Slipdock.Verified.Checks.failing_result?(result),
        do: label |> String.replace(~r/ (must|should)$/, "")
  end

  @doc """
  The reason a rejected card was sent back with, and who rejected it, for
  the agent taking it up again (#1659): nil unless `card` is rejected.
  """
  def rejection(%Card{verify_state: "rejected", verify_note: note} = card)
      when is_binary(note) and note != "" do
    %{
      reason: note,
      by: Actors.who(card.verify_by),
      at: card.verify_at,
      rejections: card.verify_rejections || 0
    }
  end

  def rejection(_card), do: nil
end
