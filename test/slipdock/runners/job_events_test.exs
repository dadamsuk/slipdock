defmodule Slipdock.Runners.JobEventsTest do
  # The `job_finished` trigger: a rule hears once about each runner job that
  # ends — how it ended, and whether its card was put back or given up on.
  use Slipdock.DataCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.{Automations, Boards, Repo, Runners}
  alias Slipdock.Automations.{Presets, Spec}
  alias Slipdock.Runners.{Job, Setup}

  setup do
    owner = user_fixture()
    board = board_fixture(%{"name" => "Events"}, owner: owner)
    [_backlog, todo, doing, _done] = board.columns
    {:ok, runner, _} = Runners.create_runner(board, %{"name" => "box", "pool" => "loop"})
    card = card_fixture(todo, %{"title" => "Next up"})
    %{owner: owner, board: board, todo: todo, doing: doing, runner: runner, card: card}
  end

  # A rule that writes down every job_finished it hears, on the card.
  defp listener(board, trigger \\ %{}) do
    rule_fixture(board, %{
      "trigger" => Map.merge(%{"type" => "job_finished"}, trigger),
      "actions" => [
        %{
          "type" => "comment",
          "body" =>
            "HEARD job {{job.id}} {{job.status}}/{{job.outcome}} pool {{job.pool}} " <>
              "exit {{job.exit_code}} on {{card.title}}"
        }
      ]
    })
  end

  defp heard(card) do
    Repo.all(
      from(c in Boards.Comment,
        where: c.card_id == ^card.id and like(c.body, "HEARD%"),
        order_by: [asc: c.id],
        select: c.body
      )
    )
  end

  defp queue(card, pool \\ "loop"),
    do: Runners.queue(card, %{pool: pool, kind: "claude", prompt: "go"})

  describe "a job ending" do
    for status <- ~w(done failed cancelled timeout) do
      test "#{status} is heard once, with the job's fields", ctx do
        listener(ctx.board)
        {:ok, job} = queue(ctx.card)
        job = Runners.claim(ctx.runner)

        {:ok, _} = Runners.finish(ctx.runner, job.id, %{status: unquote(status), exit: "4"})
        # Said twice: the second is a no-op.
        {:ok, _} = Runners.finish(ctx.runner, job.id, %{status: unquote(status)})

        status = unquote(status)

        assert heard(ctx.card) == [
                 "HEARD job #{job.id} #{status}/#{status} pool loop exit 4 on Next up"
               ]
      end
    end

    test "a queued job cancelled from the board is heard as cancelled", ctx do
      listener(ctx.board)
      {:ok, job} = queue(ctx.card)

      {:ok, _} = Runners.cancel_job(job)

      assert [line] = heard(ctx.card)
      assert line =~ "cancelled/cancelled"
    end

    test "a lease running out is heard only when the sweep gives up", ctx do
      listener(ctx.board)
      {:ok, job} = queue(ctx.card)
      Runners.claim(ctx.runner)
      later = DateTime.add(DateTime.utc_now(), Runners.lease_seconds() + 5, :second)

      # Back in the queue: not over yet.
      Runners.sweep(later)
      assert heard(ctx.card) == []

      Runners.claim(ctx.runner)

      Repo.update_all(from(j in Job, where: j.id == ^job.id),
        set: [attempts: Runners.max_attempts()]
      )

      Runners.sweep(DateTime.add(later, Runners.lease_seconds() + 5, :second))
      assert [line] = heard(ctx.card)
      assert line =~ "failed/failed"
    end

    test "outcome picks which endings a rule hears", ctx do
      listener(ctx.board, %{"outcome" => ["timeout"]})

      for status <- ~w(done failed timeout) do
        {:ok, _} = queue(ctx.card)
        job = Runners.claim(ctx.runner)
        {:ok, _} = Runners.finish(ctx.runner, job.id, %{status: status})
      end

      assert [line] = heard(ctx.card)
      assert line =~ "timeout/timeout"
    end

    test "pool picks whose jobs a rule hears", ctx do
      listener(ctx.board, %{"pool" => "gpu"})
      {:ok, _} = queue(ctx.card)
      job = Runners.claim(ctx.runner)
      {:ok, _} = Runners.finish(ctx.runner, job.id, %{status: "done"})
      assert heard(ctx.card) == []

      {:ok, gpu, _} = Runners.create_runner(ctx.board, %{"name" => "gpu", "pool" => "gpu"})
      {:ok, _} = queue(ctx.card, "gpu")
      job = Runners.claim(gpu)
      {:ok, _} = Runners.finish(gpu, job.id, %{status: "done"})
      assert [_] = heard(ctx.card)
    end
  end

  describe "a card put back or given up on" do
    setup ctx do
      rule_fixture(ctx.board, %{
        "trigger" => %{"type" => "list_top", "column" => "To Do"},
        "actions" => [%{"type" => "runner", "pool" => "loop", "requeue_stuck" => 1}]
      })

      :ok
    end

    defp end_stuck(ctx, status) do
      job = Runners.claim(ctx.runner)
      :ok = Boards.move_card_to_index(Boards.get_card!(job.card_id), ctx.doing, :top)
      {:ok, _} = Runners.finish(ctx.runner, job.id, %{status: status})
      job
    end

    test "is heard as requeued, then gave_up, once each", ctx do
      listener(ctx.board, %{"outcome" => "requeued, gave_up"})

      first = end_stuck(ctx, "timeout")

      assert heard(ctx.card) == [
               "HEARD job #{first.id} timeout/requeued pool loop exit  on Next up"
             ]

      second = end_stuck(ctx, "failed")
      assert List.last(heard(ctx.card)) =~ "job #{second.id} failed/gave_up"
      assert length(heard(ctx.card)) == 2
    end

    test "the job's own status still matches", ctx do
      listener(ctx.board, %{"outcome" => ["timeout"]})
      end_stuck(ctx, "timeout")
      assert [line] = heard(ctx.card)
      assert line =~ "timeout/requeued"
    end
  end

  describe "a webhook" do
    test "is sent the job beside the card", ctx do
      test = self()

      Req.Test.stub(Slipdock.Automations.Notifier, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test, {:callback, body})
        Plug.Conn.send_resp(conn, 200, "")
      end)

      rule_fixture(ctx.board, %{
        "trigger" => %{"type" => "job_finished"},
        "actions" => [%{"type" => "webhook", "url" => "https://example.com/hooks/jobs"}]
      })

      {:ok, _} = queue(ctx.card)
      job = Runners.claim(ctx.runner)
      {:ok, _} = Runners.finish(ctx.runner, job.id, %{status: "timeout"})

      assert_received {:callback, body}
      payload = Jason.decode!(body)
      assert payload["event"] == "job_finished"
      assert payload["card"]["id"] == ctx.card.id

      assert %{
               "id" => id,
               "status" => "timeout",
               "outcome" => "timeout",
               "recovery" => nil,
               "pool" => "loop",
               "runner" => "box",
               "attempts" => 1
             } = payload["job"]

      assert id == job.id
    end
  end

  describe "the trigger" do
    test "takes outcome as a list or text, and refuses one it doesn't know" do
      assert {:ok, %{"trigger" => %{"outcome" => ["timeout", "gave_up"]}}} =
               Spec.validate(%{
                 "trigger" => %{"type" => "job_finished", "outcome" => "Timeout, gave_up"},
                 "actions" => [%{"type" => "log", "message" => "x"}]
               })

      assert {:error, "trigger “job_finished” outcome “exploded” isn't one of" <> _} =
               Spec.validate(%{
                 "trigger" => %{"type" => "job_finished", "outcome" => ["exploded"]},
                 "actions" => [%{"type" => "log", "message" => "x"}]
               })

      assert {:error, "trigger “job_finished” pool must be" <> _} =
               Spec.validate(%{
                 "trigger" => %{"type" => "job_finished", "pool" => "My Pool!"},
                 "actions" => [%{"type" => "log", "message" => "x"}]
               })
    end

    test "reads back, and is in the vocabulary" do
      spec = %{
        "trigger" => %{
          "type" => "job_finished",
          "pool" => "loop",
          "outcome" => ["timeout", "gave_up"]
        },
        "actions" => [%{"type" => "log", "message" => "x"}]
      }

      assert Spec.summary(spec) =~ "a loop runner job ends timed out or its card given up on"

      assert %{optional: ["outcome", "pool"]} =
               Enum.find(Spec.vocabulary().triggers, &(&1.type == "job_finished"))
    end

    test "card events don't set it off", ctx do
      listener(ctx.board)
      Boards.update_card(ctx.card, %{"title" => "Renamed"})
      :ok = Boards.move_card_to_index(Boards.get_card!(ctx.card.id), ctx.doing, :top)
      assert heard(ctx.card) == []
    end
  end

  describe "the runner_trouble preset" do
    test "alerts on a timeout, a card put back or given up, for one pool or any", ctx do
      assert {:ok, %{"spec" => %{"trigger" => trigger, "actions" => [alert]}}} =
               Presets.build("runner_trouble", %{"pool" => "Loop"}, user: ctx.owner)

      assert trigger == %{
               "type" => "job_finished",
               "pool" => "loop",
               "outcome" => ["timeout", "requeued", "gave_up"]
             }

      assert %{"type" => "alert", "severity" => "warning"} = alert

      assert {:ok, %{"spec" => %{"trigger" => any}}} =
               Presets.build("runner_trouble", %{}, user: ctx.owner)

      refute Map.has_key?(any, "pool")
    end

    test "raises an alert when a job times out", ctx do
      {:ok, _} =
        Automations.create_rule_from_preset(ctx.board, "runner_trouble", %{"pool" => "loop"},
          created_by: ctx.owner
        )

      {:ok, _} = queue(ctx.card)
      job = Runners.claim(ctx.runner)
      {:ok, _} = Runners.finish(ctx.runner, job.id, %{status: "timeout"})

      assert [alert] = Automations.list_alerts(ctx.owner)
      assert alert.title == "Runner job #{job.id} timeout: Next up"
    end

    test "the wizard adds it when asked, and not otherwise", ctx do
      params = %{"scenario" => "loop", "pool" => "loop"}

      {:ok, %{alert_rule: nil}} =
        Setup.connect(ctx.board, params, ctx.owner, "https://slipdock.test")

      {:ok, %{alert_rule: rule}} =
        Setup.connect(
          ctx.board,
          Map.put(params, "alert", "yes"),
          ctx.owner,
          "https://slipdock.test"
        )

      assert rule.spec["trigger"]["type"] == "job_finished"
      assert rule.spec["trigger"]["pool"] == "loop"
    end
  end
end
