defmodule Slipdock.Runners.AnswerOneJobTest do
  @moduledoc """
  One job per card, whichever rule sends it (#2613). A board with two
  `list_top` rules on one list, one per pool: answering or skipping the
  wait a parked job asked sends the card as one job, with the answer, and
  never a second with its plain prompt from the other pool's rule; and a
  card some rule already has an open job for gets no second one from any
  rule's runner action.
  """
  use Slipdock.DataCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.{Actor, Automations, Boards, Repo, Runners}
  alias Slipdock.Boards.{Card, Wait}
  alias Slipdock.Runners.{Job, Requeue}

  setup do
    owner = user_fixture()
    dana = user_fixture("dana-2613@example.com")
    board = board_fixture(%{"name" => "Two pools"}, owner: owner)
    {:ok, _} = Slipdock.Access.grant(board, dana, "write", owner)
    [backlog, todo, doing, _done] = board.columns
    {:ok, loop, _} = Runners.create_runner(board, %{"name" => "box", "pool" => "loop"})
    {:ok, white, _} = Runners.create_runner(board, %{"name" => "white", "pool" => "white"})
    a = card_fixture(todo, %{"title" => "a"})

    %{owner: owner, dana: dana, board: board, todo: todo, doing: doing, a: a, loop: loop}
    |> Map.merge(%{white: white, backlog: backlog})
  end

  defp feed(board, pool, extra \\ %{}) do
    rule_fixture(board, %{
      "trigger" => %{"type" => "list_top", "column" => "To Do"},
      "actions" => [Map.merge(%{"type" => "runner", "pool" => pool}, extra)]
    })
  end

  defp card_jobs(card),
    do: Repo.all(from(j in Job, where: j.card_id == ^card.id, order_by: [asc: j.id]))

  defp open_card_jobs(card), do: card |> card_jobs() |> Enum.filter(&Job.open?/1)

  # The loop runner takes the card, asks and parks: the card goes back on
  # top of To Do, unassigned and flagged waiting.
  defp park(ctx) do
    job = Runners.claim(ctx.loop)
    assert job.card_id == ctx.a.id
    :ok = Boards.move_card_to_index(Repo.get!(Card, job.card_id), ctx.doing, :top)

    {:ok, _} =
      Boards.open_wait(Repo.get!(Card, job.card_id), Actor.runner(ctx.owner, job.id), %{
        "needs" => "Which region?",
        "choices" => ["eu", "us"],
        "job_id" => job.id
      })

    {:ok, %Job{status: "parked"} = job} =
      Runners.finish(ctx.loop, job.id, %{exit: "0", output: "Asked which region"})

    # Past the feeds' cool-down: only the hold keeps them off the card.
    Repo.update_all(from(j in Job, where: j.id == ^job.id),
      set: [finished_at: DateTime.add(DateTime.utc_now(:second), -7200)]
    )

    assert open_card_jobs(ctx.a) == []
    job
  end

  defp setup_two_feeds(ctx, white_extra \\ %{}) do
    loop_rule = feed(ctx.board, "loop")
    white_rule = feed(ctx.board, "white", white_extra)
    # The only card goes to the first rule; the other has nothing to send.
    assert [%Job{rule_id: id}] = open_card_jobs(ctx.a)
    assert id == loop_rule.id
    {loop_rule, white_rule}
  end

  describe "answering a parked wait, two list_top rules on one list" do
    test "sends the card as one job, the asking rule's, with the answer", ctx do
      {loop_rule, white_rule} = setup_two_feeds(ctx)
      parked = park(ctx)

      {:ok, wait} =
        Boards.answer_wait(Boards.get_card!(ctx.a.id), Actor.web(ctx.dana), %{"choice" => 1})

      assert [fresh] = open_card_jobs(ctx.a)
      assert fresh.id != parked.id
      assert fresh.rule_id == loop_rule.id
      assert fresh.pool == "loop"
      assert fresh.prompt =~ "Question on card ##{ctx.a.id}: Which region?"
      assert wait.requeue_state == "queued"
      assert wait.requeue_job_id == fresh.id

      # The other pool's rule never sent the card, and its feed still won't.
      refute Enum.any?(card_jobs(ctx.a), &(&1.rule_id == white_rule.id))
      assert {:idle, _} = Automations.feed(white_rule)
      assert Automations.next_card(white_rule, force: true) == nil
      assert [_] = open_card_jobs(ctx.a)
    end

    test "skipping it sends one job too", ctx do
      {loop_rule, _white_rule} = setup_two_feeds(ctx)
      park(ctx)
      wait = Repo.one!(from(w in Wait, where: w.card_id == ^ctx.a.id))

      {:ok, wait} = Boards.answer_wait(wait, Actor.web(ctx.dana), %{"skip" => true})

      assert [fresh] = open_card_jobs(ctx.a)
      assert fresh.rule_id == loop_rule.id
      assert fresh.prompt =~ "skipped"
      assert wait.requeue_state == "queued"
    end

    test "another rule's still-queued job on the card carries the answer, no second", ctx do
      {loop_rule, white_rule} = setup_two_feeds(ctx)
      park(ctx)
      # Sent by the other pool's rule meanwhile (another process won a race).
      {:ok, plain} =
        Runners.queue(Repo.get!(Card, ctx.a.id), %{
          rule: white_rule,
          pool: "white",
          prompt: "plain prompt"
        })

      {:ok, wait} =
        Boards.answer_wait(Boards.get_card!(ctx.a.id), Actor.web(ctx.dana), %{"choice" => 2})

      assert [same] = open_card_jobs(ctx.a)
      assert same.id == plain.id
      assert same.pool == "white"
      assert same.prompt =~ "Question on card ##{ctx.a.id}: Which region?"
      assert wait.requeue_state == "queued"
      assert wait.requeue_job_id == plain.id
      refute Enum.any?(open_card_jobs(ctx.a), &(&1.rule_id == loop_rule.id))
    end

    test "another rule's still-queued job keeps its own rule's prompt, with the answer", ctx do
      {loop_rule, white_rule} = setup_two_feeds(ctx, %{"prompt" => "white pool prompt"})
      park(ctx)

      {:ok, plain} =
        Runners.queue(Repo.get!(Card, ctx.a.id), %{
          rule: white_rule,
          pool: "white",
          prompt: "plain prompt"
        })

      {:ok, _wait} =
        Boards.answer_wait(Boards.get_card!(ctx.a.id), Actor.web(ctx.dana), %{"choice" => 1})

      assert [same] = open_card_jobs(ctx.a)
      assert same.id == plain.id
      assert same.prompt =~ "white pool prompt"
      assert same.prompt =~ "Question on card ##{ctx.a.id}: Which region?"

      # Not the asking rule's prompt (the default one).
      {:ok, asking} = Automations.Runner.runner_job(loop_rule, ctx.a)
      refute asking.prompt =~ "white pool prompt"
      refute String.starts_with?(same.prompt, String.slice(asking.prompt, 0, 40))
    end

    test "an open job no rule queued (a verify job) neither holds nor takes the answer", ctx do
      {loop_rule, _white_rule} = setup_two_feeds(ctx)
      park(ctx)

      {:ok, verify} =
        Runners.queue(Repo.get!(Card, ctx.a.id), %{pool: "v", kind: "verify", prompt: "check it"})

      {:ok, wait} =
        Boards.answer_wait(Boards.get_card!(ctx.a.id), Actor.web(ctx.dana), %{"choice" => 1})

      assert Repo.reload!(verify).prompt == "check it"
      assert Repo.reload!(verify).status == "queued"
      assert [fresh] = Enum.filter(open_card_jobs(ctx.a), &(&1.rule_id == loop_rule.id))
      assert fresh.prompt =~ "Question on card ##{ctx.a.id}: Which region?"
      assert wait.requeue_state == "queued"
      assert wait.requeue_job_id == fresh.id
    end

    test "another rule's job already running on the card holds the answer till it ends", ctx do
      {loop_rule, white_rule} = setup_two_feeds(ctx)
      park(ctx)

      {:ok, plain} =
        Runners.queue(Repo.get!(Card, ctx.a.id), %{
          rule: white_rule,
          pool: "white",
          prompt: "plain prompt"
        })

      assert %Job{id: id} = Runners.claim(ctx.white)
      assert id == plain.id

      {:ok, wait} =
        Boards.answer_wait(Boards.get_card!(ctx.a.id), Actor.web(ctx.dana), %{"choice" => 1})

      assert wait.requeue_state == "pending"
      assert [%Job{id: ^id}] = open_card_jobs(ctx.a)
      refute Enum.any?(card_jobs(ctx.a), &(&1.rule_id == loop_rule.id and Job.open?(&1)))
    end
  end

  describe "answering a parked wait on a sub-board, two list_top rules on one list" do
    # The card sits on an epic's sub-board, whose own To Do list two feed
    # rules work, one per pool: the hold covers the whole tree, not just the
    # root board (#2645).
    setup ctx do
      epic = card_fixture(ctx.backlog, %{"title" => "Epic"})
      {:ok, t} = Boards.find_template(nil, "Simple")
      {:ok, sub} = sub_board(epic, t)
      sub = Boards.get_board!(sub.id)
      [sub_todo | _] = sub.columns
      sub_doing = Enum.find(sub.columns, &(&1.name == "Doing"))
      s = card_fixture(sub_todo, %{"title" => "s"})
      %{sub: sub, sub_todo: sub_todo, sub_doing: sub_doing, s: s}
    end

    test "sends the card as one job, the asking rule's, with the answer", ctx do
      list = %{"type" => "list_top", "column" => ctx.sub_todo.name}

      loop_rule =
        rule_fixture(ctx.sub, %{
          "trigger" => list,
          "actions" => [%{"type" => "runner", "pool" => "loop"}]
        })

      white_rule =
        rule_fixture(ctx.sub, %{
          "trigger" => list,
          "actions" => [%{"type" => "runner", "pool" => "white"}]
        })

      assert [%Job{rule_id: id}] = open_card_jobs(ctx.s)
      assert id == loop_rule.id

      # The loop runner takes the card, asks and parks.
      job = Runners.claim(ctx.loop)
      assert job.card_id == ctx.s.id
      :ok = Boards.move_card_to_index(Repo.get!(Card, ctx.s.id), ctx.sub_doing, :top)

      {:ok, _} =
        Boards.open_wait(Repo.get!(Card, ctx.s.id), Actor.runner(ctx.owner, job.id), %{
          "needs" => "Which region?",
          "choices" => ["eu", "us"],
          "job_id" => job.id
        })

      {:ok, %Job{status: "parked"} = parked} =
        Runners.finish(ctx.loop, job.id, %{exit: "0", output: "Asked which region"})

      Repo.update_all(from(j in Job, where: j.id == ^parked.id),
        set: [finished_at: DateTime.add(DateTime.utc_now(:second), -7200)]
      )

      assert open_card_jobs(ctx.s) == []
      assert Repo.get!(Card, ctx.s.id).column_id == ctx.sub_todo.id

      {:ok, wait} =
        Boards.answer_wait(Boards.get_card!(ctx.s.id), Actor.web(ctx.dana), %{"choice" => 1})

      assert [fresh] = open_card_jobs(ctx.s)
      assert fresh.id != parked.id
      assert fresh.rule_id == loop_rule.id
      assert fresh.pool == "loop"
      assert fresh.board_id == ctx.sub.id
      assert fresh.prompt =~ "Question on card ##{ctx.s.id}: Which region?"
      assert wait.requeue_state == "queued"
      assert wait.requeue_job_id == fresh.id

      # The other pool's rule on the sub-board never sent the card.
      refute Enum.any?(card_jobs(ctx.s), &(&1.rule_id == white_rule.id))
      assert Automations.next_card(white_rule, force: true) == nil
    end
  end

  describe "the hold itself, while a parked wait is answered (#2663)" do
    # `Automations.feed/2` answers `{:idle, :busy}` for a rule held off in
    # this process, and anything else for one that isn't.
    defp busy?(rule), do: Automations.feed(rule, force: true) == {:idle, :busy}

    test "both feeds on the list are held for as long as the answer runs, and no longer", ctx do
      {loop_rule, white_rule} = setup_two_feeds(ctx)
      park(ctx)
      wait = Repo.one!(from(w in Wait, where: w.card_id == ^ctx.a.id))
      Repo.update_all(from(c in Card, where: c.id == ^ctx.a.id), set: [flags: []])

      # Unflagged and past the cool-down, the card is the next one either
      # feed would send: only the hold keeps them off it.
      assert Automations.next_card(loop_rule).id == ctx.a.id
      assert Automations.next_card(white_rule).id == ctx.a.id

      assert :ran =
               Requeue.quietly(wait, fn ->
                 assert busy?(loop_rule)
                 assert busy?(white_rule)
                 assert open_card_jobs(ctx.a) == []
                 :ran
               end)

      # Let go: the first feed to run sends the card.
      refute busy?(loop_rule)
      assert [%Job{rule_id: id}] = open_card_jobs(ctx.a)
      assert id == loop_rule.id
      refute busy?(white_rule)
    end

    test "the answer queues the job itself: no feed sent the card first", ctx do
      {loop_rule, _white_rule} = setup_two_feeds(ctx)
      park(ctx)

      {:ok, wait} =
        Boards.answer_wait(Boards.get_card!(ctx.a.id), Actor.web(ctx.dana), %{"choice" => 1})

      # A feed let through would have queued the card with its plain prompt,
      # and the answer would say it rewrote that job ("still queued").
      assert [fresh] = open_card_jobs(ctx.a)
      assert fresh.rule_id == loop_rule.id
      assert wait.requeue_state == "queued"
      assert wait.requeue_note == "job ##{fresh.id}"
    end

    test "a wait no job asked, or whose job's rule is gone, holds nothing", ctx do
      {loop_rule, white_rule} = setup_two_feeds(ctx)
      parked = park(ctx)
      wait = Repo.one!(from(w in Wait, where: w.card_id == ^ctx.a.id))

      assert :ran =
               Requeue.quietly(%{wait | job_id: nil}, fn ->
                 refute Process.get({:feeding, loop_rule.id})
                 refute Process.get({:feeding, white_rule.id})
                 :ran
               end)

      Repo.update_all(from(j in Job, where: j.id == ^parked.id), set: [rule_id: nil])

      assert :ran =
               Requeue.quietly(wait, fn ->
                 refute Process.get({:feeding, loop_rule.id})
                 refute Process.get({:feeding, white_rule.id})
                 :ran
               end)
    end

    test "a wait on a subcard, asked from the epic's job: the root board's feeds are held",
         ctx do
      # The asking rule and the other pool's are both on the root board,
      # where the epic is; the question is on a card on the epic's
      # sub-board, which has a feed of its own. The hold is found from the
      # root of the waiting card's tree, not from the board it is on.
      {loop_rule, white_rule} = setup_two_feeds(ctx)
      {:ok, t} = Boards.find_template(nil, "Simple")
      {:ok, sub} = sub_board(ctx.a, t)
      sub = Boards.get_board!(sub.id)
      [sub_todo | _] = sub.columns
      s = card_fixture(sub_todo, %{"title" => "s"})

      sub_rule =
        rule_fixture(sub, %{
          "trigger" => %{"type" => "list_top", "column" => sub_todo.name},
          "actions" => [%{"type" => "runner", "pool" => "white"}]
        })

      # A feed on another tree altogether is nobody's to hold.
      elsewhere = board_fixture(%{"name" => "Elsewhere"}, owner: ctx.owner)
      other_rule = feed(elsewhere, "white")

      job = Runners.claim(ctx.loop)
      assert {job.card_id, job.rule_id} == {ctx.a.id, loop_rule.id}

      {:ok, wait} =
        Boards.open_wait(Repo.get!(Card, s.id), Actor.runner(ctx.owner, job.id), %{
          "needs" => "Which region?",
          "job_id" => job.id
        })

      assert Repo.get!(Card, wait.card_id).board_id == sub.id
      assert white_rule.board_id == ctx.board.id

      assert :ran =
               Requeue.quietly(wait, fn ->
                 assert busy?(loop_rule)
                 assert busy?(white_rule)
                 assert busy?(sub_rule)
                 refute busy?(other_rule)
                 :ran
               end)

      refute busy?(loop_rule)
      refute busy?(white_rule)
      refute busy?(sub_rule)
    end
  end

  describe "a card whose job is still running" do
    test "no rule's runner action sends it a second job", ctx do
      {_loop_rule, white_rule} = setup_two_feeds(ctx)

      # A third rule sends a card to the white pool when it enters Doing.
      moved =
        rule_fixture(ctx.board, %{
          "trigger" => %{"type" => "card_entered", "column" => ctx.doing.name},
          "actions" => [%{"type" => "runner", "pool" => "white"}]
        })

      job = Runners.claim(ctx.loop)
      Runners.heartbeat(ctx.loop, job.id)
      assert Repo.reload!(job).status in ~w(claimed running)
      :ok = Boards.move_card_to_index(Repo.get!(Card, ctx.a.id), ctx.doing, :top)

      # The move fired the third rule, and both feeds have had their turn.
      assert {:idle, _} = Automations.feed(white_rule)
      assert [%Job{id: only}] = open_card_jobs(ctx.a)
      assert only == job.id
      refute Enum.any?(card_jobs(ctx.a), &(&1.rule_id == moved.id))

      # A card whose only open job no rule queued (a verify job): sent.
      c = card_fixture(ctx.backlog, %{"title" => "c"})
      {:ok, verify} = Runners.queue(c, %{pool: "v", kind: "verify", prompt: "check it"})
      :ok = Boards.move_card_to_index(Repo.get!(Card, c.id), ctx.doing, :top)
      assert Enum.any?(open_card_jobs(c), &(&1.rule_id == moved.id))
      assert Repo.reload!(verify).prompt == "check it"

      # A card with no open job (from the Backlog, which no feed works): the
      # same rule sends it.
      b = card_fixture(ctx.backlog, %{"title" => "b"})
      assert open_card_jobs(b) == []
      :ok = Boards.move_card_to_index(Repo.get!(Card, b.id), ctx.doing, :top)
      assert Enum.any?(open_card_jobs(b), &(&1.rule_id == moved.id))
    end
  end
end
