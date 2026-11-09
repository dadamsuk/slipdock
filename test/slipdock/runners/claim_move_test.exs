defmodule Slipdock.Runners.ClaimMoveTest do
  @moduledoc """
  A claimed card moves to its board's doing list on claim (#2633): claiming
  a `list_top` rule's job moves the card there, assigns nobody and says so
  in the activity; an agent's own move afterwards changes nothing; the
  prompt names the list. A board with no doing list, a card the board won't
  let in, and a job no list_top rule queued leave the card where it is.
  """
  use Slipdock.DataCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.{Actor, Automations, Boards, Repo, Runners}
  alias Slipdock.Boards.{Activity, Card, CardMove}
  alias Slipdock.Runners.{ClaimMove, Job}

  setup do
    owner = user_fixture()
    board = board_fixture(%{"name" => "Claims"}, owner: owner)
    [_backlog, todo, doing, _done] = board.columns
    {:ok, runner, _} = Runners.create_runner(board, %{"name" => "Mac Studio", "pool" => "dev"})
    %{owner: owner, board: board, todo: todo, doing: doing, runner: runner}
  end

  defp list_top(board) do
    rule_fixture(board, %{
      "trigger" => %{"type" => "list_top", "column" => "To Do"},
      "actions" => [%{"type" => "runner", "pool" => "dev"}]
    })
  end

  # The rule sends the top card, and the runner claims its job.
  defp send_and_claim(ctx) do
    rule = list_top(ctx.board)
    Automations.feed(rule)
    assert %Job{} = job = Runners.claim(ctx.runner)
    job
  end

  defp activity(card),
    do: Repo.all(from(a in Activity, where: a.card_id == ^card.id, select: a.message))

  defp assignees(card), do: Repo.preload(Repo.reload!(card), :assignees, force: true).assignees

  test "claiming a list_top rule's job moves the card to the doing list and logs it", ctx do
    card = card_fixture(ctx.todo, %{"title" => "Next"})
    # Already in progress: the claimed card goes on top of it.
    other = card_fixture(ctx.doing, %{"title" => "Older"})

    job = send_and_claim(ctx)

    assert job.card_id == card.id
    assert Repo.reload!(card).column_id == ctx.doing.id
    assert Repo.reload!(card).position < Repo.reload!(other).position
    assert assignees(card) == []

    assert "Mac Studio took job ##{job.id} and moved the card to #{ctx.doing.name}" in activity(
             card
           )

    # The ledger records the move as the runner's agent, on its job.
    assert %CardMove{actor_kind: "agent", job_id: job_id} =
             Repo.one(from(m in CardMove, where: m.card_id == ^card.id and m.kind == "moved"))

    assert job_id == job.id
  end

  test "the agent's own move afterwards changes nothing", ctx do
    card = card_fixture(ctx.todo, %{"title" => "Next"})
    job = send_and_claim(ctx)
    moves = Repo.aggregate(from(m in CardMove, where: m.card_id == ^card.id), :count)

    actor = Actor.runner(ctx.owner.id, job.id, "Mac Studio")
    assert :ok = Boards.move_card(card.id, ctx.doing.id, nil, actor: actor)

    assert Repo.reload!(card).column_id == ctx.doing.id
    assert Repo.aggregate(from(m in CardMove, where: m.card_id == ^card.id), :count) == moves
  end

  test "the prompt names the list the card is in", ctx do
    card_fixture(ctx.todo, %{"title" => "Next"})
    job = send_and_claim(ctx)

    assert Runners.claimed_prompt(job) =~
             "The card is in #{ctx.doing.name}, its board's doing list, so there is no need " <>
               "to move it there. If you move it by hand, the list is called \"#{ctx.doing.name}\"."
  end

  test "a doing list known only by its name (no category) is found as the guide finds it",
       ctx do
    Repo.update!(Ecto.Changeset.change(ctx.doing, category: nil, name: "Doing"))
    card = card_fixture(ctx.todo, %{"title" => "Next"})

    send_and_claim(ctx)

    assert Repo.reload!(card).column_id == ctx.doing.id
  end

  test "a board with no doing list: the card stays, and the activity and prompt say why", ctx do
    Repo.update!(Ecto.Changeset.change(ctx.doing, category: nil, name: "Parked"))
    card = card_fixture(ctx.todo, %{"title" => "Next"})

    job = send_and_claim(ctx)

    assert Repo.reload!(card).column_id == ctx.todo.id
    assert ClaimMove.doing_list(ctx.board.id) == nil

    assert "Mac Studio took job ##{job.id}; its board has no doing list, so the card stays put" in activity(
             card
           )

    assert Runners.claimed_prompt(job) =~
             "The card is in #{ctx.todo.name}. Its board has no doing list, so leave it where it is."
  end

  test "a move the board refuses (no bar where one is asked for) leaves the card, saying why",
       ctx do
    {:ok, _} = Boards.update_board(ctx.board, %{"bar_required" => true})
    card = card_fixture(ctx.todo, %{"title" => "Next"})

    job = send_and_claim(ctx)

    assert Repo.reload!(card).column_id == ctx.todo.id
    assert [line] = Enum.filter(activity(card), &String.starts_with?(&1, "Mac Studio took job"))
    assert line =~ "the card stays put, since moving it to the doing list was refused"
    assert line =~ "bar"

    assert Runners.claimed_prompt(job) =~
             "The card is in #{ctx.todo.name}. Its board's doing list is called " <>
               "\"#{ctx.doing.name}\": use that name if you move it there by hand."
  end

  test "a job no list_top rule queued leaves the card where it is", ctx do
    card = card_fixture(ctx.todo, %{"title" => "By hand"})
    {:ok, _} = Runners.queue(card, %{pool: "dev", kind: "claude", prompt: "go"})

    assert %Job{} = job = Runners.claim(ctx.runner)

    assert Repo.reload!(card).column_id == ctx.todo.id
    assert "Mac Studio took job ##{job.id}" in activity(card)
  end

  test "an event rule's job leaves the card where it is", ctx do
    rule =
      rule_fixture(ctx.board, %{
        "trigger" => %{"type" => "flag_added", "flag" => "starred"},
        "actions" => [%{"type" => "runner", "pool" => "dev"}]
      })

    card = card_fixture(ctx.todo, %{"title" => "Starred"})

    assert ClaimMove.move(%Job{rule_id: rule.id, card_id: card.id, kind: "claude"}, ctx.runner) ==
             :skip

    assert Repo.reload!(card).column_id == ctx.todo.id
  end

  test "a card already in the doing list stays where it is in it", ctx do
    card = card_fixture(ctx.doing, %{"title" => "Resent"})
    job = %Job{rule_id: list_top(ctx.board).id, card_id: card.id, kind: "claude"}

    assert ClaimMove.move(job, ctx.runner) == {:already, Repo.reload!(ctx.doing)}
    assert ClaimMove.activity_suffix({:already, ctx.doing}) == ""
  end

  test "a verify job, a completed card and an archived one are never moved", ctx do
    rule = list_top(ctx.board)
    card = card_fixture(ctx.todo, %{"title" => "Check it"})

    assert ClaimMove.move(%Job{rule_id: rule.id, card_id: card.id, kind: "verify"}, ctx.runner) ==
             :skip

    done = card_fixture(ctx.todo, %{"title" => "Done", "completed" => true})

    assert ClaimMove.move(%Job{rule_id: rule.id, card_id: done.id, kind: "claude"}, ctx.runner) ==
             :skip

    gone = card_fixture(ctx.todo, %{"title" => "Gone"})
    Repo.update!(Ecto.Changeset.change(gone, archived_at: DateTime.utc_now(:second)))

    assert ClaimMove.move(%Job{rule_id: rule.id, card_id: gone.id, kind: "claude"}, ctx.runner) ==
             :skip

    for c <- [card, done, gone], do: assert(Repo.get!(Card, c.id).column_id == ctx.todo.id)
  end
end
