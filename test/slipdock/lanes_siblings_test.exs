defmodule Slipdock.LanesSiblingsTest do
  @moduledoc """
  Sibling subcards under one epic's runner job hold each other's lanes
  (#2597). The epic's job works every subcard (`Runners.worked/1`), and a
  card's own tree leaves out only itself, its subcards and its ancestors,
  never a sibling: so the epic's pass can't start a subcard whose paths
  overlap a sibling's while that sibling is in progress, or (on a pull
  request board) pending, merging or held.

  The sub-board here is made from the Simple template, as an epic's often
  is, and keeps its "Doing" list with no category: lanes read a doing list
  as the guide does (`Slipdock.Flow.doing_list?/1`), by its name when it has
  no category. Reading only `category == "doing"` is what let #2350 and
  #2351 start beside an overlapping sibling on such a sub-board.
  """
  use Slipdock.DataCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.{Actor, Boards, Lanes, Repo, Runners}
  alias Slipdock.Boards.Card

  setup do
    owner = user_fixture()
    board = board_fixture(%{"name" => "Sibling lanes", "code" => unique_code()}, owner: owner)

    {:ok, board} =
      Boards.update_board(board, %{
        "lanes" => true,
        "verify_work" => true,
        "ship_via" => "pull_request"
      })

    [_backlog, todo, doing, _done] = board.columns
    agent = %{Actor.unknown() | kind: "agent", via: "api", user_id: owner.id, agent: "bot"}

    epic = card_fixture(doing, %{"title" => "Epic"})
    {:ok, t} = Boards.Templates.find_template(nil, "Simple")
    {:ok, sub} = sub_board(epic, t)
    sub = Boards.get_board!(sub.id)
    sub_doing = Enum.find(sub.columns, &(&1.name == "Doing"))

    # The Simple template's lists as an epic's sub-board has them (#2597).
    assert sub_doing.category in [nil, ""]

    # The epic's runner job: the one job working every subcard.
    working_job_fixture(epic)

    %{
      board: board,
      todo: todo,
      doing: doing,
      epic: epic,
      sub_todo: hd(sub.columns),
      sub_doing: sub_doing,
      agent: agent
    }
  end

  defp card(column, title, paths) do
    card = card_fixture(column, %{"title" => title})
    {:ok, card} = Boards.Cards.update_card(card, %{"paths" => paths})
    card
  end

  defp set_verify(card, state),
    do: Repo.update_all(from(c in Card, where: c.id == ^card.id), set: [verify_state: state])

  defp move(card, column, ctx),
    do: Boards.Cards.move_card(card.id, column.id, nil, actor: ctx.agent)

  describe "siblings under one epic job" do
    test "a sibling in progress holds its lane against the next subcard", ctx do
      first = card(ctx.sub_doing, "First", "lib/slipdock/verified.ex\nlib/a.ex")
      second = card(ctx.sub_todo, "Second", "lib/slipdock/verified.ex\nlib/b.ex")

      assert %Card{id: id} = Lanes.conflict(second)
      assert id == first.id
      assert {:error, :unprocessable_entity, message} = move(second, ctx.sub_doing, ctx)
      assert message =~ "##{first.id}"
      assert Repo.reload!(second).column_id == ctx.sub_todo.id
    end

    test "a sibling pending, merging or held on a pull request board keeps its lane", ctx do
      first = card(ctx.sub_doing, "First", "lib/slipdock/verified.ex")
      second = card(ctx.sub_todo, "Second", "lib/slipdock/verified.ex")

      for state <- ["pending", "merging", "held"] do
        set_verify(first, state)
        assert %Card{id: id} = Lanes.conflict(second), state
        assert id == first.id
        assert {:error, :unprocessable_entity, _} = move(second, ctx.sub_doing, ctx)
      end
    end

    test "a sibling in progress refuses a subcard's paths widened onto it", ctx do
      card(ctx.sub_doing, "First", "lib/slipdock/verified.ex")
      second = card(ctx.sub_doing, "Second", "lib/b.ex")

      assert {:error, :paths, message} =
               Lanes.check_update(
                 second,
                 %{"paths" => "lib/b.ex\nlib/slipdock/verified.ex"},
                 ctx.agent
               )

      assert message =~ "lib/slipdock/verified.ex"
    end

    test "a subcard isn't made straight into the doing list beside an overlapping sibling", ctx do
      first = card(ctx.sub_doing, "First", "lib/slipdock/verified.ex")

      changeset =
        %Card{board_id: ctx.sub_doing.board_id, column_id: ctx.sub_doing.id}
        |> Ecto.Changeset.change(paths: ["lib/slipdock/verified.ex"])

      changeset = Lanes.check_create(changeset, ctx.sub_doing, ctx.agent)
      assert {message, _} = changeset.errors[:paths]
      assert message =~ "##{first.id}"
    end

    test "siblings whose paths don't overlap, or overlap only on shared paths, both start",
         ctx do
      {:ok, _} = Boards.update_board(ctx.board, %{"shared_paths" => "test/**"})
      card(ctx.sub_doing, "First", "lib/a.ex\ntest/a_test.exs")
      second = card(ctx.sub_todo, "Second", "lib/b.ex\ntest/a_test.exs")

      assert Lanes.conflict(second) == nil
      assert :ok = move(second, ctx.sub_doing, ctx)
    end

    test "a sibling that has merged frees the lane", ctx do
      first = card(ctx.sub_doing, "First", "lib/slipdock/verified.ex")
      second = card(ctx.sub_todo, "Second", "lib/slipdock/verified.ex")

      Repo.update_all(from(c in Card, where: c.id == ^first.id),
        set: [completed: true, verify_state: "accepted"]
      )

      assert Lanes.conflict(second) == nil
      assert :ok = move(second, ctx.sub_doing, ctx)
    end

    test "a sibling rejected back to the ready list frees it", ctx do
      first = card(ctx.sub_todo, "First", "lib/slipdock/verified.ex")
      set_verify(first, "rejected")
      second = card(ctx.sub_todo, "Second", "lib/slipdock/verified.ex")

      assert Lanes.conflict(second) == nil
    end

    test "with no job on the epic, a sibling in progress holds nothing (#1922)", ctx do
      Repo.delete_all(from(j in Slipdock.Runners.Job, where: j.card_id == ^ctx.epic.id))
      card(ctx.sub_doing, "First", "lib/slipdock/verified.ex")
      second = card(ctx.sub_todo, "Second", "lib/slipdock/verified.ex")

      assert Lanes.conflict(second) == nil
    end
  end

  describe "a doing list with no category, across the tree" do
    test "a subcard in it holds its lane against a card elsewhere on the tree", ctx do
      child = card(ctx.sub_doing, "Child", "lib/slipdock/verified.ex")
      other = card(ctx.todo, "Other", "lib/slipdock/verified.ex")

      assert {:error, :unprocessable_entity, message} = move(other, ctx.doing, ctx)
      assert message =~ "##{child.id}"
    end

    test "a queued job on a card overlapping it is held", ctx do
      child = card(ctx.sub_doing, "Child", "lib/slipdock/verified.ex")
      other = card(ctx.todo, "Other", "lib/slipdock/verified.ex")
      {:ok, _} = Runners.queue(other, %{pool: "dev", kind: "claude", prompt: "go"})

      assert %Card{id: id} = Lanes.held_cards(ctx.board.id)[other.id]
      assert id == child.id
    end

    test "a queued subcard in a list with no category is held behind a sibling; one in Doing isn't",
         ctx do
      first = card(ctx.sub_doing, "First", "lib/slipdock/verified.ex")
      waiting = card(ctx.sub_todo, "Waiting", "lib/slipdock/verified.ex")
      started = card(ctx.sub_doing, "Started", "lib/slipdock/verified.ex")

      for c <- [waiting, started],
          do: {:ok, _} = Runners.queue(c, %{pool: "dev", kind: "claude", prompt: "go"})

      held = Lanes.held_cards(ctx.board.id)
      assert %Card{id: id} = held[waiting.id]
      assert id == first.id
      refute Map.has_key?(held, started.id)
    end

    test "an epic whose subcard is in a Doing with no category is its pass's work, not held",
         ctx do
      running = card(ctx.doing, "Running", "lib/x.ex")
      working_job_fixture(running)
      epic = card(ctx.todo, "Second epic", "lib/**")
      {:ok, t} = Boards.Templates.find_template(nil, "Simple")
      {:ok, sub} = sub_board(epic, t)
      sub = Boards.get_board!(sub.id)
      card(Enum.find(sub.columns, &(&1.name == "Doing")), "Started", "lib/x.ex")
      card(hd(sub.columns), "Later", "lib/x.ex")
      {:ok, _} = Runners.queue(epic, %{pool: "dev", kind: "claude", prompt: "go"})

      assert Lanes.held_cards(ctx.board.id)[epic.id] == nil
      assert Lanes.conflict(epic) == nil
    end

    test "a list named like neither isn't one: a card in it holds nothing", ctx do
      assert ctx.sub_todo.category in [nil, ""]
      card(ctx.sub_todo, "Not started", "lib/slipdock/verified.ex")
      other = card(ctx.todo, "Other", "lib/slipdock/verified.ex")

      assert Lanes.conflict(other) == nil
      assert :ok = move(other, ctx.doing, ctx)
    end
  end
end
