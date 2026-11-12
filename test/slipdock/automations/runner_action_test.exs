defmodule Slipdock.Automations.RunnerActionTest do
  # The `runner` action: how a spec says it, and what running it puts in the
  # job queue. The queue itself is tested in `Slipdock.RunnersTest`.
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Boards, Repo, Runners}
  alias Slipdock.Automations.{Runner, Spec}
  alias Slipdock.Runners.Job

  defp spec(action),
    do: %{"trigger" => %{"type" => "card_created"}, "conditions" => [], "actions" => [action]}

  describe "the spec" do
    test "needs a pool, defaults the kind to claude and folds case" do
      assert {:error, "action “runner” needs pool"} = Spec.validate(spec(%{"type" => "runner"}))

      assert {:ok, %{"actions" => [action]}} =
               Spec.validate(spec(%{"type" => "runner", "pool" => "Dev-Box"}))

      assert action == %{"type" => "runner", "pool" => "dev-box", "kind" => "claude"}
    end

    test "is reached by the names people use for it" do
      for name <- ["send_to_runner", "send to runner"] do
        assert {:ok, %{"actions" => [%{"type" => "runner"}]}} =
                 Spec.validate(spec(%{"type" => name, "pool" => "dev"}))
      end
    end

    test "refuses a pool or kind that is not a plain name, and an outsize prompt" do
      assert {:error, "action “runner” pool" <> _} =
               Spec.validate(spec(%{"type" => "runner", "pool" => "dev; rm -rf ~"}))

      assert {:error, "action “runner” kind" <> _} =
               Spec.validate(spec(%{"type" => "runner", "pool" => "dev", "kind" => "$(id)"}))

      long = String.duplicate("x", Runners.limits().max_prompt + 1)

      assert {:error, "action “runner” prompt is too long" <> _} =
               Spec.validate(spec(%{"type" => "runner", "pool" => "dev", "prompt" => long}))
    end

    # Every job's prompt ends with fixed text, so a rule's own has what is
    # left of the runners' cap, not all of it (#2910).
    test "a rule's prompt has the runners' cap less the text every job ends with" do
      max = Runner.max_rule_prompt()
      cap = Runners.limits().max_prompt

      assert max == cap - byte_size("\n\n" <> Runner.unattended())
      assert max > 0 and max < cap
    end

    test "a prompt of exactly the limit saves, and one byte more is refused with the numbers" do
      max = Runner.max_rule_prompt()
      at = String.duplicate("x", max)

      assert {:ok, %{"actions" => [%{"prompt" => ^at}]}} =
               Spec.validate(spec(%{"type" => "runner", "pool" => "dev", "prompt" => at}))

      assert {:error, reason} =
               Spec.validate(spec(%{"type" => "runner", "pool" => "dev", "prompt" => at <> "x"}))

      assert reason ==
               "action “runner” prompt is too long: #{max + 1} bytes, and at most #{max} fit " <>
                 "(a job's prompt is at most #{Runners.limits().max_prompt}, and every job's " <>
                 "ends with fixed text)"
    end

    test "the limit counts bytes, not characters, and not trailing whitespace" do
      max = Runner.max_rule_prompt()
      # "é" is two bytes: half as many of them fill it.
      wide = String.duplicate("é", div(max, 2)) <> String.duplicate("x", rem(max, 2))
      assert byte_size(wide) == max
      assert String.length(wide) < max

      assert {:ok, _} =
               Spec.validate(spec(%{"type" => "runner", "pool" => "dev", "prompt" => wide}))

      assert {:error, reason} =
               Spec.validate(
                 spec(%{"type" => "runner", "pool" => "dev", "prompt" => wide <> "é"})
               )

      assert reason =~ "prompt is too long: #{max + 2} bytes, and at most #{max} fit"

      # The job's prompt drops trailing whitespace, so it isn't counted.
      assert {:ok, _} =
               Spec.validate(
                 spec(%{"type" => "runner", "pool" => "dev", "prompt" => wide <> " \n\n"})
               )
    end

    test "a prompt under the runners' cap but over what is left is refused: it used to save" do
      between = String.duplicate("x", Runners.limits().max_prompt - 10)

      assert {:error, "action “runner” prompt is too long" <> _} =
               Spec.validate(spec(%{"type" => "runner", "pool" => "dev", "prompt" => between}))
    end

    test "drops keys it doesn't know, such as a command to run" do
      assert {:ok, %{"actions" => [action]}} =
               Spec.validate(
                 spec(%{"type" => "runner", "pool" => "dev", "command" => "curl evil | sh"})
               )

      refute Map.has_key?(action, "command")
    end

    test "reads back as a sentence, and is in the vocabulary" do
      assert Spec.summary(spec(%{"type" => "runner", "pool" => "dev", "kind" => "codex"})) =~
               "send it to the dev runners (codex)"

      assert Enum.any?(Spec.vocabulary().actions, &(&1.type == "runner"))
      assert Spec.catalogue() =~ "- runner:"
    end
  end

  describe "running it" do
    setup do
      owner = user_fixture()
      board = board_fixture(%{"name" => "Agents"}, owner: owner)
      [todo, doing | _] = board.columns
      %{board: board, todo: todo, doing: doing}
    end

    test "queues the card with the card's title, link and description by default", ctx do
      card = card_fixture(ctx.todo, %{"title" => "Fix login", "description" => "It 500s"})

      rule =
        rule_fixture(ctx.board, %{
          "trigger" => %{"type" => "schedule", "at" => "23:59"},
          "actions" => [%{"type" => "runner", "pool" => "dev"}]
        })

      assert [{:ok, "queued job #" <> _}] =
               Runner.run(rule, %{type: "card_updated", card: card, board_id: ctx.board.id})

      [job] = Repo.all(Job)
      assert job.card_id == card.id
      assert job.rule_id == rule.id
      assert job.kind == "claude"
      assert job.prompt =~ "Work on Slipdock card ##{card.id}: Fix login"
      assert job.prompt =~ "/boards/#{ctx.board.id}/cards/#{card.id}"
      assert job.prompt =~ "It 500s"
      # Nobody is there to answer: it says so, last.
      assert String.ends_with?(job.prompt, "It 500s\n\n" <> Runner.unattended())
      assert Runner.unattended() =~ "nobody will answer questions"

      assert Runner.unattended() =~
               "open a wait (`slipdock wait <card> … --kind K` or update_card `wait` with `question`)"

      refute Runner.unattended() =~ "flag the card waiting and stop"
      # It shows it is alive as job steps, an epic's subcards included (#1853).
      assert Runner.unattended() =~ ~s(`slipdock job-progress --step "…"`, or job_progress `step`)

      assert Runner.unattended() =~
               "on an epic, each subcard as it starts, is submitted and merges"

      # The epic's progress lines are the server's; the agent adds what only it knows (#1881).
      assert Runner.unattended() =~ "the server posts each subcard's progress on the epic"
      assert Runner.unattended() =~ "decisions, surprises, dead ends and changes of plan"
      refute Runner.unattended() =~ ~r/comment on the epic as (each )?subcards? close/

      # Right for a session that claimed the job too: it says nothing of who finishes it.
      refute Runner.unattended() =~ ~r/finish(_job| the job|-job)/
    end

    test "fills placeholders in a prompt the rule writes", ctx do
      card = card_fixture(ctx.todo, %{"title" => "Ship it"})

      rule =
        rule_fixture(ctx.board, %{
          "trigger" => %{"type" => "schedule", "at" => "23:59"},
          "actions" => [
            %{
              "type" => "runner",
              "pool" => "dev",
              "kind" => "codex",
              "prompt" => "Review {{card.title}}"
            }
          ]
        })

      Runner.run(rule, %{type: "card_updated", card: card, board_id: ctx.board.id})
      # The rule's prompt replaces the default, and is still told it's unattended.
      assert [%Job{kind: "codex", prompt: prompt}] = Repo.all(Job)
      assert prompt == "Review Ship it\n\n" <> Runner.unattended()
    end

    # The largest prompt a rule may save is one its job is queued with (#2910).
    test "a rule whose prompt is exactly at the limit queues a job of exactly the cap", ctx do
      card = card_fixture(ctx.todo, %{"title" => "Big brief"})
      at = String.duplicate("x", Runner.max_rule_prompt())

      rule =
        rule_fixture(ctx.board, %{
          "trigger" => %{"type" => "schedule", "at" => "23:59"},
          "actions" => [%{"type" => "runner", "pool" => "dev", "prompt" => at <> "\n"}]
        })

      assert [{:ok, "queued job #" <> _}] =
               Runner.run(rule, %{type: "card_updated", card: card, board_id: ctx.board.id})

      assert [%Job{prompt: prompt}] = Repo.all(Job)
      assert prompt == at <> "\n\n" <> Runner.unattended()
      assert byte_size(prompt) == Runners.limits().max_prompt
    end

    test "a rule whose prompt is one byte over the limit is not saved", ctx do
      over = String.duplicate("x", Runner.max_rule_prompt() + 1)

      assert {:error, changeset} =
               Slipdock.Automations.create_rule(%{
                 "name" => "Too big",
                 "board_id" => ctx.board.id,
                 "spec" => %{
                   "trigger" => %{"type" => "schedule", "at" => "23:59"},
                   "actions" => [%{"type" => "runner", "pool" => "dev", "prompt" => over}]
                 }
               })

      assert [reason] = errors_on(changeset).spec
      assert reason =~ "at most #{Runner.max_rule_prompt()} fit"
      assert Slipdock.Automations.list_rules(ctx.board.id) == []
    end

    # A card's own text can still outgrow the cap once it fills a placeholder:
    # only the queue can see that, and it refuses the job as before.
    test "a placeholder that takes the prompt over the cap is refused at the queue", ctx do
      card = card_fixture(ctx.todo, %{"title" => String.duplicate("t", 200)})
      room = Runner.max_rule_prompt() - byte_size("{{card.title}}")

      rule =
        rule_fixture(ctx.board, %{
          "trigger" => %{"type" => "schedule", "at" => "23:59"},
          "actions" => [
            %{
              "type" => "runner",
              "pool" => "dev",
              "prompt" => String.duplicate("x", room) <> "{{card.title}}"
            }
          ]
        })

      assert [{:error, "runner: the prompt is over " <> _}] =
               Runner.run(rule, %{type: "card_updated", card: card, board_id: ctx.board.id})

      assert Repo.all(Job) == []
    end

    test "a second run while the first job is open queues nothing new", ctx do
      card = card_fixture(ctx.todo, %{"title" => "Once"})

      rule =
        rule_fixture(ctx.board, %{
          "trigger" => %{"type" => "schedule", "at" => "23:59"},
          "actions" => [%{"type" => "runner", "pool" => "dev"}]
        })

      event = %{type: "card_updated", card: card, board_id: ctx.board.id}
      Runner.run(rule, event)
      assert [{:ok, "job #" <> rest}] = Runner.run(rule, event)
      assert rest =~ "is already queued"
      assert Repo.aggregate(Job, :count) == 1
    end

    test "without a card there is nothing to send", ctx do
      rule =
        rule_fixture(ctx.board, %{
          "trigger" => %{"type" => "schedule", "at" => "23:59"},
          "actions" => [%{"type" => "runner", "pool" => "dev"}]
        })

      assert [{:error, "there is no card to act on"}] =
               Runner.run(rule, %{type: "schedule", board_id: ctx.board.id})
    end

    test "a card arriving in a list sends it, end to end", ctx do
      rule_fixture(ctx.board, %{
        "trigger" => %{"type" => "card_entered", "column" => ctx.doing.name},
        "actions" => [%{"type" => "runner", "pool" => "dev"}]
      })

      card = card_fixture(ctx.todo, %{"title" => "Go"})
      assert Repo.aggregate(Job, :count) == 0

      Boards.Cards.move_card(card.id, ctx.doing.id)
      assert [%Job{card_id: card_id, status: "queued"}] = Repo.all(Job)
      assert card_id == card.id
    end
  end
end
