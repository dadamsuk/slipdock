defmodule Slipdock.Gardener.Checks.HandbookGapTest do
  @moduledoc "Cards closed on a handbook board without a `Handbook:` line (#1267)."
  use Slipdock.DataCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures
  import Slipdock.GardenerHelpers

  alias Slipdock.{Boards, Gardener, Handbook, Repo}
  alias Slipdock.Gardener.Checks.HandbookGap
  alias Slipdock.Gardener.Settings

  setup do
    user = user_fixture()
    board = board_fixture(%{}, owner: user)
    [_backlog, todo | _] = board.columns
    %{user: user, board: board, todo: todo}
  end

  defp done_card(col, title) do
    card = card_fixture(col, %{"title" => title})
    {:ok, card} = Boards.update_card(card, %{"completed" => true})
    card
  end

  defp install(user, board) do
    {:ok, _} = Handbook.install(user, board)
    # The seed card the install makes is open; it plays no part here.
    Handbook.find(board)
  end

  test "a board without a handbook finds nothing", %{board: board, todo: todo} do
    done_card(todo, "No gate")
    assert find(HandbookGap, board) == []
  end

  test "a card done since the install without the line is found, and asked about",
       %{user: user, board: board, todo: todo} do
    install(user, board)
    card = done_card(todo, "Skipped it")

    assert [finding] = find(HandbookGap, board)
    assert finding.subject == %{"cards" => [card.id]}
    assert finding.explanation == "##{card.id} closed without a Handbook line"
    assert [%{"op" => "comment", "card" => id, "body" => body}] = finding.proposal
    assert id == card.id
    assert body =~ "**Handbook gate skipped.**"
    # The nudge itself must not read as the line, or applying it would clear it.
    assert Handbook.gate_line(body) == nil
    assert finding.alternatives == %{"reopen" => [%{"op" => "reopen", "card" => card.id}]}
  end

  test "a Handbook line, `no change (…)` included, counts as the gate run",
       %{user: user, board: board, todo: todo} do
    install(user, board)
    updated = done_card(todo, "Updated")
    unchanged = done_card(todo, "Unchanged")
    {:ok, _} = Boards.add_comment(updated, "**Done.**\n\n- Handbook: updated W-3 §Contexts")
    {:ok, _} = Boards.add_comment(unchanged, "**Done.**\n\nHandbook: no change (tests only)")
    {:ok, _} = Boards.add_comment(done_card(todo, "Mentioned"), "the handbook: later")

    assert [%{explanation: e}] = find(HandbookGap, board)
    assert e =~ "closed without a Handbook line"
    refute e =~ "##{updated.id} "
  end

  test "cards done before the install, open cards and archived ones are ignored",
       %{user: user, board: board, todo: todo} do
    early = done_card(todo, "Before")
    hb = install(user, board)

    Repo.update_all(from(c in Boards.Card, where: c.id == ^early.id),
      set: [completed_at: DateTime.add(hb.installed_at, -60)]
    )

    card_fixture(todo, %{"title" => "Open"})
    {:ok, _} = Boards.archive_card(done_card(todo, "Archived"))

    assert find(HandbookGap, board) == []
  end

  test "subcards on a sub-board are checked against the root's handbook",
       %{user: user, board: board, todo: todo} do
    install(user, board)
    epic = card_fixture(todo, %{"title" => "Epic"})
    {:ok, t} = Boards.find_template(nil, "Simple")
    {:ok, sub} = sub_board(epic, t)
    [sub_col | _] = Boards.get_board!(sub.id).columns
    sub_card = done_card(sub_col, "Deep")

    assert sub_card.id in found_ids(HandbookGap, board)
    assert sub_card.id in found_ids(HandbookGap, Boards.get_board!(sub.id))
  end

  test "resolving it clears it at the next run; settings switch it off",
       %{user: user, board: board, todo: todo} do
    install(user, board)
    card = done_card(todo, "Late")

    {:ok, run} = Gardener.run(board, only: ["handbook_gap"])
    assert run.counts["total"] == 1

    {:ok, _} = Boards.add_comment(card, "Handbook: no change (copy edit)")
    {:ok, run} = Gardener.run(board, only: ["handbook_gap"])
    assert run.counts["total"] == 0
    assert Gardener.list_open(board) == []

    done_card(todo, "Another")
    {:ok, board} = Settings.put(Repo.reload!(board), HandbookGap, %{"enabled" => false})
    {:ok, run} = Gardener.run(board, only: ["handbook_gap"])
    assert run.counts["total"] == 0
  end
end
