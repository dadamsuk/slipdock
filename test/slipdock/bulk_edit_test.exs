defmodule Slipdock.BulkEditTest do
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Boards, BulkEdit, Repo}
  alias Slipdock.Boards.Card

  setup do
    owner = user_fixture()
    board = board_fixture(%{}, owner: owner)
    [backlog, todo | _] = board.columns
    a = card_fixture(todo, %{"title" => "A"})
    b = card_fixture(todo, %{"title" => "B"})
    c = card_fixture(todo, %{"title" => "C"})
    %{owner: owner, board: board, backlog: backlog, todo: todo, a: a, b: b, c: c}
  end

  defp fresh(card), do: Repo.get(Card, card.id)
  defp ids(cards), do: Enum.map(cards, & &1.id)

  describe "apply/4" do
    test "archives every selected card and leaves the rest", %{owner: o, board: bd} = ctx do
      assert {:ok, %{changed: 2, failed: []}} =
               BulkEdit.apply(o, bd, ids([ctx.a, ctx.b]), :archive)

      assert fresh(ctx.a).archived_at
      assert fresh(ctx.b).archived_at
      refute fresh(ctx.c).archived_at
    end

    test "deletes every selected card", %{owner: o, board: bd} = ctx do
      assert {:ok, %{changed: 2}} = BulkEdit.apply(o, bd, ids([ctx.a, ctx.c]), :delete)
      assert is_nil(fresh(ctx.a)) and is_nil(fresh(ctx.c))
      assert fresh(ctx.b)
    end

    test "completes and reopens", %{owner: o, board: bd} = ctx do
      assert {:ok, %{changed: 2}} = BulkEdit.apply(o, bd, ids([ctx.a, ctx.b]), :complete)
      assert fresh(ctx.a).completed and fresh(ctx.b).completed
      assert {:ok, %{changed: 1}} = BulkEdit.apply(o, bd, [ctx.a.id], :reopen)
      refute fresh(ctx.a).completed
    end

    test "adds a tag only once, and removes it", %{owner: o, board: bd} = ctx do
      tag = tag_fixture(bd, "ops")
      {:ok, _} = Boards.set_card_tags(ctx.a, [tag])

      assert {:ok, %{changed: 2, failed: []}} =
               BulkEdit.apply(o, bd, ids([ctx.a, ctx.b]), {:add_tag, to_string(tag.id)})

      for card <- [ctx.a, ctx.b],
          do: assert([%{name: "ops"}] = Repo.preload(fresh(card), :tags).tags)

      assert {:ok, %{changed: 2}} =
               BulkEdit.apply(o, bd, ids([ctx.a, ctx.b]), {:remove_tag, tag.id})

      assert Repo.preload(fresh(ctx.a), :tags).tags == []
    end

    test "refuses a tag from another board before changing anything",
         %{owner: o, board: bd} = ctx do
      other = tag_fixture(board_fixture(%{}, owner: o), "elsewhere")

      assert {:error, "That tag isn't on this board."} =
               BulkEdit.apply(o, bd, [ctx.a.id], {:add_tag, other.id})

      assert Repo.preload(fresh(ctx.a), :tags).tags == []
    end

    test "sets priority and flags", %{owner: o, board: bd} = ctx do
      assert {:ok, %{changed: 2}} =
               BulkEdit.apply(o, bd, ids([ctx.a, ctx.b]), {:priority, "high"})

      assert fresh(ctx.a).priority == "high" and fresh(ctx.b).priority == "high"

      {:ok, _} = Boards.update_card(ctx.a, %{"flags" => ["blocked"]})
      assert {:ok, _} = BulkEdit.apply(o, bd, ids([ctx.a, ctx.b]), {:add_flag, "blocked"})
      assert fresh(ctx.a).flags == ["blocked"]
      assert fresh(ctx.b).flags == ["blocked"]

      assert {:ok, _} = BulkEdit.apply(o, bd, [ctx.a.id], {:remove_flag, "blocked"})
      assert fresh(ctx.a).flags == []

      assert {:error, "That isn't a priority."} =
               BulkEdit.apply(o, bd, [ctx.a.id], {:priority, "x"})

      assert {:error, "That isn't a flag."} = BulkEdit.apply(o, bd, [ctx.a.id], {:add_flag, "x"})
    end

    test "assigns me and unassigns", %{owner: o, board: bd} = ctx do
      assert {:ok, %{changed: 2}} = BulkEdit.apply(o, bd, ids([ctx.a, ctx.b]), :assign_me)
      assert fresh(ctx.a).assignee_id == o.id

      assert {:ok, _} = BulkEdit.apply(o, bd, [ctx.a.id], :unassign)
      assert is_nil(fresh(ctx.a).assignee_id)
      assert fresh(ctx.b).assignee_id == o.id
    end

    test "moves to a list on the same board", %{owner: o, board: bd, backlog: backlog} = ctx do
      assert {:ok, %{changed: 2}} =
               BulkEdit.apply(o, bd, ids([ctx.a, ctx.b]), {:move, backlog.id})

      assert fresh(ctx.a).column_id == backlog.id and fresh(ctx.b).column_id == backlog.id
      assert fresh(ctx.c).column_id == ctx.todo.id
    end

    test "moves to a list on another board the user can write to", %{owner: o, board: bd} = ctx do
      other = board_fixture(%{}, owner: o)
      dest = hd(other.columns)

      assert {:ok, %{changed: 2}} =
               BulkEdit.apply(o, bd, ids([ctx.a, ctx.b]), {:move, "#{dest.id}"})

      assert fresh(ctx.a).board_id == other.id and fresh(ctx.a).column_id == dest.id
      assert fresh(ctx.b).board_id == other.id
    end

    test "refuses a move to a board the user can't write to", %{owner: o, board: bd} = ctx do
      theirs = board_fixture(%{}, owner: user_fixture("someone@example.com"))

      assert {:error, "You can't move cards to that list."} =
               BulkEdit.apply(o, bd, [ctx.a.id], {:move, hd(theirs.columns).id})

      assert {:error, _} = BulkEdit.apply(o, bd, [ctx.a.id], {:move, "nope"})
      assert fresh(ctx.a).board_id == bd.id
    end

    test "leaves out cards on other boards, archived cards and junk ids",
         %{owner: o, board: bd} = ctx do
      elsewhere = card_fixture(hd(board_fixture(%{}, owner: o).columns))
      {:ok, _} = Boards.archive_card(ctx.b)

      assert {:ok, %{changed: 1, failed: []}} =
               BulkEdit.apply(o, bd, [ctx.a.id, ctx.b.id, elsewhere.id, "x", nil], :complete)

      refute fresh(elsewhere).completed
      refute fresh(ctx.b).completed
    end

    test "with no cards left, nothing is tried", %{owner: o, board: bd} do
      assert {:error, "No cards are selected."} = BulkEdit.apply(o, bd, [], :archive)
    end

    test "refuses a reader without write access", %{board: bd} = ctx do
      reader = user_fixture("reader@example.com")
      share_fixture(bd, reader, "read")

      assert {:error, "You have read-only access to this board."} =
               BulkEdit.apply(reader, bd, [ctx.a.id], :delete)

      assert fresh(ctx.a)
    end

    test "an unknown action is refused", %{owner: o, board: bd} = ctx do
      assert {:error, _} = BulkEdit.apply(o, bd, [ctx.a.id], :explode)
    end

    test "one card refusing doesn't stop the rest", %{owner: o, board: bd} = ctx do
      # Into A's own subcards: A can't go there, B can.
      {:ok, t} = Boards.find_template(nil, "Simple")

      {:ok, sub} =
        Boards.create_sub_board(ctx.a, t, code: "bk#{System.unique_integer([:positive])}")

      dest = hd(Boards.get_board!(sub.id).columns)

      assert {:ok, %{changed: 1, failed: [{%{id: a_id}, reason}]}} =
               BulkEdit.apply(o, bd, ids([ctx.a, ctx.b]), {:move, dest.id})

      assert a_id == ctx.a.id
      assert reason =~ "its own subcards"
      assert fresh(ctx.a).board_id == bd.id
      assert fresh(ctx.b).board_id == sub.id
    end
  end

  describe "parse_action/1" do
    test "reads what the bar sends" do
      assert {:ok, :archive, "Archived"} = BulkEdit.parse_action("archive")
      assert {:ok, {:add_tag, "7"}, _} = BulkEdit.parse_action("tag:7")
      assert {:ok, {:remove_tag, "7"}, _} = BulkEdit.parse_action("untag:7")
      assert {:ok, {:priority, "high"}, _} = BulkEdit.parse_action("priority:high")
      assert {:ok, {:add_flag, "blocked"}, _} = BulkEdit.parse_action("flag:blocked")
      assert {:ok, {:remove_flag, "blocked"}, _} = BulkEdit.parse_action("unflag:blocked")
      assert {:ok, {:move, "12"}, "Moved"} = BulkEdit.parse_action("move:12")
      assert :error = BulkEdit.parse_action("")
      assert :error = BulkEdit.parse_action("explode")
      assert :error = BulkEdit.parse_action(nil)
    end
  end

  describe "describe/2" do
    test "says how many, and which failed and why", %{a: a} do
      assert BulkEdit.describe({:ok, %{changed: 1, failed: []}}, "Archived") == "Archived 1 card."
      assert BulkEdit.describe({:ok, %{changed: 3, failed: []}}, "Moved") == "Moved 3 cards."

      assert BulkEdit.describe({:ok, %{changed: 2, failed: [{a, "no room"}]}}, "Moved") ==
               "Moved 2 cards; 1 couldn't be: “A”: no room"

      assert BulkEdit.describe({:error, "Nope."}, "Moved") == "Nope."
    end
  end

  describe "destinations/2" do
    test "this board first, then other writable boards, never read-only ones", %{
      owner: o,
      board: bd
    } do
      mine = board_fixture(%{"name" => "Mine"}, owner: o)
      theirs = board_fixture(%{}, owner: user_fixture("other@example.com"))
      share_fixture(theirs, o, "read")

      [{first, cols} | rest] = BulkEdit.destinations(o, bd)
      assert first.id == bd.id
      assert ids(cols) == ids(bd.columns)
      rest_ids = Enum.map(rest, fn {b, _} -> b.id end)
      assert mine.id in rest_ids
      refute theirs.id in rest_ids
    end
  end
end
