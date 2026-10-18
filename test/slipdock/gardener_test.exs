defmodule Slipdock.GardenerTest do
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.Boards
  alias Slipdock.Gardener
  alias Slipdock.Gardener.{Context, Settings, Suggestion}

  # A check for the core alone: every open card titled "Rot…" anywhere in
  # the tree is a finding, fixed by completing it and moving it to Done.
  defmodule RotCheck do
    @behaviour Slipdock.Gardener.Check
    alias Slipdock.Gardener.Context

    def key, do: "rot"
    def label, do: "Rot"
    def defaults, do: %{"enabled" => true, "days" => 14}

    def find(ctx, _settings) do
      for board_id <- ctx.board_ids,
          card <- Slipdock.Rollup.board_cards(ctx.rollup, board_id),
          String.starts_with?(card.title, "Rot"),
          not card.completed do
        done = Context.first_column(ctx, card.board_id, "done")

        %{
          subject: %{"cards" => [card.id]},
          state: card.updated_at,
          proposal: [
            %{"op" => "complete", "card" => card.id},
            %{"op" => "move", "card" => card.id, "column" => done.id}
          ],
          alternatives: %{"flag" => [%{"op" => "flag", "card" => card.id, "flag" => "review"}]},
          explanation: "“#{card.title}” is rotting"
        }
      end
    end
  end

  defmodule OffCheck do
    @behaviour Slipdock.Gardener.Check
    def key, do: "off"
    def label, do: "Off by default"
    def defaults, do: %{"enabled" => false}

    def find(_ctx, _settings),
      do: raise("a check that is off is never asked")
  end

  @checks [RotCheck, OffCheck]

  setup do
    owner = user_fixture()
    board = board_fixture(%{}, owner: owner)
    [_backlog, todo, doing, done] = board.columns
    %{owner: owner, board: board, todo: todo, doing: doing, done: done}
  end

  defp run(board, opts \\ []), do: Gardener.run(board, Keyword.put_new(opts, :checks, @checks))

  defp touch(card, title) do
    # A second later, so the fingerprint's updated_at moves on.
    Repo.update_all(
      from(c in Boards.Card, where: c.id == ^card.id),
      set: [title: title, updated_at: DateTime.add(DateTime.utc_now(:second), 5)]
    )
  end

  describe "a run" do
    test "keeps what the checks find, with counts", %{board: board, todo: todo} do
      rot = card_fixture(todo, %{"title" => "Rot one"})
      card_fixture(todo, %{"title" => "Fine"})

      {:ok, run} = run(board, trigger: "mcp")

      assert run.trigger == "mcp"
      assert run.finished_at
      assert run.counts == %{"total" => 1, "new" => 1, "rot" => 1}

      assert [%Suggestion{} = s] = Gardener.list_open(board)
      assert s.check == "rot"
      assert s.subject == %{"cards" => [rot.id]}
      assert s.run_id == run.id
      assert s.explanation == "“Rot one” is rotting"
      assert [%{"op" => "complete"}, %{"op" => "move"}] = s.proposal
      assert Gardener.open_count(board) == 1
    end

    test "covers the boards beneath, and a check that is off is not run", %{
      board: board,
      todo: todo
    } do
      epic = card_fixture(todo, %{"title" => "Epic"})
      {:ok, t} = Boards.find_template(nil, "Simple")
      {:ok, sub} = sub_board(epic, t)
      sub = Boards.get_board!(sub.id)
      deep = card_fixture(hd(sub.columns), %{"title" => "Rot deep"})

      {:ok, _} = run(board)
      assert [%{subject: %{"cards" => [id]}}] = Gardener.list_open(board)
      assert id == deep.id
    end

    test "only: runs just the checks named", %{board: board, todo: todo} do
      card_fixture(todo, %{"title" => "Rot"})
      {:ok, run} = run(board, only: ["nothing"])
      assert run.counts["total"] == 0
      assert Gardener.list_open(board) == []
    end

    test "a second run repeats nothing", %{board: board, todo: todo} do
      card_fixture(todo, %{"title" => "Rot"})
      {:ok, _} = run(board)
      {:ok, again} = run(board)

      assert again.counts == %{"total" => 1, "new" => 0, "rot" => 1}
      assert length(Repo.all(from(s in Suggestion, where: s.board_id == ^board.id))) == 1
    end

    test "an open suggestion no longer found expires", %{board: board, todo: todo} do
      rot = card_fixture(todo, %{"title" => "Rot"})
      {:ok, _} = run(board)
      [s] = Gardener.list_open(board)

      touch(rot, "Fixed by hand")
      {:ok, run} = run(board)

      assert run.counts["total"] == 0
      assert Repo.get!(Suggestion, s.id).state == "expired"
    end

    test "turning a check off in settings leaves it out", %{board: board, todo: todo} do
      card_fixture(todo, %{"title" => "Rot"})
      {:ok, board} = Settings.put(board, RotCheck, %{"enabled" => false})
      {:ok, run} = run(board)
      assert run.counts["total"] == 0
    end
  end

  describe "fingerprints" do
    test "a dismissed suggestion doesn't come back on the next run", %{
      board: board,
      todo: todo,
      owner: owner
    } do
      card_fixture(todo, %{"title" => "Rot"})
      {:ok, _} = run(board)
      [s] = Gardener.list_open(board)

      {:ok, dismissed} = Gardener.dismiss(s, owner)
      assert dismissed.state == "dismissed"
      assert dismissed.decided_by_id == owner.id
      assert dismissed.decided_at

      {:ok, run} = run(board)
      assert run.counts["new"] == 0
      assert Gardener.list_open(board) == []
    end

    test "comes back once the subject changes", %{board: board, todo: todo, owner: owner} do
      rot = card_fixture(todo, %{"title" => "Rot"})
      {:ok, _} = run(board)
      [s] = Gardener.list_open(board)
      {:ok, _} = Gardener.dismiss(s, owner)

      touch(rot, "Rot still")
      {:ok, run} = run(board)

      assert run.counts["new"] == 1
      assert [again] = Gardener.list_open(board)
      assert again.fingerprint != s.fingerprint
    end

    test "an applied suggestion isn't suggested again", %{board: board, todo: todo, owner: owner} do
      rot = card_fixture(todo, %{"title" => "Rot"})
      {:ok, _} = run(board)
      [s] = Gardener.list_open(board)
      {:ok, _} = Gardener.apply(s, owner, choice: "flag")

      # Flagging left the card open and touched it, but the same state again
      # would match: put updated_at back to prove the fingerprint is kept.
      Repo.update_all(from(c in Boards.Card, where: c.id == ^rot.id),
        set: [updated_at: rot.updated_at]
      )

      {:ok, run} = run(board)
      assert run.counts["new"] == 0
    end

    test "depend on the check, the subjects and the state" do
      f = %{subject: %{"cards" => [2, 1]}, state: 1}

      assert Gardener.fingerprint("a", f) ==
               Gardener.fingerprint("a", %{f | subject: %{"cards" => [1, 2]}})

      refute Gardener.fingerprint("a", f) == Gardener.fingerprint("b", f)
      refute Gardener.fingerprint("a", f) == Gardener.fingerprint("a", %{f | state: 2})

      refute Gardener.fingerprint("a", f) ==
               Gardener.fingerprint("a", %{f | subject: %{"pages" => [1, 2]}})
    end
  end

  describe "applying" do
    setup %{board: board, todo: todo} do
      rot = card_fixture(todo, %{"title" => "Rot"})
      {:ok, _} = run(board)
      [s] = Gardener.list_open(board)
      %{rot: rot, s: s}
    end

    test "takes the steps through the ordinary functions", %{
      s: s,
      rot: rot,
      owner: owner,
      done: done
    } do
      {:ok, applied} = Gardener.apply(s, owner)

      assert applied.state == "applied"
      assert applied.decided_by_id == owner.id
      card = Boards.get_card!(rot.id)
      assert card.completed
      assert card.column_id == done.id

      messages =
        Repo.all(from(a in Boards.Activity, where: a.card_id == ^rot.id, select: a.message))

      assert "via gardener: “Rot” is rotting" in messages
      assert Enum.any?(messages, &(&1 =~ "complete"))
    end

    test "fires the board's automations", %{board: board, s: s, rot: rot, owner: owner} do
      rule_fixture(board, %{
        "trigger" => %{"type" => "card_completed"},
        "actions" => [%{"type" => "comment", "body" => "Closed by a rule."}]
      })

      {:ok, _} = Gardener.apply(s, owner)
      assert Enum.any?(Boards.get_card!(rot.id).comments, &(&1.body == "Closed by a rule."))
    end

    test "an alternative instead of the proposal", %{s: s, rot: rot, owner: owner} do
      {:ok, _} = Gardener.apply(s, owner, choice: "flag")
      card = Boards.get_card!(rot.id)
      assert "review" in card.flags
      refute card.completed

      assert {:error, "that suggestion is applied, not open"} =
               Gardener.apply(s |> Repo.reload!(), owner)
    end

    test "an unknown alternative is refused", %{s: s, owner: owner} do
      assert {:error, msg} = Gardener.apply(s, owner, choice: "burn")
      assert msg =~ "no fix called “burn”"
      assert Repo.reload!(s).state == "open"
    end

    test "is refused to somebody who can only read the board", %{
      board: board,
      s: s,
      rot: rot
    } do
      reader = user_fixture("reader-#{System.unique_integer([:positive])}@example.com")
      share_fixture(board, reader, "read")

      assert {:error, :forbidden} = Gardener.apply(s, reader)
      assert {:error, :forbidden} = Gardener.dismiss(s, reader)
      assert {:error, :forbidden} = Gardener.apply(s, nil)
      refute Boards.get_card!(rot.id).completed
      assert Repo.reload!(s).state == "open"
    end

    test "decide/4 names the decision", %{s: s, owner: owner} do
      assert {:error, "decision must be apply or dismiss"} = Gardener.decide(s, owner, "maybe")
      assert {:ok, %{state: "dismissed"}} = Gardener.decide(s, owner, "dismiss")
    end
  end

  describe "undo" do
    setup %{board: board, todo: todo, owner: owner} do
      rot = card_fixture(todo, %{"title" => "Rot"})
      {:ok, _} = run(board)
      [s] = Gardener.list_open(board)
      {:ok, applied} = Gardener.apply(s, owner)
      %{rot: rot, applied: applied}
    end

    test "puts everything back and opens it again", %{
      applied: applied,
      rot: rot,
      owner: owner,
      todo: todo,
      board: board
    } do
      assert [%{id: id}] = Gardener.list_applied(board)
      assert id == applied.id

      {:ok, undone} = Gardener.undo(applied, owner)

      assert undone.state == "open"
      assert undone.undo == nil
      card = Boards.get_card!(rot.id)
      refute card.completed
      assert card.column_id == todo.id

      assert Repo.exists?(
               from(a in Boards.Activity,
                 where: a.card_id == ^rot.id and like(a.message, "undone via gardener%")
               )
             )
    end

    test "after a later conflicting edit is refused with the reason", %{
      applied: applied,
      rot: rot,
      owner: owner,
      doing: doing
    } do
      :ok = Boards.move_card(rot.id, doing.id)

      assert {:error, reason} = Gardener.undo(applied, owner)
      assert reason =~ "card ##{rot.id} “Rot” has been moved to another list since"
      # Nothing was undone: it stays where it was put, and still applied.
      assert Boards.get_card!(rot.id).column_id == doing.id
      assert Repo.reload!(applied).state == "applied"
    end

    test "only an applied suggestion", %{applied: applied, owner: owner} do
      {:ok, open} = Gardener.undo(applied, owner)
      assert {:error, "only an applied suggestion can be undone"} = Gardener.undo(open, owner)
    end
  end

  describe "the context" do
    test "knows each list's category and the first of one", %{
      board: board,
      done: done,
      doing: doing
    } do
      ctx = Context.new(board)
      assert Context.first_column(ctx, board.id, "done").id == done.id
      assert Context.category(ctx, %{column_id: doing.id}) == "doing"
      assert Context.category(ctx, %{column_id: -1}) == nil
      assert ctx.board_ids == [board.id]
    end
  end

  describe "settings" do
    test "are the defaults with the board's changes over them", %{board: board} do
      assert Settings.for(board, RotCheck) == %{"enabled" => true, "days" => 14}

      {:ok, board} = Settings.put(board, RotCheck, %{"days" => "30"})
      assert Settings.for(board, RotCheck) == %{"enabled" => true, "days" => 30}
      assert board.gardening == %{"rot" => %{"days" => 30}}

      # Setting a value back to its default forgets it.
      {:ok, board} = Settings.put(board, RotCheck, %{days: 14})
      assert board.gardening == %{}
      refute Settings.enabled?(board, OffCheck)
    end

    test "refuse unknown keys and bad values", %{board: board} do
      assert {:error, "unknown setting: colour"} = Settings.put(board, RotCheck, %{"colour" => 1})

      assert {:error, "days must be a whole number above 0"} =
               Settings.put(board, RotCheck, %{"days" => 0})

      assert {:error, "days must be a whole number above 0"} =
               Settings.put(board, RotCheck, %{"days" => "x"})

      assert {:error, "enabled must be true or false"} =
               Settings.put(board, RotCheck, %{"enabled" => "yes"})
    end
  end
end
