defmodule Slipdock.Automations.FeedTest do
  # The `list_top` trigger: a rule that keeps a runner pool busy with a list,
  # one card at a time in the list's order (`Slipdock.Automations.feed/2`).
  use Slipdock.DataCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.{Automations, Boards, Repo, Runners}
  alias Slipdock.Automations.{Presets, Spec}
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
      Boards.update_card(b, %{"priority" => "high"})
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
      Boards.move_card_to_index(Repo.reload!(a), ctx.done, :top)
      assert open_jobs(rule) == []

      b = card_fixture(hd(ctx.board.columns), %{"title" => "b"})
      Boards.move_card_to_index(b, ctx.todo, :top)
      assert queued_cards(rule) == [b.id]
    end

    test "reordering the list while a job is open queues no second job", ctx do
      [a, b] = for t <- ~w(a b), do: card_fixture(ctx.todo, %{"title" => t})
      rule = feed_rule(ctx.board)

      Boards.move_card_to_index(b, ctx.todo, :top)
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

      Boards.move_card_to_index(Repo.reload!(b), ctx.todo, :top)
      assert queued_cards(rule) == [b.id]
    end

    test "skips flagged, dependency-blocked, completed, archived and assigned cards", ctx do
      blocked = card_fixture(ctx.todo, %{"title" => "flag blocked", "flags" => ["blocked"]})
      waiting = card_fixture(ctx.todo, %{"title" => "flag waiting", "flags" => ["waiting"]})
      dep = card_fixture(ctx.todo, %{"title" => "waits on another"})
      blocker = card_fixture(ctx.doing, %{"title" => "unfinished"})
      {:ok, _} = Boards.add_dependency(dep, blocker)
      complete = card_fixture(ctx.todo, %{"title" => "already done", "completed" => true})
      archived = card_fixture(ctx.todo, %{"title" => "archived"})
      {:ok, _} = Boards.archive_card(archived)
      mine = card_fixture(ctx.todo, %{"title" => "taken", "assignee_id" => ctx.owner.id})
      free = card_fixture(ctx.todo, %{"title" => "free"})

      rule = feed_rule(ctx.board, %{"unassigned" => true})

      assert queued_cards(rule) == [free.id]

      for card <- [blocked, waiting, dep, complete, archived, mine],
          do: refute(card.id in queued_cards(rule))
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
      {:ok, _} = Boards.add_dependency(card, blocker)
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
end
