defmodule Slipdock.LanesEpicTest do
  @moduledoc """
  An epic's lane is its subcards' (#1811). An epic waits only when none of
  the subcards its pass could take could start, each checked on its own
  paths; with none to take, its own paths count. An epic in progress holds
  no lane of its own: its subcards in progress hold theirs.
  """
  use Slipdock.DataCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.{Actor, Boards, Lanes, Repo, Runners}
  alias Slipdock.Boards.Card

  setup do
    owner = user_fixture()
    board = board_fixture(%{"name" => "Epic lanes", "code" => unique_code()}, owner: owner)
    {:ok, board} = Boards.update_board(board, %{"lanes" => true})
    [_backlog, todo, doing, _done] = board.columns
    agent = %{Actor.unknown() | kind: "agent", via: "api", user_id: owner.id, agent: "bot"}
    {:ok, runner, _} = Runners.create_runner(board, %{"name" => "r", "pool" => "dev"})
    %{board: board, todo: todo, doing: doing, agent: agent, runner: runner}
  end

  defp card(column, title, paths, attrs \\ %{}) do
    card = card_fixture(column, Map.put(attrs, "title", title))
    {:ok, card} = Boards.update_card(card, %{"paths" => paths})
    card
  end

  # An epic in `column` with wide paths, and its sub-board's To Do, In
  # Progress and Done lists.
  defp epic(column, title \\ "Epic") do
    epic = card(column, title, "lib/**\ndocs/**")
    {:ok, t} = Boards.find_template(nil, "Simple")
    {:ok, sub} = sub_board(epic, t)
    sub = Boards.get_board!(sub.id)
    todo = hd(sub.columns)

    doing =
      sub.columns
      |> Enum.find(&(&1.name == "Doing"))
      |> Ecto.Changeset.change(category: "doing")
      |> Repo.update!()

    done = Enum.find(sub.columns, &(&1.category == "done"))
    {epic, %{todo: todo, doing: doing, done: done}}
  end

  defp queue(card), do: Runners.queue(card, %{pool: "dev", kind: "claude", prompt: "go"})

  defp held(ctx, card), do: Lanes.held_cards(ctx.board.id)[card.id]

  defp move(card, column, ctx), do: Boards.move_card(card.id, column.id, nil, actor: ctx.agent)

  describe "an epic waiting" do
    test "isn't held while one subcard its pass could take is free", ctx do
      _running = card(ctx.doing, "Running", "lib/a.ex")
      {epic, sub} = epic(ctx.todo)
      _taken = card(sub.todo, "Overlaps", "lib/a.ex")
      _free = card(sub.todo, "Free", "docs/b.md")
      {:ok, job} = queue(epic)

      assert held(ctx, epic) == nil
      assert Runners.held_reason(Repo.reload!(job), claimant: true) == nil
      assert %{id: id} = Runners.claim(ctx.runner)
      assert id == job.id
      assert :ok = move(epic, ctx.doing, ctx)
    end

    test "is held when every subcard it could take overlaps a card in progress", ctx do
      running = card(ctx.doing, "Running", "lib/**")
      {epic, sub} = epic(ctx.todo)
      card(sub.todo, "One", "lib/a.ex")
      card(sub.todo, "Two", "lib/b.ex")
      {:ok, job} = queue(epic)

      assert %Card{id: id} = held(ctx, epic)
      assert id == running.id

      assert Runners.held_reason(Repo.reload!(job), claimant: true) ==
               "Lane: overlaps ##{running.id}, in progress"

      assert Runners.claim(ctx.runner) == nil
      assert {:error, :unprocessable_entity, message} = move(epic, ctx.doing, ctx)
      assert message =~ "##{running.id}"
    end

    test "a subcard in progress already, or one with no paths, frees it", ctx do
      card(ctx.doing, "Running", "lib/**")
      {epic, sub} = epic(ctx.todo)
      card(sub.todo, "Overlaps", "lib/a.ex")
      started = card(sub.doing, "Started", "lib/c.ex")
      assert held(ctx, epic) == nil

      Repo.update_all(from(c in Card, where: c.id == ^started.id), set: [completed: true])
      {:ok, _} = queue(epic)
      assert %Card{} = held(ctx, epic)

      card(sub.todo, "No paths", [])
      assert held(ctx, epic) == nil
    end

    test "submitted, blocked and flagged subcards aren't ones it could take", ctx do
      card(ctx.doing, "Running", "lib/a.ex")
      {epic, sub} = epic(ctx.todo)
      card(sub.todo, "Overlaps", "lib/a.ex")
      {:ok, _} = queue(epic)

      pending = card(sub.todo, "Pending", "docs/p.md")
      Repo.update_all(from(c in Card, where: c.id == ^pending.id), set: [verify_state: "pending"])
      merging = card(sub.todo, "Merging", "docs/m.md")
      Repo.update_all(from(c in Card, where: c.id == ^merging.id), set: [verify_state: "merging"])
      card(sub.todo, "Waiting", "docs/w.md", %{"flags" => ["waiting"]})
      card(sub.todo, "Flagged", "docs/f.md", %{"flags" => ["blocked"]})
      blocked = card(sub.todo, "Blocked", "docs/x.md")
      blocker = card(ctx.todo, "Blocker", [])
      {:ok, _} = Boards.add_dependency(blocked, blocker)

      assert %Card{} = held(ctx, epic)
    end

    test "with no subcard left to take, its own paths count, as before", ctx do
      running = card(ctx.doing, "Running", "docs/manual.md")
      {epic, sub} = epic(ctx.todo)
      card(sub.done, "Finished", "lib/a.ex", %{"completed" => true})
      {:ok, _} = queue(epic)

      assert %Card{id: id} = held(ctx, epic)
      assert id == running.id
    end
  end

  describe "an epic in progress" do
    test "holds no lane of its own; its subcards in progress hold theirs", ctx do
      {epic, sub} = epic(ctx.doing)
      child = card(sub.doing, "Child", "lib/a.ex")
      card(sub.todo, "Later", "docs/later.md")

      elsewhere = card(ctx.todo, "Elsewhere", "lib/x.ex")
      assert :ok = move(elsewhere, ctx.doing, ctx)

      same = card(ctx.todo, "Same file", "lib/a.ex")
      assert {:error, :unprocessable_entity, message} = move(same, ctx.doing, ctx)
      assert message =~ "##{child.id}"
      refute message =~ "##{epic.id}"
    end

    test "a card with an empty sub-board isn't an epic: it holds its own lane", ctx do
      wide = card(ctx.doing, "Wide", "lib/**")
      {:ok, t} = Boards.find_template(nil, "Simple")
      {:ok, _sub} = sub_board(wide, t)

      other = card(ctx.todo, "Other", "lib/x.ex")
      assert {:error, :unprocessable_entity, message} = move(other, ctx.doing, ctx)
      assert message =~ "##{wide.id}"
    end
  end
end
