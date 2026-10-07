defmodule Slipdock.Automations.LimitsTest do
  # What one board owner can make this server send: email only to people who
  # can see the board, so many per hour, rules of a bounded size, callbacks
  # metered per board.
  # Sync: turns rate limiting on, and the counts are one table for the node
  # (RateLimit.reset/0 clears everybody's).
  use Slipdock.DataCase, async: false

  import Slipdock.Fixtures
  import Swoosh.TestAssertions

  alias Slipdock.{Access, Automations}
  alias Slipdock.Automations.{Runner, Spec}

  setup do
    owner = user_fixture()
    board = board_fixture(%{"name" => "Limits"}, owner: owner)
    %{owner: owner, board: board}
  end

  defp email_spec(to, count \\ 1) do
    %{
      "trigger" => %{"type" => "card_created"},
      "actions" => List.duplicate(%{"type" => "email", "to" => to}, count)
    }
  end

  defp add_rule(board, spec),
    do: Automations.create_rule(%{"name" => "R", "spec" => spec, "board_id" => board.id})

  defp with_rate_limit(_ctx) do
    previous = Application.get_env(:slipdock, :rate_limit)
    Application.put_env(:slipdock, :rate_limit, enabled: true)
    Slipdock.RateLimit.reset()

    on_exit(fn ->
      Application.put_env(:slipdock, :rate_limit, previous)
      Slipdock.RateLimit.reset()
    end)
  end

  describe "who an automation may email" do
    test "somebody who can't see the board is refused when the rule is saved", %{board: board} do
      assert {:error, changeset} = add_rule(board, email_spec("stranger@example.com"))
      assert %{spec: [message]} = errors_on(changeset)
      assert message =~ "can only email people who can see this board"
      assert message =~ "stranger@example.com"
      assert Automations.list_rules(board.id) == []
    end

    test "the owner, and people the board is shared with, are fine", %{board: board} = ctx do
      colleague = user_fixture("colleague@example.com")
      share_fixture(board, colleague, "read")

      assert {:ok, _} = add_rule(board, email_spec([ctx.owner.email, "Colleague@Example.com"]))
    end

    test "nor can an existing rule be edited to email a stranger", %{board: board} = ctx do
      {:ok, rule} = add_rule(board, email_spec(ctx.owner.email))

      assert {:error, _} =
               Automations.update_rule(rule, %{"spec" => email_spec("stranger@example.com")})
    end

    test "losing access after the rule was saved stops the email", %{board: board} do
      colleague = user_fixture("colleague@example.com")
      share_fixture(board, colleague, "read")
      {:ok, rule} = add_rule(board, email_spec("colleague@example.com"))

      for grant <- Repo.all(Access.Grant), do: {:ok, _} = Access.revoke(grant)

      assert [{:error, message}] = Runner.run(rule, %{type: "card_created", board_id: board.id})
      assert message =~ "colleague@example.com can't see this board"
      refute_email_sent()
    end
  end

  describe "how big a rule may be" do
    test "too many recipients on one email is refused", %{board: board} do
      to = for n <- 1..(Spec.max_recipients() + 1), do: "p#{n}@example.com"
      assert {:error, changeset} = add_rule(board, email_spec(to))
      assert %{spec: [message]} = errors_on(changeset)
      assert message =~ "at most #{Spec.max_recipients()} addresses"
    end

    test "too many actions in one rule is refused", %{board: board} = ctx do
      assert {:error, changeset} =
               add_rule(board, email_spec(ctx.owner.email, Spec.max_actions() + 1))

      assert %{spec: [message]} = errors_on(changeset)
      assert message =~ "at most #{Spec.max_actions()} actions"
    end

    test "a board holds a bounded number of rules", %{board: board} = ctx do
      for _ <- 1..Automations.max_rules(),
          do: {:ok, _} = add_rule(board, email_spec(ctx.owner.email))

      assert {:error, changeset} = add_rule(board, email_spec(ctx.owner.email))
      assert %{board_id: [message]} = errors_on(changeset)
      assert message =~ "already has #{Automations.max_rules()} automations"
    end
  end

  describe "how much a board may send" do
    setup :with_rate_limit

    test "automation email stops at the owner's hourly allowance", %{board: board} = ctx do
      per_run = Spec.max_actions()
      {:ok, rule} = add_rule(board, email_spec(ctx.owner.email, per_run))
      runs = div(Runner.allowances().emails_per_hour, per_run)
      event = %{type: "card_created", board_id: board.id}

      for _ <- 1..runs do
        assert Enum.all?(Runner.run(rule, event), &match?({:ok, _}, &1))
      end

      assert [{:error, message} | _] = Runner.run(rule, event)
      assert message =~ "email held back"
    end

    test "callbacks stop at the board's per-minute allowance", %{board: board} do
      Req.Test.stub(Slipdock.Automations.Notifier, &Plug.Conn.send_resp(&1, 200, ""))

      per_run = Spec.max_actions()

      {:ok, rule} =
        add_rule(board, %{
          "trigger" => %{"type" => "card_created"},
          "actions" =>
            List.duplicate(%{"type" => "webhook", "url" => "https://example.com/h"}, per_run)
        })

      runs = div(Runner.allowances().callbacks_per_minute, per_run)
      event = %{type: "card_created", board_id: board.id}

      for _ <- 1..runs do
        assert Enum.all?(Runner.run(rule, event), &match?({:ok, _}, &1))
      end

      assert [{:error, message} | _] = Runner.run(rule, event)
      assert message =~ "callback held back"
    end
  end
end
