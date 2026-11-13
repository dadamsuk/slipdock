defmodule Slipdock.WorkWaitingHeldRuleTest do
  @moduledoc """
  An answer held for its card's job (`requeue_state` `pending`, #2896) keeps
  the card off Waiting on you: it is on its way to the runners. Only a
  drain for the asking job's rule sends it, so once that rule is switched
  off or deleted nothing ever does (#2962). The wait then stays pending,
  and the card is a person's again: in progress with nobody on it.
  """
  use Slipdock.DataCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.{Actor, Automations, Boards, Repo, Runners, Work}
  alias Slipdock.Boards.Wait
  alias Slipdock.Runners.Job

  setup do
    owner = user_fixture("owner@example.com")
    board = board_fixture(%{"name" => "Held"}, owner: owner)
    [_backlog, todo, doing, _done] = board.columns
    {:ok, runner, _} = Runners.create_runner(board, %{"name" => "box", "pool" => "loop"})
    card = card_fixture(todo, %{"title" => "a"})

    rule =
      rule_fixture(board, %{
        "trigger" => %{"type" => "list_top", "column" => "To Do"},
        "actions" => [%{"type" => "runner", "pool" => "loop"}]
      })

    %{owner: owner, doing: doing, runner: runner, card: card, rule: rule}
  end

  # The rule's job takes the card into Doing and asks; the answer comes
  # while the job is still running, so it is held behind it.
  defp held(ctx) do
    job = Runners.claim(ctx.runner)
    assert job.card_id == ctx.card.id
    :ok = Boards.Cards.move_card_to_index(Repo.get!(Boards.Card, job.card_id), ctx.doing, :top)

    {:ok, _} =
      Boards.Waits.open_wait(
        Boards.Cards.get_card!(ctx.card.id),
        Actor.runner(ctx.owner, job.id),
        %{
          "needs" => "Which region?",
          "job_id" => job.id
        }
      )

    {:ok, wait} =
      Boards.Waits.answer_wait(Boards.Cards.get_card!(ctx.card.id), Actor.web(ctx.owner), %{
        "answer" => "eu"
      })

    assert wait.requeue_state == "pending"
    {job, wait}
  end

  # The job ends, and the card has sat in Doing past the hour.
  defp job_ends(ctx, job) do
    {:ok, %Job{status: "done"}} = Runners.finish(ctx.runner, job.id, %{exit: "0", output: "ok"})

    from(m in Boards.CardMove, where: m.card_id == ^ctx.card.id)
    |> Repo.update_all(set: [inserted_at: DateTime.add(DateTime.utc_now(), -7200, :second)])
  end

  defp reasons(ctx), do: ctx.owner |> Work.waiting_on_me() |> Enum.map(&{&1.card.id, &1.reason})

  test "held while the rule is on: off Waiting on you", ctx do
    {_job, _wait} = held(ctx)

    from(m in Boards.CardMove, where: m.card_id == ^ctx.card.id)
    |> Repo.update_all(set: [inserted_at: DateTime.add(DateTime.utc_now(), -7200, :second)])

    # The job is open, and the answer will follow it.
    assert reasons(ctx) == []
    # Still held with the job gone but the rule on: the answer is on its way.
    Repo.update_all(from(j in Job, where: j.card_id == ^ctx.card.id), set: [status: "done"])
    assert reasons(ctx) == []
  end

  test "the rule switched off: the wait stays pending, and the card is on Waiting on you",
       ctx do
    {job, wait} = held(ctx)
    {:ok, _} = Automations.update_rule(ctx.rule, %{"enabled" => false})

    job_ends(ctx, job)

    # Nothing drains it: no job went out for the answer.
    assert Repo.get!(Wait, wait.id).requeue_state == "pending"
    assert Repo.all(from(j in Job, where: j.status in ^Job.open_statuses())) == []
    assert reasons(ctx) == [{ctx.card.id, "needs_owner"}]
  end

  test "the rule deleted: the wait stays pending, and the card is on Waiting on you", ctx do
    {job, wait} = held(ctx)
    {:ok, _} = Automations.delete_rule(ctx.rule)

    job_ends(ctx, job)

    assert Repo.get!(Wait, wait.id).requeue_state == "pending"
    assert Repo.all(from(j in Job, where: j.status in ^Job.open_statuses())) == []
    assert reasons(ctx) == [{ctx.card.id, "needs_owner"}]
  end

  test "the rule switched on again: held, and off Waiting on you once more", ctx do
    {job, _wait} = held(ctx)
    {:ok, rule} = Automations.update_rule(ctx.rule, %{"enabled" => false})
    job_ends(ctx, job)
    assert reasons(ctx) == [{ctx.card.id, "needs_owner"}]

    # Back on, its feed sends the answer; until then it is on its way.
    Repo.update_all(from(r in Automations.Rule, where: r.id == ^rule.id), set: [enabled: true])
    assert reasons(ctx) == []
  end
end
