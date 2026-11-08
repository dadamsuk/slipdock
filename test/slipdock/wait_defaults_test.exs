defmodule Slipdock.WaitDefaultsTest do
  @moduledoc """
  A stall must not outlive its reason (#2096), in the context: any agent may
  withdraw a moot wait, but one it didn't open only with a reason, which
  the comment carries; a wait can propose one of its choices; and a board's
  `wait_default_after` resolves an unanswered approval wait (kind `other`,
  choices, a proposal) to its proposal, saying so on the card and telling
  the person asked, never a product, ux, security or release question, a
  wait with no proposal or the server's own.
  """
  use Slipdock.DataCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures
  import Swoosh.TestAssertions

  alias Slipdock.{Actor, Boards, Repo, WaitDefaults}
  alias Slipdock.Boards.Wait

  setup do
    owner = user_fixture("defaults-owner@example.com")
    dana = user_fixture("defaults-dana@example.com")
    board = board_fixture(%{"name" => "Defaults"}, owner: owner)
    {:ok, _} = Slipdock.Access.grant(board, dana, "write", owner)
    [_backlog, todo, _doing, _done] = board.columns
    card = card_fixture(todo, %{"title" => "Skill copies"})
    %{owner: owner, dana: dana, board: board, todo: todo, card: card}
  end

  defp agent(user, label, job_id \\ nil),
    do: %{
      Actor.unknown()
      | kind: "agent",
        via: "mcp",
        user_id: user.id,
        agent: label,
        job_id: job_id
    }

  defp approval!(ctx, attrs \\ %{}) do
    attrs =
      Map.merge(
        %{
          "needs" => "Read bar 2 as the one copy W-31 settled on?",
          "on_user_id" => ctx.dana.id,
          "question" => "other",
          "choices" => ["Yes", "No"],
          "default_choice" => 1
        },
        attrs
      )

    {:ok, wait} = Boards.open_wait(ctx.card, agent(ctx.owner, "builder"), attrs)
    wait
  end

  defp age!(wait, minutes) do
    at = DateTime.add(DateTime.utc_now(:second), -minutes * 60, :second)
    from(w in Wait, where: w.id == ^wait.id) |> Repo.update_all(set: [inserted_at: at])
  end

  defp set_after!(board, value) do
    {:ok, board} = Boards.update_board(board, %{"wait_default_after" => value})
    board
  end

  defp bodies(ctx), do: Boards.get_card!(ctx.card.id).comments |> Enum.map(& &1.body)
  defp fresh(wait), do: Repo.get!(Wait, wait.id)

  describe "withdrawing a moot wait" do
    test "another agent is refused without a reason, and the wait stays open", ctx do
      wait = approval!(ctx)

      assert {:error, message} = Boards.withdraw_wait(ctx.card, agent(ctx.owner, "verifier"))
      assert message =~ "an agent withdrawing a wait it didn't open says why"
      assert is_nil(fresh(wait).closed_at)

      assert {:error, _} =
               Boards.withdraw_wait(ctx.card, agent(ctx.owner, "verifier"), reason: "  ")

      assert is_nil(fresh(wait).closed_at)
    end

    test "another agent may with a reason, and the comment carries it", ctx do
      wait = approval!(ctx)

      assert {:ok, closed} =
               Boards.withdraw_wait(ctx.card, agent(ctx.owner, "verifier"),
                 reason: "Moot: W-2514 settled it on #2048"
               )

      assert closed.close_reason == "withdrawn"
      assert "waiting" not in Boards.get_card!(ctx.card.id).flags

      assert Enum.any?(
               bodies(ctx),
               &(&1 =~ "withdrew the wait “#{wait.needs}”: Moot: W-2514 settled it on #2048")
             )
    end

    test "an agent of another job is another agent, even on the same token", ctx do
      job_a = runner_job!(ctx)
      job_b = runner_job!(ctx)

      {:ok, _} =
        Boards.open_wait(ctx.card, agent(ctx.owner, "runner-a", job_a.id), %{
          "needs" => "Which region?",
          "job_id" => job_a.id
        })

      assert {:error, _} = Boards.withdraw_wait(ctx.card, agent(ctx.owner, "runner-b", job_b.id))
    end

    test "the agent that opened it, and a person, need no reason", ctx do
      approval!(ctx)
      assert {:ok, _} = Boards.withdraw_wait(ctx.card, agent(ctx.owner, "builder"))

      approval!(ctx)
      assert {:ok, _} = Boards.withdraw_wait(ctx.card, Actor.web(ctx.dana))

      assert Enum.any?(
               bodies(ctx),
               &String.ends_with?(
                 &1,
                 "withdrew the wait “Read bar 2 as the one copy W-31 settled on?”"
               )
             )
    end

    test "a person's own wait, withdrawn by an agent, needs a reason too", ctx do
      {:ok, _} = Boards.open_wait(ctx.card, Actor.web(ctx.dana), %{"needs" => "Which region?"})
      assert {:error, _} = Boards.withdraw_wait(ctx.card, agent(ctx.owner, "builder"))

      assert {:ok, _} =
               Boards.withdraw_wait(ctx.card, agent(ctx.owner, "builder"),
                 reason: "Answered in the description"
               )
    end

    test "a reason over 2000 characters is refused", ctx do
      approval!(ctx)

      assert {:error, "the reason is too long" <> _} =
               Boards.withdraw_wait(ctx.card, agent(ctx.owner, "verifier"),
                 reason: String.duplicate("x", 2001)
               )
    end
  end

  describe "a proposed choice" do
    test "is kept, and is one of the choices", ctx do
      wait = approval!(ctx, %{"default_choice" => 2})
      assert wait.default_choice == 2
      assert Wait.approval?(wait)
    end

    test "out of range, or with no choices, is refused", ctx do
      assert {:error, cs} =
               Boards.open_wait(ctx.card, agent(ctx.owner, "builder"), %{
                 "needs" => "Which?",
                 "choices" => ["a", "b"],
                 "default_choice" => 3
               })

      assert %{default_choice: ["must be a choice's number, 1 to 2"]} = errors_on(cs)

      assert {:error, cs} =
               Boards.open_wait(ctx.card, agent(ctx.owner, "builder"), %{
                 "needs" => "Which?",
                 "default_choice" => 1
               })

      assert %{default_choice: ["needs choices: propose one of them by number"]} = errors_on(cs)
    end

    test "only an other question with choices and a proposal is an approval", ctx do
      refute Wait.approval?(%Wait{question: "product", choices: ["a"], default_choice: 1})
      refute Wait.approval?(%Wait{question: "other", choices: ["a"], default_choice: nil})
      refute Wait.approval?(%Wait{question: "other", choices: [], default_choice: 1})

      refute Wait.approval?(%Wait{
               question: "other",
               choices: ["a"],
               default_choice: 1,
               purpose: "verify_limit"
             })

      assert Wait.approval?(approval!(ctx))
    end
  end

  describe "the board's wait_default_after" do
    test "is off by default, and takes 4h, 90m, 2d, minutes or off", ctx do
      assert ctx.board.wait_default_after == nil
      assert set_after!(ctx.board, "4h").wait_default_after == 240
      assert set_after!(ctx.board, "90m").wait_default_after == 90
      assert set_after!(ctx.board, "2d").wait_default_after == 2880
      assert set_after!(ctx.board, 45).wait_default_after == 45
      assert set_after!(ctx.board, "off").wait_default_after == nil
      assert set_after!(ctx.board, "").wait_default_after == nil
    end

    test "refuses what isn't a time, and past 30 days", ctx do
      for bad <- ["soon", "4 weeks", "31d", -5] do
        assert {:error, cs} = Boards.update_board(ctx.board, %{"wait_default_after" => bad})

        assert %{wait_default_after: ["must be a time like 4h, 90m or 2d (at most 30d), or off"]} =
                 errors_on(cs),
               inspect(bad)
      end
    end

    test "reads back as the shortest text" do
      assert WaitDefaults.format(nil) == nil
      assert WaitDefaults.format(240) == "4h"
      assert WaitDefaults.format(90) == "90m"
      assert WaitDefaults.format(2880) == "2d"
      assert WaitDefaults.parse("4 hours") == {:ok, 240}
      assert WaitDefaults.parse(:soon) == :error
    end

    test "a sub-board without one takes the nearest board's above it", ctx do
      set_after!(ctx.board, "4h")
      {:ok, t} = Boards.find_template(nil, "Simple")
      {:ok, parent} = sub_board(ctx.card, t)
      [sub_todo | _] = Boards.get_board!(parent.id).columns
      sub_card = card_fixture(sub_todo, %{"title" => "Sub"})
      assert WaitDefaults.after_minutes(sub_card) == 240

      set_after!(Boards.get_board!(parent.id), "30m")
      assert WaitDefaults.after_minutes(sub_card) == 30
    end
  end

  describe "tick/1" do
    test "an approval past its time resolves to its proposal, says so and tells the person",
         ctx do
      set_after!(ctx.board, "4h")
      wait = approval!(ctx)
      age!(wait, 241)

      # The email it opened with, first.
      assert_email_sent(fn email -> assert email.subject =~ "is waiting on you" end)
      assert WaitDefaults.tick() == 1

      closed = fresh(wait)
      assert closed.close_reason == "answered"
      assert closed.choice == 1
      assert "waiting" not in Boards.get_card!(ctx.card.id).flags

      assert Enum.any?(
               bodies(ctx),
               &(&1 =~ "No answer after 4h, so the proposal stands: “Yes”")
             )

      assert_email_sent(fn email ->
        assert email.to == [{"", ctx.dana.email}]
        assert email.subject == "The proposal stood on “Skill copies”: Yes"
        assert email.text_body =~ "within 4h, so its proposal stands: Yes"
      end)

      # Once only.
      assert WaitDefaults.tick() == 0
    end

    test "a wait on anyone tells the board's owner", ctx do
      set_after!(ctx.board, "1h")
      wait = approval!(ctx, %{"on_user_id" => nil})
      age!(wait, 61)

      # An agent's question on anyone tells its token holder as it opens
      # (#2095): that email first.
      assert_email_sent(fn email -> assert email.subject =~ "is waiting on you" end)
      assert WaitDefaults.tick() == 1

      assert_email_sent(fn email ->
        assert email.to == [{"", ctx.owner.email}]
        assert email.subject =~ "The proposal stood"
      end)
    end

    test "not before its time", ctx do
      set_after!(ctx.board, "4h")
      wait = approval!(ctx)
      age!(wait, 239)

      assert WaitDefaults.tick() == 0
      assert is_nil(fresh(wait).closed_at)
    end

    test "never while the board has it off", ctx do
      wait = approval!(ctx)
      age!(wait, 60 * 24 * 40)

      assert WaitDefaults.tick() == 0
      assert is_nil(fresh(wait).closed_at)
    end

    test "never a product, ux, security or release question", ctx do
      set_after!(ctx.board, "1h")

      for kind <- ~w(product ux security release) do
        wait = approval!(ctx, %{"question" => kind, "on_user_id" => ctx.dana.id})
        age!(wait, 120)
        assert WaitDefaults.tick() == 0
        assert is_nil(fresh(wait).closed_at), kind
        {:ok, _} = Boards.withdraw_wait(ctx.card, Actor.web(ctx.owner))
      end
    end

    test "never a wait with no proposal, or with no choices", ctx do
      set_after!(ctx.board, "1h")

      wait = approval!(ctx, %{"default_choice" => nil})
      age!(wait, 120)
      assert WaitDefaults.tick() == 0
      assert is_nil(fresh(wait).closed_at)
      {:ok, _} = Boards.withdraw_wait(ctx.card, Actor.web(ctx.owner))

      {:ok, plain} =
        Boards.open_wait(ctx.card, agent(ctx.owner, "builder"), %{"needs" => "Which region?"})

      age!(plain, 120)
      assert WaitDefaults.tick() == 0
      assert is_nil(fresh(plain).closed_at)
    end

    test "never the server's own waits", ctx do
      set_after!(ctx.board, "1h")
      wait = approval!(ctx)
      from(w in Wait, where: w.id == ^wait.id) |> Repo.update_all(set: [purpose: "verify_limit"])
      age!(wait, 120)

      assert WaitDefaults.tick() == 0
      assert {:error, _} = Boards.default_wait(fresh(wait), "1h")
    end

    test "the scheduler runs it" do
      assert Enum.any?(Slipdock.Automations.Scheduler.jobs(), &(elem(&1, 0) == "Wait defaults"))
    end
  end

  test "the setting is listed with the board's agentic rules", ctx do
    board = %{ctx.board | wait_default_after: 240}
    assert "Approval waits default" in Slipdock.AgenticBuilding.live_rules(board)
    refute "Approval waits default" in Slipdock.AgenticBuilding.live_rules(ctx.board)
  end

  defp runner_job!(ctx), do: working_job_fixture(ctx.card)
end
