defmodule Slipdock.HandoffsTest do
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures
  alias Slipdock.Boards
  alias Slipdock.Boards.Handoff

  setup do
    board = board_fixture()
    %{board: board, card: card_fixture(hd(board.columns)), user: user_fixture()}
  end

  defp leave(card, user, next, body \\ nil) do
    {:ok, h} = Boards.leave_handoff(card, user, %{next_step: next, body: body, via: "ui"})
    h
  end

  describe "leaving a handoff" do
    test "the newest write is the handoff and the older ones its history", %{
      card: card,
      user: user
    } do
      assert Boards.current_handoff(card) == nil

      first = leave(card, user, "Write the migration")
      second = leave(card, user, "Wire up the API", "State: schema done")

      assert %Handoff{id: id, next_step: "Wire up the API", body: "State: schema done"} =
               Boards.current_handoff(card)

      assert id == second.id
      assert Boards.current_handoff(card).user.id == user.id
      assert Enum.map(Boards.handoff_history(card), & &1.id) == [second.id, first.id]
    end

    test "keeps who wrote it, how and for which job", %{card: card, user: user} do
      {:ok, h} = Boards.leave_handoff(card, user, %{"next_step" => "Go on", "via" => "mcp"})
      assert h.user_id == user.id
      assert h.via == "mcp"
      assert h.user.email == user.email
      assert h.job_id == nil
    end

    test "next_step is required, one line, and at most 280 characters", %{
      card: card,
      user: user
    } do
      for blank <- [nil, "", "   "] do
        assert {:error, cs} = Boards.leave_handoff(card, user, %{next_step: blank, via: "ui"})
        assert %{next_step: ["can't be blank: say the one next step"]} = errors_on(cs)
      end

      assert {:error, cs} =
               Boards.leave_handoff(card, user, %{
                 next_step: String.duplicate("x", 281),
                 via: "ui"
               })

      assert %{next_step: ["should be at most 280 character(s)"]} = errors_on(cs)

      assert {:error, cs} = Boards.leave_handoff(card, user, %{next_step: "a\nb", via: "ui"})
      assert %{next_step: ["must be one line"]} = errors_on(cs)

      assert {:ok, _} =
               Boards.leave_handoff(card, user, %{
                 next_step: String.duplicate("x", 280),
                 via: "ui"
               })
    end

    test "the body is capped at 8000 and a blank one is no body", %{card: card, user: user} do
      assert {:error, cs} =
               Boards.leave_handoff(card, user, %{
                 next_step: "n",
                 body: String.duplicate("x", 8001),
                 via: "ui"
               })

      assert %{body: ["should be at most 8000 character(s)"]} = errors_on(cs)
      assert leave(card, user, "n", "  \n ").body == nil
    end

    test "via must be one of the known ways in", %{card: card, user: user} do
      assert {:error, cs} = Boards.leave_handoff(card, user, %{next_step: "n", via: "fax"})
      assert %{via: ["is invalid"]} = errors_on(cs)
      assert {:error, cs} = Boards.leave_handoff(card, user, %{next_step: "n"})
      assert %{via: ["can't be blank"]} = errors_on(cs)
    end

    test "logs a line with the next step", %{board: board, card: card, user: user} do
      leave(card, user, "Run the suite")

      assert [%{kind: "handoff", message: message}] =
               Boards.list_activities(board.id, 50, card.id)
               |> Enum.filter(&(&1.kind == "handoff"))

      assert message == "left a handoff on “#{card.title}”: Run the suite"
    end

    test "is told to the board", %{board: board, card: card, user: user} do
      Boards.subscribe(board.id)
      leave(card, user, "Next")
      assert_receive {:board_changed, _}
    end
  end

  describe "clearing" do
    test "writes an empty row, so the card has no handoff but the history shows it", %{
      board: board,
      card: card,
      user: user
    } do
      leave(card, user, "Next")
      assert {:ok, clear} = Boards.clear_handoff(card, user, %{via: "cli"})
      assert Handoff.cleared?(clear)
      assert Boards.current_handoff(card) == nil
      assert [%{id: id}, %{next_step: "Next"}] = Boards.handoff_history(card)
      assert id == clear.id

      assert Enum.any?(
               Boards.list_activities(board.id, 50, card.id),
               &(&1.message == "cleared the handoff on “#{card.title}”")
             )

      # And a new note after a clear is the handoff again.
      leave(card, user, "Back to it")
      assert Boards.current_handoff(card).next_step == "Back to it"
    end

    test "completing the card keeps the note", %{card: card, user: user} do
      leave(card, user, "Next")
      {:ok, _} = Boards.update_card(card, %{"completed" => true})
      assert Boards.current_handoff(card).next_step == "Next"
    end
  end

  describe "many cards at once" do
    test "current_handoffs/1 maps each card with a handoff to its newest", %{
      board: board,
      card: card,
      user: user
    } do
      other = card_fixture(hd(board.columns))
      cleared = card_fixture(hd(board.columns))
      none = card_fixture(hd(board.columns))

      leave(card, user, "old")
      leave(card, user, "new")
      leave(other, user, "other")
      leave(cleared, user, "gone")
      Boards.clear_handoff(cleared, user, %{via: "ui"})

      map = Boards.current_handoffs([card.id, other.id, cleared.id, none.id])
      assert map |> Map.keys() |> Enum.sort() == Enum.sort([card.id, other.id])
      assert map[card.id].next_step == "new"
      assert map[other.id].next_step == "other"
      assert Boards.current_handoffs([]) == %{}
    end
  end

  test "an author who is deleted leaves the note behind", %{card: card} do
    gone = user_fixture("gone@example.com")
    leave(card, gone, "Still here")
    Slipdock.Repo.delete!(gone)
    assert %{next_step: "Still here", user: nil} = Boards.current_handoff(card)
  end

  test "deleting the card deletes its handoffs", %{card: card, user: user} do
    leave(card, user, "Next")
    Slipdock.Repo.delete!(card)
    assert Slipdock.Repo.aggregate(Handoff, :count) == 0
  end

  test "handoff_written_since?/2 says whether anyone wrote one since", %{card: card, user: user} do
    before = DateTime.add(DateTime.utc_now(), -5) |> DateTime.truncate(:second)
    refute Boards.handoff_written_since?(card.id, before)
    leave(card, user, "Next")
    assert Boards.handoff_written_since?(card.id, before)
    refute Boards.handoff_written_since?(card.id, DateTime.add(DateTime.utc_now(), 60))
  end
end
