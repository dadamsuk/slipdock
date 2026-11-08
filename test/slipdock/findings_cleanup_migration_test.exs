defmodule Slipdock.FindingsCleanupMigrationTest do
  @moduledoc """
  The one-off clean-up of rule proposals drafted from findings (#2129):
  each open one whose finding triage decided, whose finding is an event,
  or that duplicates its finding's own open proposal is closed with a note
  naming why; a live one, one filed by hand and any other suggestion stay
  as they are.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.Findings
  alias Slipdock.Findings.Finding
  alias Slipdock.Gardener.Suggestion
  alias Slipdock.Repo

  [{migration, _}] =
    Code.require_file("priv/repo/migrations/20261108201207_close_stale_finding_proposals.exs")

  @migration migration

  # The test database is migrated already: its backfill again, on rows put
  # back as they stood before, inside the test's transaction.
  defp backfill, do: Enum.each(@migration.backfill(), &Repo.query!/1)

  setup do
    owner = user_fixture()
    board = board_fixture(%{"name" => "Cleaning"}, owner: owner)
    card = card_fixture(hd(board.columns), %{"title" => "A card"})
    %{board: board, card: card}
  end

  defp finding(ctx, attrs) do
    %Finding{
      board_id: ctx.board.id,
      card_id: ctx.card.id,
      kind: "gotcha",
      source: "agent",
      text: "a lesson",
      lesson: "a lesson",
      count: 3
    }
    |> struct(attrs)
    |> Repo.insert!()
  end

  defp drafted(ctx, %Finding{id: id}, count, attrs \\ []) do
    %Suggestion{
      board_id: ctx.board.id,
      check: "proposal",
      state: "open",
      fingerprint: "fp-#{id}-#{count}-#{System.unique_integer([:positive])}",
      subject: %{"cards" => [ctx.card.id], "pages" => [], "findings" => [id]},
      explanation: "Finding ##{id} was seen #{count} times (cards ##{ctx.card.id}): a lesson."
    }
    |> struct(attrs)
    |> Repo.insert!()
  end

  defp own(%Finding{} = f, %Suggestion{id: id}),
    do: Repo.update!(Ecto.Changeset.change(f, proposal_id: id))

  defp after_backfill(%Suggestion{id: id}), do: Repo.get!(Suggestion, id)

  test "a decided finding's proposals close with its decision as the note", ctx do
    promoted = finding(ctx, status: "promoted", note: "handbook proposal #76 (W-1950)")
    dismissed = finding(ctx, status: "dismissed", note: nil)
    into = finding(ctx, text: "the lesson it went into")
    merged = finding(ctx, status: "merged", merged_into_id: into.id)

    p1 = drafted(ctx, promoted, 3)
    p2 = drafted(ctx, promoted, 4)
    own(promoted, p2)
    d = drafted(ctx, dismissed, 3)
    m = drafted(ctx, merged, 3)

    backfill()

    for p <- [p1, p2] do
      assert %{state: "dismissed", decided_by_id: nil, decided_at: %DateTime{}, note: note} =
               after_backfill(p)

      assert note == "finding ##{promoted.id} promoted: handbook proposal #76 (W-1950)"
    end

    assert after_backfill(d).note == "finding ##{dismissed.id} dismissed"
    assert after_backfill(m).note == "finding ##{merged.id} merged into ##{into.id}"

    # Reopening the finding reopens its own proposal, not the duplicate.
    {:ok, _} = Findings.triage(Repo.get!(Finding, promoted.id), "reopen")
    assert after_backfill(p2).state == "open"
    assert after_backfill(p1).state == "dismissed"
  end

  test "an open finding's duplicates close; its own proposal stays", ctx do
    f = finding(ctx, [])
    dupe = drafted(ctx, f, 3)
    mine = drafted(ctx, f, 4)
    own(f, mine)

    backfill()

    assert %{state: "dismissed", note: note} = after_backfill(dupe)
    assert note == "duplicate of proposal ##{mine.id} (finding ##{f.id})"
    assert %{state: "open", note: nil} = after_backfill(mine)
  end

  test "an event finding's proposal closes; a lesson's stays", ctx do
    health = finding(ctx, source: "health", text: "Lane held, nothing moving")
    rejection = finding(ctx, source: "rejection")
    h = drafted(ctx, health, 3)
    own(health, h)
    r = drafted(ctx, rejection, 3)
    own(rejection, r)

    backfill()

    assert after_backfill(h).note ==
             "finding ##{health.id} is a health event: it records what happened, not a lesson"

    assert after_backfill(r).state == "open"
  end

  test "proposals filed by hand, decided ones and other checks are left alone", ctx do
    decided = finding(ctx, status: "promoted", note: "W-1950")

    by_hand =
      drafted(ctx, decided, 3,
        explanation: "From triaging the board's findings: the lessons that recurred, as rules"
      )

    person = drafted(ctx, decided, 4, state: "dismissed")
    other = drafted(ctx, decided, 5, check: "stale_in_progress")

    backfill()

    assert %{state: "open", note: nil} = after_backfill(by_hand)
    assert %{state: "dismissed", note: nil} = after_backfill(person)
    assert %{state: "open", note: nil} = after_backfill(other)
  end
end
