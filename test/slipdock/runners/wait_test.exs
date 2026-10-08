defmodule Slipdock.Runners.WaitTest do
  # A job that waits while anything is in progress (`wait_while_doing`): it
  # stays queued, and claim passes it over, while another open card is in a
  # doing list on its board.
  use Slipdock.DataCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.{Automations, Boards, Repo, Runners}
  alias Slipdock.Automations.{Presets, Spec}
  alias Slipdock.Runners.{Job, Setup}

  setup do
    owner = user_fixture()
    board = board_fixture(%{"name" => "Waits"}, owner: owner)
    [_backlog, todo, doing, done] = board.columns
    {:ok, runner, _} = Runners.create_runner(board, %{"name" => "box", "pool" => "loop"})
    card = card_fixture(todo, %{"title" => "Next up"})

    %{
      owner: owner,
      board: board,
      todo: todo,
      doing: doing,
      done: done,
      runner: runner,
      card: card
    }
  end

  defp queue(card, wait \\ true),
    do: Runners.queue(card, %{pool: "loop", kind: "claude", prompt: "go", wait_while_doing: wait})

  describe "claiming" do
    test "a card in progress holds the job back, queued and with no try counted", ctx do
      busy = card_fixture(ctx.doing, %{"title" => "Being worked by hand"})
      {:ok, job} = queue(ctx.card)

      assert Runners.claim(ctx.runner) == nil
      job = Repo.reload!(job)
      assert job.status == "queued"
      assert job.attempts == 0
      assert Runners.waiting_on(job).id == busy.id
      assert Runners.waiting_reason(job) == "##{busy.id} is in progress"
      assert Runners.first_waiting(ctx.board, "loop").id == job.id
    end

    test "once that card leaves the list, the next claim gets the job", ctx do
      busy = card_fixture(ctx.doing)
      {:ok, job} = queue(ctx.card)
      assert Runners.claim(ctx.runner) == nil

      :ok = Boards.move_card_to_index(busy, ctx.done, :top)
      assert %Job{id: id, status: "claimed"} = Runners.claim(ctx.runner)
      assert id == job.id
      assert Runners.first_waiting(ctx.board, "loop") == nil
    end

    test "the job's own card in progress doesn't hold it back", ctx do
      {:ok, job} = queue(ctx.card)
      :ok = Boards.move_card_to_index(ctx.card, ctx.doing, :top)

      assert Runners.waiting_on(Repo.reload!(job)) == nil
      assert %Job{id: id} = Runners.claim(ctx.runner)
      assert id == job.id
    end

    test "completed and archived cards in the list don't count", ctx do
      card_fixture(ctx.doing, %{"completed" => true})
      {:ok, _} = ctx.doing |> card_fixture() |> Boards.archive_card()
      {:ok, job} = queue(ctx.card)

      assert %Job{id: id} = Runners.claim(ctx.runner)
      assert id == job.id
    end

    test "a card in progress on a sub-board doesn't hold back a job on the board", ctx do
      epic = card_fixture(ctx.todo, %{"title" => "Epic"})

      template = %Boards.Template{
        name: "Breakdown",
        columns: [
          %{"name" => "To Do", "category" => "todo"},
          %{"name" => "Doing", "category" => "doing"},
          %{"name" => "Done", "category" => "done"}
        ]
      }

      {:ok, sub} = sub_board(epic, template)
      sub = Boards.get_board!(sub.id)
      sub_doing = Enum.find(sub.columns, &(&1.category == "doing"))
      card_fixture(sub_doing, %{"title" => "A subcard underway"})
      {:ok, job} = queue(ctx.card)

      assert %Job{id: id} = Runners.claim(ctx.runner)
      assert id == job.id
    end

    test "a later job that doesn't wait is handed out past one that does", ctx do
      card_fixture(ctx.doing)
      {:ok, waiting} = queue(ctx.card)
      {:ok, free} = queue(card_fixture(ctx.todo), false)

      assert %Job{id: id} = Runners.claim(ctx.runner)
      assert id == free.id
      assert Repo.reload!(waiting).status == "queued"
    end

    test "without the option, claiming is as it was", ctx do
      card_fixture(ctx.doing)
      {:ok, job} = queue(ctx.card, false)

      refute Repo.reload!(job).wait_while_doing
      assert Runners.waiting_on(job) == nil
      assert %Job{id: id} = Runners.claim(ctx.runner)
      assert id == job.id
    end

    test "a running job is never waiting, whatever is in progress", ctx do
      {:ok, job} = queue(ctx.card)
      Runners.claim(ctx.runner)
      card_fixture(ctx.doing)
      assert Runners.waiting_reason(Repo.reload!(job)) == nil
    end
  end

  describe "the rule" do
    defp spec(action \\ %{}) do
      %{
        "trigger" => %{"type" => "card_entered", "column" => "To Do"},
        "actions" => [Map.merge(%{"type" => "runner", "pool" => "loop"}, action)]
      }
    end

    test "the runner action takes wait_while_doing as a boolean and says so" do
      assert {:ok, %{"actions" => [%{"wait_while_doing" => true}]}} =
               Spec.validate(spec(%{"wait_while_doing" => "true"}))

      assert {:error, "action “runner” wait_while_doing must be true or false"} =
               Spec.validate(spec(%{"wait_while_doing" => "often"}))

      assert Spec.summary(spec(%{"wait_while_doing" => true})) =~
               "send it to the loop runners (claude) once nothing is in progress"

      runner = Enum.find(Spec.vocabulary().actions, &(&1.type == "runner"))
      assert "wait_while_doing" in runner.optional
    end

    test "queues jobs that wait", ctx do
      rule = rule_fixture(ctx.board, spec(%{"wait_while_doing" => true}))
      card = card_fixture(ctx.todo)

      assert [%Job{wait_while_doing: true}] =
               Repo.all(from(j in Job, where: j.rule_id == ^rule.id and j.card_id == ^card.id))
    end

    test "is refused on a board with no in-progress list", ctx do
      {:ok, plain} =
        Boards.create_board(%{"name" => "No doing", "code" => "nd#{rem(ctx.owner.id, 100_000)}"},
          columns: [
            %{"name" => "Inbox", "category" => "todo"},
            %{"name" => "Done", "category" => "done"}
          ],
          owner_id: ctx.owner.id
        )

      plain = Boards.get_board!(plain.id)
      assert Enum.all?(plain.columns, &(&1.category != "doing"))

      assert {:error, changeset} =
               Automations.create_rule(%{
                 "name" => "Waits",
                 "spec" => spec(%{"wait_while_doing" => true}),
                 "board_id" => plain.id
               })

      assert {"wait_while_doing needs an in-progress list" <> _, _} = changeset.errors[:spec]

      # Without the option the same rule is fine there.
      assert {:ok, _} =
               Automations.create_rule(%{
                 "name" => "Plain",
                 "spec" => spec(),
                 "board_id" => plain.id
               })
    end

    test "the top-card preset waits by default, the arrival one doesn't", ctx do
      {:ok, feed} =
        Automations.create_rule_from_preset(ctx.board, "feed_runner", %{
          "column" => "Backlog",
          "pool" => "loop"
        })

      assert [%{"wait_while_doing" => true}] = feed.spec["actions"]

      {:ok, send} =
        Automations.create_rule_from_preset(ctx.board, "send_to_runner", %{
          "column" => "Doing",
          "pool" => "loop"
        })

      refute Map.has_key?(hd(send.spec["actions"]), "wait_while_doing")

      assert {:ok, %{"spec" => %{"actions" => [action]}}} =
               Presets.build("feed_runner", %{"column" => "To Do", "pool" => "x", "wait" => "no"})

      refute Map.has_key?(action, "wait_while_doing")

      assert {:ok, %{"spec" => %{"actions" => [%{"wait_while_doing" => true}]}}} =
               Presets.build("send_to_runner", %{
                 "column" => "To Do",
                 "pool" => "x",
                 "wait" => "yes"
               })
    end

    test "the wizard passes the choice on", ctx do
      params = %{"scenario" => "loop", "pool" => "loop", "column" => "To Do", "feed" => "top"}

      {:ok, %{rule: on}} =
        Setup.connect(ctx.board, params, ctx.owner, "https://slipdock.test")

      assert [%{"wait_while_doing" => true}] = on.spec["actions"]

      {:ok, %{rule: off}} =
        Setup.connect(
          ctx.board,
          Map.merge(params, %{"column" => "Backlog", "wait" => "no"}),
          ctx.owner,
          "https://slipdock.test"
        )

      refute Map.has_key?(hd(off.spec["actions"]), "wait_while_doing")
    end
  end
end
