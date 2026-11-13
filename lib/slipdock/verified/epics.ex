defmodule Slipdock.Verified.Epics do
  @moduledoc """
  A card's sub-board, as the checks of `Slipdock.Verified` read it: the
  subcards still open, whether the card is an epic, and whether accepting
  it has nothing to merge.
  """

  import Ecto.Query, only: [from: 2]

  alias Slipdock.Boards.{Board, Card}
  alias Slipdock.Repo
  alias Slipdock.Verified.{Evidence, Util}

  ## Open subcards (#1758) ----------------------------------------------------

  # How many open subcards a refusal names before it says how many more.
  @named_subcards 10

  @doc """
  The cards still open on `card`'s sub-board, as `{id, title}` in id order:
  not completed, not archived and not submitted for verification (pending,
  or accepted and merging or held for a person, #1952, which is the
  verifier's or the person's to finish). A subcard
  that is complete counts as done whatever its own sub-board holds. An
  archived sub-board, or none, has none.
  """
  def open_subcards(%Card{id: id}) do
    from(c in Card,
      join: b in Board,
      on: b.id == c.board_id,
      where:
        b.parent_card_id == ^id and is_nil(b.archived_at) and c.completed == false and
          is_nil(c.archived_at) and
          coalesce(c.verify_state, "") not in ["pending", "merging", "held"],
      order_by: c.id,
      select: {c.id, c.title}
    )
    |> Repo.all()
  end

  # Why `card` can't be completed by an agent yet, or nil when it can.
  @doc false
  def subcards_message(%Card{} = card) do
    case open_subcards(card) do
      [] ->
        nil

      open ->
        {named, rest} = Enum.split(open, @named_subcards)
        names = Enum.map_join(named, ", ", fn {id, title} -> "##{id} #{title}" end)
        more = if rest == [], do: "", else: " and #{length(rest)} more"
        verb = if length(open) == 1, do: "is", else: "are"

        "card ##{card.id} has open subcards: #{names}#{more} #{verb} still open. " <>
          "Finish or archive them first, then complete it"
    end
  end

  @doc """
  Whether `card` is an epic (#1917): its sub-board, not archived, holds a
  card that isn't archived. On a board that ships by pull request each
  subcard ships its own pull request, so an epic needs none of its own.
  """
  def epic?(%Card{id: id}) do
    from(c in Card,
      join: b in Board,
      on: b.id == c.board_id,
      where: b.parent_card_id == ^id and is_nil(b.archived_at) and is_nil(c.archived_at)
    )
    |> Repo.exists?()
  end

  @doc """
  Whether accepting `card` on a board that ships by pull request has
  nothing to merge (#1917): it is an epic, and it names no pull request, or
  one a subcard of it already merged (an accepted, completed subcard with
  the same `evidence_pr`). Such an epic completes on acceptance, as on a
  push board; an epic naming a pull request of its own still merges it.
  """
  def nothing_to_merge?(%Card{} = card) do
    Evidence.no_code?(card) or
      (epic?(card) and (Util.blank?(card.evidence_pr) or subcard_merged?(card, card.evidence_pr)))
  end

  @doc false
  def subcard_merged?(%Card{id: id}, pr) do
    pr = pr_key(pr)

    from(c in Card,
      join: b in Board,
      on: b.id == c.board_id,
      where:
        b.parent_card_id == ^id and is_nil(c.archived_at) and c.completed == true and
          c.verify_state == "accepted" and not is_nil(c.evidence_pr),
      select: c.evidence_pr
    )
    |> Repo.all()
    |> Enum.any?(&(pr_key(&1) == pr))
  end

  # The same pull request whatever its trailing slash, case or fragment.
  defp pr_key(url),
    do:
      url
      |> Util.trim()
      |> String.split(["#", "?"])
      |> hd()
      |> String.trim_trailing("/")
      |> String.downcase()
end
