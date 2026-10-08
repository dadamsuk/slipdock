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

      assert {:error, "action “runner” prompt is too long"} =
               Spec.validate(spec(%{"type" => "runner", "pool" => "dev", "prompt" => long}))
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
      assert [%Job{kind: "codex", prompt: "Review Ship it"}] = Repo.all(Job)
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

      Boards.move_card(card.id, ctx.doing.id)
      assert [%Job{card_id: card_id, status: "queued"}] = Repo.all(Job)
      assert card_id == card.id
    end
  end
end
