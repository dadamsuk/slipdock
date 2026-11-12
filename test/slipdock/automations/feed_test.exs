defmodule Slipdock.Automations.FeedTest do
  # The `list_top` trigger: a rule that keeps a runner pool busy with a list,
  # one card at a time in the list's order (`Slipdock.Automations.feed/2`).
  use Slipdock.DataCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.{Automations, Boards, Repo, Runners}
  alias Slipdock.Automations.{Presets, Spec}
  alias Slipdock.Boards.Card
  alias Slipdock.Runners.{Job, Setup}

  setup do
    owner = user_fixture()
    board = board_fixture(%{"name" => "Loop"}, owner: owner)
    [_backlog, todo, doing, done] = board.columns
    {:ok, runner, _} = Runners.create_runner(board, %{"name" => "box", "pool" => "loop"})
    %{owner: owner, board: board, todo: todo, doing: doing, done: done, runner: runner}
  end

  defp feed_spec(trigger \\ %{}) do
    %{
      "trigger" => Map.merge(%{"type" => "list_top", "column" => "To Do"}, trigger),
      "actions" => [%{"type" => "runner", "pool" => "loop"}]
    }
  end

  defp feed_rule(board, trigger \\ %{}, attrs \\ %{}),
    do: rule_fixture(board, feed_spec(trigger), attrs)

  defp jobs(rule),
    do: Repo.all(from(j in Job, where: j.rule_id == ^rule.id, order_by: [asc: j.id]))

  defp open_jobs(rule), do: Enum.filter(jobs(rule), &Job.open?/1)

  defp queued_cards(rule), do: Enum.map(open_jobs(rule), & &1.card_id)

  # Ends `job` long enough ago that its card is out of the cool-down.
  defp age(job) do
    past = DateTime.utc_now() |> DateTime.add(-(Automations.feed_cooldown() + 5), :second)
    Repo.update_all(from(j in Job, where: j.id == ^job.id), set: [finished_at: past])
  end

  defp finish(runner, status) do
    job = Runners.claim(runner)
    # The claim moved the card to the doing list (#2633); the job leaves it
    # back on its list, as these cool-down cases need.
    card = Repo.get!(Card, job.card_id)
    todo = Repo.get_by!(Slipdock.Boards.Column, board_id: card.board_id, name: "To Do")
    :ok = Boards.Cards.move_card_to_index(card, todo, :top)
    {:ok, job} = Runners.finish(runner, job.id, %{status: status})
    job
  end

  describe "the spec" do
    test "needs a list and a runner action" do
      assert {:error, "trigger “list_top” needs column"} =
               Spec.validate(%{feed_spec() | "trigger" => %{"type" => "list_top"}})

      assert {:error, "trigger “list_top” needs a runner action" <> _} =
               Spec.validate(%{
                 feed_spec()
                 | "actions" => [%{"type" => "comment", "body" => "hi"}]
               })
    end

    test "takes unassigned as a boolean, from a form's strings too" do
      assert {:ok, %{"trigger" => %{"unassigned" => true}}} =
               Spec.validate(feed_spec(%{"unassigned" => "true"}))

      assert {:ok, %{"trigger" => %{"unassigned" => false}}} =
               Spec.validate(feed_spec(%{"unassigned" => false}))

      assert {:error, "trigger “list_top” unassigned must be true or false"} =
               Spec.validate(feed_spec(%{"unassigned" => "sometimes"}))
    end

    test "is neither an event nor the clock, reads back, and is in the vocabulary" do
      spec = feed_spec(%{"unassigned" => true})
      assert Spec.feed?(spec)
      refute Spec.scheduled?(spec)

      assert Spec.summary(spec) =~
               "When nothing it sent is still open, take the top unassigned card of To Do, " <>
                 "send it to the loop runners"

      assert %{feed: true, scheduled: false, required: ["column"]} =
               Enum.find(Spec.vocabulary().triggers, &(&1.type == "list_top"))

      assert Spec.catalogue() =~ "- list_top:"
    end

    test "a rule naming a list the board doesn't have is refused", ctx do
      assert {:error, changeset} =
               Automations.create_rule(%{
                 "name" => "Feed",
                 "spec" => feed_spec(%{"column" => "Nowhere"}),
                 "board_id" => ctx.board.id
               })

      assert {"there's no list called “Nowhere” on this board", _} = changeset.errors[:spec]
    end
  end

  describe "feeding" do
    test "saving the rule queues one job, for the top card", ctx do
      [top, _, _] = for t <- ~w(one two three), do: card_fixture(ctx.todo, %{"title" => t})
      rule = feed_rule(ctx.board)

      assert [%Job{card_id: card_id, pool: "loop", status: "queued"}] = jobs(rule)
      assert card_id == top.id
    end

    test "while its job is open nothing more is queued", ctx do
      [a, b] = for t <- ~w(a b), do: card_fixture(ctx.todo, %{"title" => t})
      rule = feed_rule(ctx.board)

      card_fixture(ctx.todo)
      Boards.Cards.update_card(b, %{"priority" => "high"})
      assert {:idle, :job_open} = Automations.feed(rule)
      assert Automations.run_rule_now(rule) == 0

      # Claimed and running is just as open as queued.
      job = Runners.claim(ctx.runner)
      Runners.heartbeat(ctx.runner, job.id)
      card_fixture(ctx.todo)
      assert queued_cards(rule) == [a.id]
    end

    for status <- ~w(done failed cancelled) do
      test "a job ending #{status} sends the next card", ctx do
        [a, b] = for t <- ~w(a b), do: card_fixture(ctx.todo, %{"title" => t})
        rule = feed_rule(ctx.board)

        finish(ctx.runner, unquote(status))

        # The card the runner left at the top cools down; the next one goes.
        assert queued_cards(rule) == [b.id]
        refute a.id in queued_cards(rule)
      end
    end

    test "a queued job cancelled from the board sends the next card", ctx do
      [_a, b] = for t <- ~w(a b), do: card_fixture(ctx.todo, %{"title" => t})
      rule = feed_rule(ctx.board)

      {:ok, _} = rule |> open_jobs() |> hd() |> Runners.cancel_job()
      assert queued_cards(rule) == [b.id]
    end

    test "a job the runners kept dropping sends the next card", ctx do
      [_a, b] = for t <- ~w(a b), do: card_fixture(ctx.todo, %{"title" => t})
      rule = feed_rule(ctx.board)
      [job] = open_jobs(rule)
      past = DateTime.utc_now() |> DateTime.add(-60) |> DateTime.truncate(:second)

      Repo.update_all(from(j in Job, where: j.id == ^job.id),
        set: [status: "running", attempts: Runners.max_attempts(), lease_expires_at: past]
      )

      Runners.sweep()
      assert Repo.get!(Job, job.id).status == "failed"
      assert queued_cards(rule) == [b.id]
    end

    test "the card the runner finished with is sent again once it has cooled down", ctx do
      a = card_fixture(ctx.todo, %{"title" => "a"})
      rule = feed_rule(ctx.board)

      job = finish(ctx.runner, "failed")
      assert {:idle, :empty} = Automations.feed(rule)

      age(job)
      assert {:ok, %{id: id}} = Automations.feed(rule)
      assert id == a.id
    end

    test "Run now sends the top card at once, cool-down or not", ctx do
      a = card_fixture(ctx.todo, %{"title" => "a"})
      rule = feed_rule(ctx.board)
      finish(ctx.runner, "failed")

      assert Automations.run_rule_now(rule) == 1
      assert queued_cards(rule) == [a.id]
    end

    test "moving a card to the top while nothing is open sends it", ctx do
      a = card_fixture(ctx.todo, %{"title" => "a"})
      rule = feed_rule(ctx.board)
      job = finish(ctx.runner, "done")
      age(job)
      Boards.Cards.move_card_to_index(Repo.reload!(a), ctx.done, :top)
      assert open_jobs(rule) == []

      b = card_fixture(hd(ctx.board.columns), %{"title" => "b"})
      Boards.Cards.move_card_to_index(b, ctx.todo, :top)
      assert queued_cards(rule) == [b.id]
    end

    test "reordering the list while a job is open queues no second job", ctx do
      [a, b] = for t <- ~w(a b), do: card_fixture(ctx.todo, %{"title" => t})
      rule = feed_rule(ctx.board)

      Boards.Cards.move_card_to_index(b, ctx.todo, :top)
      assert queued_cards(rule) == [a.id]
    end

    test "reordering the list with nothing open sends the new top card", ctx do
      [_a, b, _c] = for t <- ~w(a b c), do: card_fixture(ctx.todo, %{"title" => t})
      rule = feed_rule(ctx.board)

      # Cancel jobs until nothing is open and every card is cooling down.
      cancelled =
        Enum.map(1..3, fn _ ->
          [job] = open_jobs(rule)
          {:ok, job} = Runners.cancel_job(job)
          job
        end)

      assert open_jobs(rule) == []
      Enum.each(cancelled, &age/1)

      Boards.Cards.move_card_to_index(Repo.reload!(b), ctx.todo, :top)
      assert queued_cards(rule) == [b.id]
    end

    test "skips flagged, dependency-blocked, completed, archived and assigned cards", ctx do
      blocked = card_fixture(ctx.todo, %{"title" => "flag blocked", "flags" => ["blocked"]})
      waiting = card_fixture(ctx.todo, %{"title" => "flag waiting", "flags" => ["waiting"]})
      dep = card_fixture(ctx.todo, %{"title" => "waits on another"})
      blocker = card_fixture(ctx.doing, %{"title" => "unfinished"})
      {:ok, _} = Boards.Dependencies.add_dependency(dep, blocker)
      complete = card_fixture(ctx.todo, %{"title" => "already done", "completed" => true})
      archived = card_fixture(ctx.todo, %{"title" => "archived"})
      {:ok, _} = Boards.Cards.archive_card(archived)
      mine = card_fixture(ctx.todo, %{"title" => "taken", "assignee_id" => ctx.owner.id})
      free = card_fixture(ctx.todo, %{"title" => "free"})

      rule = feed_rule(ctx.board, %{"unassigned" => true})

      assert queued_cards(rule) == [free.id]

      for card <- [blocked, waiting, dep, complete, archived, mine],
          do: refute(card.id in queued_cards(rule))
    end

    test "skips a card pending verification or merging, and sends a rejected one", ctx do
      pending = card_fixture(ctx.todo, %{"title" => "submitted"})
      merging = card_fixture(ctx.todo, %{"title" => "accepted, merging"})
      rejected = card_fixture(ctx.todo, %{"title" => "sent back"})

      # Only Slipdock.Verified sets these; the feed only reads them (#1807).
      for {card, state} <- [{pending, "pending"}, {merging, "merging"}, {rejected, "rejected"}],
          do:
            Repo.update_all(from(c in Card, where: c.id == ^card.id), set: [verify_state: state])

      rule = feed_rule(ctx.board)
      assert queued_cards(rule) == [rejected.id]

      Repo.update_all(from(c in Card, where: c.id == ^rejected.id),
        set: [verify_state: "pending"]
      )

      assert Automations.next_card(rule, force: true) == nil
    end

    test "an assigned card is sent when the rule doesn't ask for unassigned ones", ctx do
      mine = card_fixture(ctx.todo, %{"assignee_id" => ctx.owner.id})
      rule = feed_rule(ctx.board)
      assert queued_cards(rule) == [mine.id]
    end

    test "the rule's conditions narrow the cards too", ctx do
      card_fixture(ctx.todo, %{"title" => "low", "priority" => "low"})
      high = card_fixture(ctx.todo, %{"title" => "high", "priority" => "high"})

      rule =
        rule_fixture(
          ctx.board,
          Map.put(feed_spec(), "conditions", [
            %{"field" => "priority", "op" => "is", "value" => "high"}
          ])
        )

      assert queued_cards(rule) == [high.id]
    end

    test "an empty list queues nothing", ctx do
      rule = feed_rule(ctx.board)
      assert jobs(rule) == []
      assert {:idle, :empty} = Automations.feed(rule)
      assert Automations.run_rule_now(rule) == 0
    end

    test "a switched-off rule sends nothing until it is switched on", ctx do
      card = card_fixture(ctx.todo)
      rule = feed_rule(ctx.board, %{}, %{"enabled" => false})
      assert jobs(rule) == []
      assert {:idle, :disabled} = Automations.feed(rule)

      {:ok, _} = Automations.toggle_rule(rule)
      assert queued_cards(rule) == [card.id]
    end

    test "the clock picks up a card that became ready with no event on the board", ctx do
      blocker = card_fixture(ctx.doing, %{"title" => "blocker"})
      card = card_fixture(ctx.todo, %{"title" => "waits"})
      {:ok, _} = Boards.Dependencies.add_dependency(card, blocker)
      rule = feed_rule(ctx.board)
      assert jobs(rule) == []

      # Completed behind the board's back: no event, so nothing fed.
      Repo.update_all(from(c in Slipdock.Boards.Card, where: c.id == ^blocker.id),
        set: [completed: true]
      )

      assert jobs(rule) == []
      Automations.run_scheduled()
      assert queued_cards(rule) == [card.id]
    end
  end

  # Two feeds on one list, for two pools, work it side by side (#1956): each
  # passes over a card the other already has a job open on.
  describe "two feeds on one list" do
    defp spare_rule(board) do
      rule_fixture(board, %{
        feed_spec()
        | "actions" => [%{"type" => "runner", "pool" => "spare"}]
      })
    end

    test "each sends a different card, and the next free one when its job ends", ctx do
      [a, b, c] = for t <- ~w(a b c), do: card_fixture(ctx.todo, %{"title" => t})
      {:ok, spare, _} = Runners.create_runner(ctx.board, %{"name" => "spare", "pool" => "spare"})

      loop = feed_rule(ctx.board)
      other = spare_rule(ctx.board)

      assert queued_cards(loop) == [a.id]
      assert queued_cards(other) == [b.id]

      # Claimed and running holds the card just as queued does.
      job = Runners.claim(spare)
      Runners.heartbeat(spare, job.id)

      finish(ctx.runner, "done")
      assert queued_cards(loop) == [c.id]
      assert queued_cards(other) == [b.id]
    end

    test "neither sends a card the other holds, even when it is the only one", ctx do
      only = card_fixture(ctx.todo, %{"title" => "only"})
      loop = feed_rule(ctx.board)
      other = spare_rule(ctx.board)

      assert queued_cards(loop) == [only.id]
      assert jobs(other) == []
      assert {:idle, :empty} = Automations.feed(other)
      assert Automations.next_card(other, force: true) == nil
    end

    test "a job no rule queued holds its card until it ends", ctx do
      [held, free] = for t <- ~w(held free), do: card_fixture(ctx.todo, %{"title" => t})
      {:ok, job} = Runners.queue(held, %{pool: "loop", kind: "claude", prompt: "by hand"})

      rule = feed_rule(ctx.board)
      assert queued_cards(rule) == [free.id]
      # Both are held now: one by hand, one by the rule's own job.
      assert Automations.next_card(rule, force: true) == nil

      # Once the hand-queued job is over, the card is the rule's to send.
      {:ok, _} = Runners.cancel_job(job)
      assert %Card{id: id} = Automations.next_card(rule, force: true)
      assert id == held.id
    end
  end

  describe "making one" do
    test "the preset makes a list_top rule that skips assigned cards", ctx do
      preset = Presets.get("feed_runner")
      # The to-do list after the Backlog: where the work is taken from.
      assert Presets.defaults(preset, ctx.board)["column"] == "To Do"

      assert {:ok, rule} =
               Automations.create_rule_from_preset(ctx.board, "feed_runner", %{
                 "column" => "To Do",
                 "pool" => "Loop"
               })

      assert rule.spec["trigger"] == %{
               "type" => "list_top",
               "column" => "To Do",
               "unassigned" => true
             }

      assert [%{"type" => "runner", "pool" => "loop", "kind" => "claude"}] = rule.spec["actions"]
    end

    test "the runner wizard's top-card choice makes one", ctx do
      card = card_fixture(ctx.todo)

      params = %{
        "scenario" => "loop",
        "pool" => "loop",
        "column" => "To Do",
        "feed" => "top"
      }

      assert {:ok, %{rule: rule}} =
               Setup.connect(ctx.board, params, ctx.owner, "https://slipdock.test")

      assert Spec.feed?(rule.spec)
      assert queued_cards(rule) == [card.id]
    end
  end

  describe "lanes (#2102)" do
    # A card in progress that a job is working on, holding `lib/**`.
    setup ctx do
      {:ok, board} = Boards.update_board(ctx.board, %{"lanes" => true})
      running = pathed(ctx.doing, "Running", "lib/**")
      working_job_fixture(running)
      %{board: board, running: running}
    end

    defp pathed(column, title, paths) do
      card = card_fixture(column, %{"title" => title})
      {:ok, card} = Boards.Cards.update_card(card, %{"paths" => paths})
      card
    end

    test "passes over a card its lane would hold and sends the next that could start", ctx do
      held = pathed(ctx.todo, "Held", "lib/a.ex")
      free = pathed(ctx.todo, "Free", "docs/**")
      rule = feed_rule(ctx.board)

      # Saving the rule fed it: the free card went, though the held one is on top.
      assert queued_cards(rule) == [free.id]
      refute held.id in Enum.map(jobs(rule), & &1.card_id)
    end

    test "sends nothing while every card in the list is held", ctx do
      pathed(ctx.todo, "Held", "lib/a.ex")
      rule = feed_rule(ctx.board)

      assert Automations.next_card(rule) == nil
      assert jobs(rule) == []
      assert Automations.feed(rule) == {:idle, :empty}
    end

    test "withdraws its own queued job a lane holds, sends the next card, and the held one " <>
           "goes when its lane frees",
         ctx do
      first = pathed(ctx.todo, "First", "lib/a.ex")
      second = pathed(ctx.todo, "Second", "docs/**")

      # Sent before its lane was held: the card in the way only now has a job.
      Repo.update_all(from(j in Job, where: j.card_id == ^ctx.running.id), set: [status: "done"])
      rule = feed_rule(ctx.board)
      assert [%Job{id: held_id}] = open_jobs(rule)
      assert queued_cards(rule) == [first.id]
      working_job_fixture(ctx.running)

      assert {:ok, %Card{id: id}} = Automations.feed(rule)
      assert id == second.id
      assert queued_cards(rule) == [second.id]

      held = Repo.get!(Job, held_id)
      assert held.status == "cancelled"
      assert held.recovery == "withdrawn"

      assert held.error ==
               "Lane: overlaps ##{ctx.running.id}, in progress: gave way to ##{second.id}"

      assert [comment] = Repo.preload(Repo.get!(Card, first.id), :comments).comments
      assert comment.body =~ "its paths overlap ##{ctx.running.id}"
      assert comment.body =~ "gave way to ##{second.id}"

      # The card in the way is done, and so is the second card's job: the
      # withdrawn card is next, cool-down or not.
      {:ok, _} = Boards.Cards.update_card(ctx.running, %{"completed" => true})
      finish(ctx.runner, "done")
      assert queued_cards(rule) == [first.id]
    end

    test "keeps its held job when no other card could start", ctx do
      first = pathed(ctx.todo, "First", "lib/a.ex")
      pathed(ctx.todo, "Also held", "lib/b.ex")
      Repo.update_all(from(j in Job, where: j.card_id == ^ctx.running.id), set: [status: "done"])
      rule = feed_rule(ctx.board)
      working_job_fixture(ctx.running)

      assert Automations.feed(rule) == {:idle, :job_open}
      assert [%Job{status: "queued", card_id: card_id}] = open_jobs(rule)
      assert card_id == first.id
      assert Repo.preload(Repo.get!(Card, first.id), :comments).comments == []
    end

    test "never withdraws a job that has been handed out", ctx do
      first = pathed(ctx.todo, "First", "docs/a.md")
      pathed(ctx.todo, "Second", "docs/b.md")
      rule = feed_rule(ctx.board)
      assert %Job{card_id: card_id} = Runners.claim(ctx.runner)
      assert card_id == first.id

      assert Automations.feed(rule) == {:idle, :job_open}
      assert [%Job{status: "claimed"}] = open_jobs(rule)
    end

    test "with lanes advising, an overlapping card is sent as usual", ctx do
      {:ok, _} = Boards.update_board(ctx.board, %{"lane_mode" => "advise"})
      held = pathed(ctx.todo, "Overlapping", "lib/a.ex")
      rule = feed_rule(ctx.board)
      assert queued_cards(rule) == [held.id]
    end

    test "with lanes off, an overlapping card is sent as usual", ctx do
      {:ok, _} = Boards.update_board(ctx.board, %{"lanes" => false})
      held = pathed(ctx.todo, "Overlapping", "lib/a.ex")
      rule = feed_rule(ctx.board)
      assert queued_cards(rule) == [held.id]
    end
  end

  describe "a pool gone offline (#2805)" do
    # Last seen `ago` seconds back: three leases (270 s) is online.
    defp seen(runner, ago) do
      at = DateTime.utc_now() |> DateTime.add(-ago, :second) |> DateTime.truncate(:second)

      Repo.update_all(from(r in Runners.Runner, where: r.id == ^runner.id),
        set: [last_seen_at: at]
      )
    end

    defp offline(runner), do: seen(runner, 1_000)

    defp comments(card), do: Repo.preload(Repo.get!(Card, card.id), :comments).comments

    setup ctx do
      {:ok, spare, _} = Runners.create_runner(ctx.board, %{"name" => "spare", "pool" => "spare"})
      seen(spare, 5)
      %{spare: spare}
    end

    test "a pool is offline only once one of its runners has been seen, and none lately", ctx do
      refute Runners.pool_offline?(ctx.board.id, "loop")
      offline(ctx.runner)
      assert Runners.pool_offline?(ctx.board.id, "loop")

      # One runner of the pool online is enough, and another pool's doesn't count.
      {:ok, other, _} = Runners.create_runner(ctx.board, %{"name" => "box 2", "pool" => "loop"})
      seen(other, 200)
      refute Runners.pool_offline?(ctx.board.id, "loop")
      seen(other, 300)
      assert Runners.pool_offline?(ctx.board.id, "loop")
      refute Runners.pool_offline?(ctx.board.id, "spare")
      refute Runners.pool_offline?(ctx.board.id, "nobody")
    end

    test "its feed sends nothing, and an online pool's feed takes the top card", ctx do
      offline(ctx.runner)
      [top, next] = for t <- ~w(top next), do: card_fixture(ctx.todo, %{"title" => t})

      loop = feed_rule(ctx.board)
      assert jobs(loop) == []
      assert Automations.feed(loop) == {:idle, :offline}
      assert Automations.run_rule_now(loop) == 0

      spare = spare_rule(ctx.board)
      assert queued_cards(spare) == [top.id]
      assert %Job{card_id: card_id} = Runners.claim(ctx.spare)
      assert card_id == top.id
      assert jobs(loop) == []
      refute next.id in queued_cards(spare)
    end

    test "a card it sent that no runner has taken goes to an online pool instead", ctx do
      seen(ctx.runner, 5)
      [top, next] = for t <- ~w(top next), do: card_fixture(ctx.todo, %{"title" => t})
      loop = feed_rule(ctx.board)
      spare = spare_rule(ctx.board)
      assert [%Job{id: sent_id}] = open_jobs(loop)
      assert queued_cards(loop) == [top.id]
      assert queued_cards(spare) == [next.id]

      # The spare runner takes the next card; then the loop runner goes away.
      Runners.claim(ctx.spare)
      offline(ctx.runner)
      assert Automations.feed(loop) == {:idle, :offline}

      sent = Repo.get!(Job, sent_id)
      assert sent.status == "cancelled"
      assert sent.recovery == "withdrawn"
      assert sent.error == "No runner online for pool loop: gave its card back"
      assert open_jobs(loop) == []

      assert [comment] = comments(top)
      assert comment.body =~ "Job ##{sent_id} gave this card back"
      assert comment.body =~ "no runner of pool loop has been online"

      # The spare feed is busy with `next`; once that is done it sends `top`,
      # the card the offline pool gave back, not cooling.
      finish_claimed(ctx.spare)
      assert queued_cards(spare) == [top.id]
      assert queued_cards(loop) == []
    end

    test "a given-back card goes to an idle online pool at once", ctx do
      seen(ctx.runner, 5)
      top = card_fixture(ctx.todo, %{"title" => "top"})
      loop = feed_rule(ctx.board)
      spare = spare_rule(ctx.board)
      assert queued_cards(loop) == [top.id]
      assert queued_cards(spare) == []

      offline(ctx.runner)
      assert Automations.feed(loop) == {:idle, :offline}
      assert queued_cards(spare) == [top.id]
    end

    test "a job already handed out is never given back", ctx do
      seen(ctx.runner, 5)
      top = card_fixture(ctx.todo, %{"title" => "top"})
      loop = feed_rule(ctx.board)
      assert %Job{id: id} = Runners.claim(ctx.runner)

      offline(ctx.runner)
      assert Automations.feed(loop) == {:idle, :offline}
      assert [%Job{id: ^id, status: "claimed"}] = open_jobs(loop)

      assert comments(Repo.get!(Card, top.id))
             |> Enum.all?(&(not (&1.body =~ "gave this card back")))
    end

    test "a job an answered question queued is kept for the pool's return", ctx do
      seen(ctx.runner, 5)
      top = card_fixture(ctx.todo, %{"title" => "top"})
      loop = feed_rule(ctx.board)
      assert [%Job{} = answer_job] = open_jobs(loop)

      Repo.insert!(%Slipdock.Boards.Wait{
        card_id: top.id,
        needs: "which one?",
        requeue_state: "queued",
        requeue_job_id: answer_job.id
      })

      offline(ctx.runner)
      assert Automations.feed(loop) == {:idle, :offline}
      assert Repo.get!(Job, answer_job.id).status == "queued"
    end

    test "the pool back online is sent work again", ctx do
      offline(ctx.runner)
      top = card_fixture(ctx.todo, %{"title" => "top"})
      loop = feed_rule(ctx.board)
      assert jobs(loop) == []

      seen(ctx.runner, 5)
      assert {:ok, %Card{id: id}} = Automations.feed(loop)
      assert id == top.id
      assert queued_cards(loop) == [top.id]
    end

    test "a rule sending to two pools keeps feeding while one of them is online", ctx do
      offline(ctx.runner)
      top = card_fixture(ctx.todo, %{"title" => "top"})

      both =
        rule_fixture(ctx.board, %{
          feed_spec()
          | "actions" => [
              %{"type" => "runner", "pool" => "loop"},
              %{"type" => "runner", "pool" => "spare"}
            ]
        })

      assert top.id in queued_cards(both)
      refute Automations.feed(both) == {:idle, :offline}
      assert Enum.all?(open_jobs(both), &(&1.status == "queued"))
    end

    test "a rule on a sub-board reads its pool's runners on the tree's root", ctx do
      seen(ctx.runner, 5)
      {:ok, t} = Boards.Templates.find_template(nil, "Simple")
      epic = card_fixture(ctx.todo, %{"title" => "Epic"})
      {:ok, sub} = sub_board(epic, t)
      sub = Boards.get_board!(sub.id)
      ready = hd(sub.columns)
      task = card_fixture(ready, %{"title" => "Sub task"})

      rule = feed_rule(sub, %{"column" => ready.name})
      assert [%Job{id: sent_id}] = open_jobs(rule)
      assert queued_cards(rule) == [task.id]

      offline(ctx.runner)
      assert Automations.feed(rule) == {:idle, :offline}
      assert Repo.get!(Job, sent_id).status == "cancelled"
      assert open_jobs(rule) == []
      assert [comment] = comments(task)
      assert comment.body =~ "Job ##{sent_id} gave this card back"
    end

    test "a rule with no runner action fires whatever the pools' runners", ctx do
      offline(ctx.runner)
      top = card_fixture(ctx.todo, %{"title" => "top"})

      # The spec's check asks a list_top rule for a runner action; one saved
      # before it, with only a comment, is still a feed and sends to no pool.
      rule = feed_rule(ctx.board)
      spec = %{feed_spec() | "actions" => [%{"type" => "comment", "body" => "Up next"}]}
      Repo.update_all(from(r in Automations.Rule, where: r.id == ^rule.id), set: [spec: spec])
      rule = Repo.get!(Automations.Rule, rule.id)
      assert Spec.feed?(rule.spec)

      assert {:ok, %Card{id: id}} = Automations.feed(rule)
      assert id == top.id
      assert Enum.any?(comments(top), &(&1.body =~ "Up next"))
    end

    test "runners never seen yet are fed as before", ctx do
      top = card_fixture(ctx.todo, %{"title" => "top"})
      loop = feed_rule(ctx.board)
      assert queued_cards(loop) == [top.id]
    end
  end

  # Finishes the job `runner` holds, leaving its card where it is.
  defp finish_claimed(runner) do
    job = Repo.one!(from(j in Job, where: j.runner_id == ^runner.id and j.status == "claimed"))
    {:ok, _} = Runners.finish(runner, job.id, %{status: "done"})
  end
end
