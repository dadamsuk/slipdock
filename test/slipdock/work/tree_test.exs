defmodule Slipdock.Work.TreeTest do
  @moduledoc """
  What in a board's tree waits on one person (#2095, `Slipdock.Work.Tree`):
  `Work.waiting/2`'s items, put under the epic they sit beneath, with the
  waits on other people beside them for the glance line only.
  """
  use Slipdock.DataCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.{Actor, Boards, Repo, Runners, Work}
  alias Slipdock.Boards.Card
  alias Slipdock.Runners.Job
  alias Slipdock.Work.Tree

  setup do
    owner = user_fixture("tree-owner@example.com")
    dana = user_fixture("tree-dana@example.com")
    board = board_fixture(%{"name" => "Tree"}, owner: owner)
    [_backlog, todo, _doing, _done] = board.columns
    {:ok, _} = Slipdock.Access.grant(board, dana, "write", owner)

    epic = card_fixture(todo, %{"title" => "Epic"})
    {:ok, t} = Boards.find_template(nil, "Simple")
    {:ok, sub} = sub_board(epic, t)
    sub = Boards.get_board!(sub.id)

    %{owner: owner, dana: dana, board: board, todo: todo, epic: epic, sub: sub}
  end

  defp agent(user), do: %{Actor.unknown() | kind: "agent", via: "mcp", user_id: user.id}

  defp sub_card(ctx, title), do: card_fixture(hd(ctx.sub.columns), %{"title" => title})

  defp wait_on(card, by, on) do
    {:ok, wait} =
      Boards.open_wait(card, agent(by), %{"needs" => "Which region?", "on_user_id" => on.id})

    wait
  end

  defp circling(card, n) do
    from(c in Card, where: c.id == ^card.id)
    |> Repo.update_all(
      set: [
        verify_rejections: n,
        verify_state: "rejected",
        flags: ["review"],
        verify_at: DateTime.utc_now(:second)
      ]
    )
  end

  defp failed_job(card) do
    {:ok, job} = Runners.queue(card, %{pool: "dev", kind: "claude", prompt: "go"})

    from(j in Job, where: j.id == ^job.id)
    |> Repo.update_all(set: [status: "failed", finished_at: DateTime.utc_now(:second)])
  end

  test "a wait on me in an epic's tree is under the epic, with a question for its reason",
       ctx do
    card = sub_card(ctx, "Region")
    wait_on(card, ctx.owner, ctx.owner)

    tree = Tree.for_board(ctx.owner, ctx.board)
    assert tree.count == 1
    assert %{mine: [item], others: []} = Tree.of(tree, ctx.epic.id)
    assert item.card.id == card.id
    assert item.reason == "wait"
    assert Tree.short(item) == "a question"
    assert Tree.glance(Tree.of(tree, ctx.epic.id)) == "Waiting on you: ##{card.id} (a question)"
    # The same item My work gives: one source.
    assert [%{cause: cause}] = Work.waiting_on_me(ctx.owner, board_id: ctx.board.id)
    assert item.cause == cause
  end

  test "a card past the rejection limit reads its rejections", ctx do
    card = sub_card(ctx, "Circling")
    circling(card, 3)

    tree = Tree.for_board(ctx.owner, ctx.board)
    assert %{mine: [item]} = Tree.of(tree, ctx.epic.id)
    assert item.reason == "circling"
    assert Tree.short(item) == "3 rejections"
  end

  test "a failed job is on the tree's owner", ctx do
    card = sub_card(ctx, "Failing")
    failed_job(card)

    tree = Tree.for_board(ctx.owner, ctx.board)
    assert %{mine: [item]} = Tree.of(tree, ctx.epic.id)
    assert item.reason == "failed"
    assert Tree.short(item) == "a failed job"
  end

  test "a wait on someone else is in others, never in the count", ctx do
    mine = sub_card(ctx, "Mine")
    theirs = sub_card(ctx, "Theirs")
    wait_on(mine, ctx.owner, ctx.owner)
    wait_on(theirs, ctx.owner, ctx.dana)

    tree = Tree.for_board(ctx.owner, ctx.board)
    entry = Tree.of(tree, ctx.epic.id)
    assert tree.count == 1
    assert length(entry.mine) == 1
    assert [%{card_id: id}] = entry.others
    assert id == theirs.id

    assert Tree.glance(entry) ==
             "Waiting on you: ##{mine.id} (a question) and 1 on someone else"

    # Dana sees hers as hers, and mine as someone else's.
    dana_entry = Tree.of(Tree.for_board(ctx.dana, ctx.board), ctx.epic.id)
    assert [%{card: %{id: ^id}}] = dana_entry.mine
    assert length(dana_entry.others) == 1
  end

  test "only someone else's wait: a line, but nothing on me", ctx do
    wait_on(sub_card(ctx, "Theirs"), ctx.owner, ctx.dana)

    entry = Tree.of(Tree.for_board(ctx.owner, ctx.board), ctx.epic.id)
    assert entry.mine == []
    assert Tree.glance(entry) == "Waiting on someone else: 1"
  end

  test "nothing waiting: zero, no entry and no line", ctx do
    sub_card(ctx, "Quiet")

    tree = Tree.for_board(ctx.owner, ctx.board)
    assert tree.count == 0
    assert Tree.of(tree, ctx.epic.id) == %{mine: [], others: []}
    assert Tree.glance(Tree.of(tree, ctx.epic.id)) == nil
    assert Tree.for_card(ctx.owner, ctx.epic).count == 0
  end

  test "a wait on the epic itself counts on the board, not on its own tile", ctx do
    wait_on(ctx.epic, ctx.owner, ctx.owner)

    tree = Tree.for_board(ctx.owner, ctx.board)
    assert tree.count == 1
    assert Tree.of(tree, ctx.epic.id) == %{mine: [], others: []}
    # The filter keeps the epic: the item is on it.
    assert MapSet.member?(Tree.card_ids(tree, ctx.board), ctx.epic.id)
  end

  test "deeper levels count under the top epic; for_card reads the epic's tree", ctx do
    mid = sub_card(ctx, "Middle")
    {:ok, t} = Boards.find_template(nil, "Simple")
    {:ok, deep} = sub_board(mid, t)
    deep = Boards.get_board!(deep.id)
    leaf = card_fixture(hd(deep.columns), %{"title" => "Leaf"})
    wait_on(leaf, ctx.owner, ctx.owner)

    tree = Tree.for_board(ctx.owner, ctx.board)
    assert %{mine: [%{card: %{id: id}}]} = Tree.of(tree, ctx.epic.id)
    assert id == leaf.id
    assert Tree.card_ids(tree, ctx.board) == MapSet.new([ctx.epic.id])

    # On the sub-board the item sits under the middle card.
    sub_tree = Tree.for_board(ctx.owner, ctx.sub)
    assert %{mine: [_]} = Tree.of(sub_tree, mid.id)
    assert Tree.for_card(ctx.owner, ctx.epic).count == 1
    assert Tree.for_card(ctx.owner, leaf).count == 0
  end

  test "the short reasons" do
    assert Tree.short(%{reason: "wait_anyone"}) == "a question for anyone"
    assert Tree.short(%{reason: "verify"}) == "to verify"
    assert Tree.short(%{reason: "review"}) == "flagged review"
    assert Tree.short(%{reason: "waiting"}) == "flagged waiting"
    assert Tree.short(%{reason: "gave_up"}) == "the runner gave up"
    assert Tree.short(%{reason: "failed", job: %{status: "timeout"}}) == "a job timed out"
    assert Tree.short(%{reason: "needs_owner"}) == "nobody on it"
    assert Tree.short(%{reason: "overseer"}) == "the overseer"

    assert Tree.short(%{
             reason: "wait",
             wait: %Slipdock.Boards.Wait{purpose: "verify_limit"},
             card: %Card{verify_rejections: 1}
           }) == "1 rejection"

    assert Tree.short(%{reason: "circling", card: %Card{verify_rejections: nil}}) ==
             "past the rejection limit"
  end

  test "nobody signed in gets an empty tree", ctx do
    assert Tree.for_board(nil, ctx.board) == %Tree{}
    assert Tree.for_card(nil, ctx.epic) == %Tree{}
  end
end
