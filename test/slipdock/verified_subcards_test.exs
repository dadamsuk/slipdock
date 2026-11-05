defmodule Slipdock.VerifiedSubcardsTest do
  @moduledoc """
  Orchestration fixes 5 (#1758): an agent can't complete (or, on a board
  that verifies work, submit) a card whose sub-board still has open cards,
  by a write or by a move into a done list, and the refusal names them. It
  holds on every board, with no switch; people, the in-app assistant and
  automations are never refused.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Actor, Boards, Verified}
  alias Slipdock.Boards.{Board, Card}

  setup do
    owner = user_fixture("owner@example.com")
    board = board_fixture(%{"name" => "Epics", "code" => unique_code()}, owner: owner)
    [_backlog, _todo, doing, done] = board.columns
    epic = card_fixture(doing, %{"title" => "Epic"})
    {:ok, t} = Boards.find_template(nil, "Simple")
    {:ok, sub} = sub_board(epic, t)
    [column | _] = Boards.get_board!(sub.id).columns
    agent = %{Actor.unknown() | kind: "agent", via: "mcp", user_id: owner.id, agent: "bot"}

    %{owner: owner, board: board, done: done, epic: epic, sub: sub, column: column, agent: agent}
  end

  defp complete(card, actor), do: Boards.update_card(card, %{"completed" => true}, actor: actor)
  defp fresh(card), do: Repo.get!(Card, card.id)

  test "with no switch on, an agent completing over open subcards is refused, naming them", ctx do
    assert Verified.switches(ctx.board) == []
    one = card_fixture(ctx.column, %{"title" => "Foo"})
    two = card_fixture(ctx.column, %{"title" => "Bar"})

    assert {:error, cs} = complete(ctx.epic, ctx.agent)
    assert %{completed: [message]} = errors_on(cs)
    assert message =~ "is refused: card ##{ctx.epic.id} has open subcards"
    assert message =~ "##{one.id} Foo, ##{two.id} Bar are still open"
    refute fresh(ctx.epic).completed
  end

  test "one open subcard is named on its own", ctx do
    one = card_fixture(ctx.column, %{"title" => "Foo"})
    assert {:error, cs} = complete(ctx.epic, ctx.agent)
    assert %{completed: [message]} = errors_on(cs)
    assert message =~ "##{one.id} Foo is still open"
  end

  test "a long list names ten and counts the rest", ctx do
    for n <- 1..12, do: card_fixture(ctx.column, %{"title" => "Sub #{n}"})
    assert {:error, cs} = complete(ctx.epic, ctx.agent)
    assert %{completed: [message]} = errors_on(cs)
    assert message =~ "Sub 10 and 2 more are still open"
    refute message =~ "Sub 11"
  end

  test "with every subcard done or archived it completes as before", ctx do
    card_fixture(ctx.column, %{"title" => "Done", "completed" => true})
    gone = card_fixture(ctx.column, %{"title" => "Gone"})
    {:ok, _} = Boards.archive_card(gone)

    assert Verified.open_subcards(ctx.epic) == []
    assert {:ok, %{completed: true}} = complete(ctx.epic, ctx.agent)
  end

  test "a card with no sub-board, or an empty one, completes as before", ctx do
    assert {:ok, %{completed: true}} = complete(ctx.epic, ctx.agent)
    plain = card_fixture(hd(ctx.board.columns), %{"title" => "Plain"})
    assert {:ok, %{completed: true}} = complete(plain, ctx.agent)
  end

  test "a complete subcard counts as done whatever its own sub-board holds", ctx do
    child = card_fixture(ctx.column, %{"title" => "Child"})
    {:ok, t} = Boards.find_template(nil, "Simple")
    {:ok, subsub} = sub_board(child, t)
    card_fixture(hd(Boards.get_board!(subsub.id).columns), %{"title" => "Grandchild"})
    {:ok, _} = complete(child, Actor.web(ctx.owner))

    assert {:ok, %{completed: true}} = complete(ctx.epic, ctx.agent)
  end

  test "an archived sub-board holds nothing open", ctx do
    card_fixture(ctx.column, %{"title" => "Foo"})
    ctx.sub |> Ecto.Changeset.change(archived_at: DateTime.utc_now(:second)) |> Repo.update!()
    assert {:ok, %{completed: true}} = complete(ctx.epic, ctx.agent)
  end

  test "a person, the in-app assistant and automations can always complete it", ctx do
    card_fixture(ctx.column, %{"title" => "Foo"})

    for actor <- [Actor.web(ctx.owner), %{ctx.agent | via: "assistant"}, Actor.automation()] do
      assert {:ok, %{completed: true}} = complete(fresh(ctx.epic), actor)
      {:ok, _} = Boards.update_card(fresh(ctx.epic), %{"completed" => false})
    end

    assert {:ok, %{completed: true}} = Boards.update_card(ctx.epic, %{"completed" => true})
  end

  test "an edit that doesn't complete the card is untouched", ctx do
    card_fixture(ctx.column, %{"title" => "Foo"})

    assert {:ok, %{title: "Renamed"}} =
             Boards.update_card(ctx.epic, %{"title" => "Renamed"}, actor: ctx.agent)

    {:ok, done} = complete(fresh(ctx.epic), Actor.web(ctx.owner))

    assert {:ok, _} =
             Boards.update_card(done, %{"completed" => true, "title" => "Again"},
               actor: ctx.agent
             )
  end

  describe "a move into a done list" do
    test "by an agent is refused with the open subcards named", ctx do
      one = card_fixture(ctx.column, %{"title" => "Foo"})

      assert {:error, :unprocessable_entity, message} =
               Boards.move_card(ctx.epic.id, ctx.done.id, nil, actor: ctx.agent)

      assert message =~ "card ##{ctx.epic.id} has open subcards: ##{one.id} Foo is still open"
      card = fresh(ctx.epic)
      refute card.completed
      refute card.column_id == ctx.done.id
    end

    test "by an agent goes through once they are done; a person's always does", ctx do
      one = card_fixture(ctx.column, %{"title" => "Foo"})
      assert :ok = Boards.move_card(ctx.epic.id, ctx.done.id, nil, actor: Actor.web(ctx.owner))
      assert fresh(ctx.epic).completed

      [_, _, doing, _] = ctx.board.columns
      :ok = Boards.move_card(ctx.epic.id, doing.id, nil, actor: Actor.web(ctx.owner))
      {:ok, _} = Boards.update_card(fresh(ctx.epic), %{"completed" => false})
      {:ok, _} = complete(one, Actor.web(ctx.owner))

      assert :ok = Boards.move_card(ctx.epic.id, ctx.done.id, nil, actor: ctx.agent)
      assert fresh(ctx.epic).completed
    end
  end

  describe "on a board that verifies work" do
    setup ctx do
      {:ok, board} = Boards.update_board(ctx.board, %{"verify_work" => true})
      # A sub-board takes the switch when it is made; this one already was.
      {:ok, _} = Boards.update_board(Boards.get_board!(ctx.sub.id), %{"verify_work" => true})
      %{board: board}
    end

    test "an agent's submission over open subcards is refused, and nothing goes pending", ctx do
      one = card_fixture(ctx.column, %{"title" => "Foo"})
      assert {:error, cs} = complete(fresh(ctx.epic), ctx.agent)
      assert %{completed: [message]} = errors_on(cs)
      assert message =~ "##{one.id} Foo is still open"
      assert fresh(ctx.epic).verify_state == nil
    end

    test "a submitted subcard counts as finished, so the epic can be submitted after it", ctx do
      one = card_fixture(ctx.column, %{"title" => "Foo"})
      assert Repo.get!(Board, ctx.sub.id).verify_work
      {:ok, %{verify_state: "pending"}} = complete(one, ctx.agent)

      assert Verified.open_subcards(ctx.epic) == []
      assert {:ok, %{verify_state: "pending"}} = complete(fresh(ctx.epic), ctx.agent)
    end

    test "a rejected subcard is open again", ctx do
      one = card_fixture(ctx.column, %{"title" => "Foo"})
      {:ok, _} = complete(one, ctx.agent)
      checker = %{ctx.agent | agent: "checker"}
      {:ok, _} = Verified.decide(fresh(one), "reject", %{"reason" => "No"}, checker, ctx.owner)

      assert Verified.open_subcards(ctx.epic) == [{one.id, "Foo"}]
      assert {:error, _} = complete(fresh(ctx.epic), ctx.agent)
    end
  end
end
