defmodule Slipdock.WaitsTest do
  @moduledoc """
  Waiting on a person (#1114), in the context: opening a wait flags the card
  and asks on it, answering and withdrawing close it once and take off only
  the flag it put on, an agent can't answer its own question, and finishing,
  archiving or deleting the card closes or removes it.
  """
  use Slipdock.DataCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.{Actor, Boards, Repo, Runners}
  alias Slipdock.Boards.Wait

  setup do
    owner = user_fixture()

    dana =
      "dana@example.com"
      |> user_fixture()
      |> Ecto.Changeset.change(name: "Dana")
      |> Repo.update!()

    board = board_fixture(%{"name" => "Waits"}, owner: owner)
    [_backlog, todo, doing, done] = board.columns
    {:ok, _} = Slipdock.Access.grant(board, dana, "write", owner)
    card = card_fixture(todo, %{"title" => "Deploy"})
    %{owner: owner, dana: dana, board: board, todo: todo, doing: doing, done: done, card: card}
  end

  defp agent(user, label \\ "claude", job_id \\ nil),
    do: %{
      Actor.unknown()
      | kind: "agent",
        via: "mcp",
        user_id: user.id,
        agent: label,
        job_id: job_id
    }

  defp open!(ctx, attrs \\ %{}, actor \\ nil) do
    attrs = Map.merge(%{"needs" => "Which region?", "on_user_id" => ctx.dana.id}, attrs)
    {:ok, wait} = Boards.open_wait(ctx.card, actor || agent(ctx.owner), attrs)
    wait
  end

  defp card(ctx), do: Boards.get_card!(ctx.card.id)
  defp bodies(ctx), do: ctx |> card() |> Map.get(:comments) |> Enum.map(& &1.body)

  describe "open_wait/3" do
    test "flags the card waiting, keeps who asked and how, and asks on the card", ctx do
      wait = open!(ctx, %{"choices" => ["eu", " us ", ""]})

      assert wait.needs == "Which region?"
      assert wait.choices == ["eu", "us"]
      assert wait.on_user_id == ctx.dana.id
      assert wait.opened_by_id == ctx.owner.id
      assert {wait.kind, wait.via, wait.agent} == {"agent", "mcp", "claude"}
      assert wait.set_flag
      assert "waiting" in card(ctx).flags

      assert [body] = bodies(ctx)
      assert body == "Waiting on Dana: Which region?\n1. eu\n2. us"
      assert Boards.current_wait(ctx.card).id == wait.id
      assert Boards.get_card!(ctx.card.id).wait.id == wait.id
    end

    test "on nobody in particular, it waits on anyone", ctx do
      open!(ctx, %{"on_user_id" => nil})
      assert bodies(ctx) == ["Waiting on anyone: Which region?"]
    end

    test "opening fires the rules on the waiting flag", ctx do
      rule_fixture(ctx.board, %{
        "trigger" => %{"type" => "flag_added", "flag" => "waiting"},
        "conditions" => [],
        "actions" => [%{"type" => "comment", "body" => "Rule saw the flag"}]
      })

      open!(ctx)
      assert "Rule saw the flag" in bodies(ctx)
    end

    test "a second open is refused, naming the one that is open", ctx do
      open!(ctx)

      assert {:error, message} =
               Boards.open_wait(ctx.card, agent(ctx.owner), %{"needs" => "And the size?"})

      assert message =~ "already has an open wait: “Which region?”"
      assert message =~ "on Dana"
      assert Repo.aggregate(Wait, :count) == 1
    end

    test "a blank question is refused and nothing changes", ctx do
      assert {:error, %Ecto.Changeset{} = cs} =
               Boards.open_wait(ctx.card, agent(ctx.owner), %{"needs" => "  "})

      assert {"can't be blank: say what you need", _} = cs.errors[:needs]
      refute "waiting" in card(ctx).flags
      assert bodies(ctx) == []
    end

    test "on a card already flagged waiting it doesn't claim the flag", ctx do
      {:ok, _} = Boards.update_card(ctx.card, %{"flags" => ["waiting"]})
      refute open!(ctx).set_flag
    end
  end

  describe "linking a runner job" do
    setup ctx do
      {:ok, runner, _token} =
        Runners.create_runner(ctx.board, %{"name" => "box", "pool" => "dev"})

      %{runner: runner}
    end

    defp job_on(ctx, card) do
      {:ok, job} = Runners.queue(card, %{pool: "dev", kind: "claude", prompt: "do it"})
      %Runners.Job{} = Runners.claim(ctx.runner)
      Repo.get!(Runners.Job, job.id)
    end

    test "a claimed job on the card is kept on the wait", ctx do
      job = job_on(ctx, ctx.card)
      assert open!(ctx, %{"job_id" => job.id}).job_id == job.id
    end

    test "another card's job, or a finished one, refuses the open and is left alone", ctx do
      other = card_fixture(ctx.todo, %{"title" => "Other"})
      job = job_on(ctx, other)

      assert {:error, "job ##{job.id} is working on another card, not ##{ctx.card.id}"} ==
               Boards.open_wait(ctx.card, agent(ctx.owner), %{
                 "needs" => "Which region?",
                 "job_id" => job.id
               })

      {:ok, _} = Runners.finish(ctx.runner, job.id, %{exit: "0"})
      finished = Repo.get!(Runners.Job, job.id)

      assert {:error, "job ##{job.id} is done: only a claimed or running job can wait"} ==
               Boards.open_wait(other, agent(ctx.owner), %{
                 "needs" => "Which region?",
                 "job_id" => job.id
               })

      assert Repo.get!(Runners.Job, job.id) == finished
      assert Repo.aggregate(Wait, :count) == 0
      refute "waiting" in card(ctx).flags
    end

    test "a job that doesn't exist is refused", ctx do
      assert {:error, "no job #999999"} =
               Boards.open_wait(ctx.card, agent(ctx.owner), %{
                 "needs" => "Which region?",
                 "job_id" => 999_999
               })
    end
  end

  describe "answer_wait/3" do
    test "Dana's answer in words closes it, is hers on the card, and clears the flag", ctx do
      open!(ctx)

      assert {:ok, wait} =
               Boards.answer_wait(ctx.card, Actor.web(ctx.dana), %{"answer" => "eu-west"})

      assert wait.close_reason == "answered"
      assert wait.closed_by_id == ctx.dana.id
      assert wait.answer == "eu-west"
      refute Wait.open?(wait)
      refute "waiting" in card(ctx).flags
      assert Boards.current_wait(ctx.card) == nil
      assert Boards.last_wait(ctx.card).id == wait.id

      answer = Enum.find(card(ctx).comments, &(&1.body =~ "Answered"))
      assert answer.body == "Answered “Which region?”: eu-west"
      assert answer.user_id == ctx.dana.id
    end

    test "a flag that was there before the wait stays after the answer", ctx do
      {:ok, _} = Boards.update_card(ctx.card, %{"flags" => ["waiting"]})
      open!(ctx)
      {:ok, _} = Boards.answer_wait(ctx.card, Actor.web(ctx.dana), %{"answer" => "eu"})
      assert "waiting" in card(ctx).flags
    end

    test "a choice is kept and its text commented; words may come with it", ctx do
      open!(ctx, %{"choices" => ["eu", "us"]})

      assert {:ok, wait} =
               Boards.answer_wait(ctx.card, Actor.web(ctx.dana), %{
                 "choice" => "2",
                 "answer" => "but only for now"
               })

      assert {wait.choice, wait.answer} == {2, "but only for now"}
      assert "Answered “Which region?”: us — but only for now" in bodies(ctx)
    end

    test "a choice out of range, a choice on a wait with none, or no answer at all is refused",
         ctx do
      open!(ctx, %{"choices" => ["eu", "us"]})
      dana = Actor.web(ctx.dana)

      assert {:error, "choice must be a number from 1 to 2"} =
               Boards.answer_wait(ctx.card, dana, %{"choice" => 3})

      assert {:error, "an answer needs text or a choice"} =
               Boards.answer_wait(ctx.card, dana, %{"answer" => " "})

      other = card_fixture(ctx.todo)
      {:ok, _} = Boards.open_wait(other, dana, %{"needs" => "Size?"})

      assert {:error, "the wait “Size?” has no choices: answer in words"} =
               Boards.answer_wait(other, dana, %{"choice" => 1})

      assert Wait.open?(Boards.current_wait(ctx.card))
    end

    test "of two answers racing, the second is told who answered first and when", ctx do
      wait = open!(ctx)
      {:ok, _} = Boards.answer_wait(wait, Actor.web(ctx.dana), %{"answer" => "eu"})

      assert {:error, message} =
               Boards.answer_wait(wait, Actor.web(ctx.owner), %{"answer" => "us"})

      assert message =~ ~r/^the wait “Which region\?” was already answered by Dana at \d{4}-/
      assert Boards.last_wait(ctx.card).answer == "eu"

      assert {:error, ^message} =
               Boards.answer_wait(ctx.card, Actor.web(ctx.owner), %{"answer" => "us"})
    end

    test "an agent can't answer the wait it opened, by token or by job", ctx do
      open!(ctx)

      assert {:error, "an agent can't answer the wait it opened itself" <> _} =
               Boards.answer_wait(ctx.card, agent(ctx.owner), %{"answer" => "eu"})

      assert Wait.open?(Boards.current_wait(ctx.card))
    end

    test "the same person on the same token, as a person, can answer it", ctx do
      open!(ctx)
      person = %{agent(ctx.owner) | kind: "human", via: "cli"}

      assert {:ok, %{close_reason: "answered"}} =
               Boards.answer_wait(ctx.card, person, %{"answer" => "eu"})
    end

    test "another agent may answer, and a person may answer their own question", ctx do
      open!(ctx)

      assert {:ok, _} =
               Boards.answer_wait(ctx.card, agent(ctx.owner, "other-token"), %{"answer" => "eu"})

      {:ok, _} = Boards.open_wait(ctx.card, Actor.web(ctx.owner), %{"needs" => "Size?"})
      assert {:ok, _} = Boards.answer_wait(ctx.card, Actor.web(ctx.owner), %{"answer" => "L"})
    end

    test "with no wait ever opened it says there is none", ctx do
      assert {:error, "card ##{ctx.card.id} has no open wait"} ==
               Boards.answer_wait(ctx.card, Actor.web(ctx.dana), %{"answer" => "eu"})
    end
  end

  describe "closing without an answer" do
    test "withdraw_wait closes it as withdrawn, says who, and takes the flag off", ctx do
      open!(ctx)
      assert {:ok, wait} = Boards.withdraw_wait(ctx.card, Actor.web(ctx.owner))
      assert wait.close_reason == "withdrawn"
      refute "waiting" in card(ctx).flags
      assert "#{ctx.owner.email} withdrew the wait “Which region?”" in bodies(ctx)

      assert {:error, "card ##{ctx.card.id} has no open wait"} ==
               Boards.withdraw_wait(ctx.card, Actor.web(ctx.owner))
    end

    test "taking the waiting flag off by hand withdraws it, naming who (AE4)", ctx do
      open!(ctx)

      {:ok, _} =
        Boards.toggle_flag(card(ctx), "waiting", by: ctx.dana, actor: Actor.web(ctx.dana))

      assert %{close_reason: "withdrawn", closed_by_id: closed_by} = Boards.last_wait(ctx.card)
      assert closed_by == ctx.dana.id

      assert "Dana took the waiting flag off, which withdrew the wait “Which region?”" in bodies(
               ctx
             )

      refute "waiting" in card(ctx).flags
    end

    test "ticking the card done closes it as card_completed", ctx do
      open!(ctx)
      {:ok, _} = Boards.toggle_completed(card(ctx))

      assert %{close_reason: "card_completed"} = Boards.last_wait(ctx.card)
      assert "Wait “Which region?” closed: the card was completed." in bodies(ctx)
      refute "waiting" in card(ctx).flags
    end

    test "moving the card into a done list closes it as card_completed", ctx do
      open!(ctx)
      :ok = Boards.move_card(ctx.card.id, ctx.done.id)
      assert %{close_reason: "card_completed"} = Boards.last_wait(ctx.card)
      assert Boards.current_wait(ctx.card) == nil
    end

    test "archiving closes it as archived, and restoring doesn't reopen it", ctx do
      open!(ctx)
      {:ok, archived} = Boards.archive_card(card(ctx))
      assert %{close_reason: "archived"} = Boards.last_wait(ctx.card)
      assert "Wait “Which region?” closed: the card was archived." in bodies(ctx)

      {:ok, _} = Boards.unarchive_card(archived)
      assert Boards.current_wait(ctx.card) == nil
      assert Boards.last_wait(ctx.card).close_reason == "archived"
    end

    test "deleting the card takes its waits with it", ctx do
      open!(ctx)
      {:ok, _} = Boards.delete_card(card(ctx))
      assert Repo.aggregate(Wait, :count) == 0
    end

    test "a card with no wait is changed as ever: no comment, no wait", ctx do
      {:ok, _} = Boards.toggle_flag(card(ctx), "waiting")
      {:ok, _} = Boards.toggle_flag(card(ctx), "waiting")
      {:ok, _} = Boards.toggle_completed(card(ctx))
      assert bodies(ctx) == []
      assert Boards.last_wait(ctx.card) == nil
    end
  end

  describe "reading them" do
    test "current_waits/1 and last_waits/1 batch by card, wait_count counts them all", ctx do
      other = card_fixture(ctx.todo)
      open!(ctx)
      {:ok, _} = Boards.withdraw_wait(ctx.card, Actor.web(ctx.owner))
      w2 = open!(ctx, %{"needs" => "Size?"})
      {:ok, w3} = Boards.open_wait(other, Actor.web(ctx.owner), %{"needs" => "Colour?"})

      assert Boards.current_waits([ctx.card.id, other.id]) |> Map.new(fn {k, v} -> {k, v.id} end) ==
               %{ctx.card.id => w2.id, other.id => w3.id}

      assert %{} == Boards.last_waits([other.id])
      assert Boards.last_waits([ctx.card.id])[ctx.card.id].needs == "Which region?"
      assert Boards.wait_count(ctx.card) == 2
      assert Boards.current_waits([]) == %{}
    end
  end

  describe "export and import" do
    test "carry open and closed waits, with no job on the way in", ctx do
      {:ok, runner, _} = Runners.create_runner(ctx.board, %{"name" => "box", "pool" => "dev"})
      {:ok, job} = Runners.queue(ctx.card, %{pool: "dev", kind: "claude", prompt: "do it"})
      %Runners.Job{} = Runners.claim(runner)

      open!(ctx, %{"choices" => ["eu", "us"]})
      {:ok, _} = Boards.answer_wait(ctx.card, Actor.web(ctx.dana), %{"choice" => 1})
      open!(ctx, %{"needs" => "Size?", "job_id" => job.id, "on_user_id" => ctx.owner.id})

      document = ctx.owner |> Slipdock.Portable.export(boards: [ctx.board]) |> Jason.encode!()
      receiver = user_fixture("receiver@example.com")
      {:ok, report} = Slipdock.Portable.import(receiver, document)

      [card] =
        report.boards
        |> hd()
        |> Map.fetch!(:id)
        |> Boards.get_board!()
        |> Boards.list_cards(%{})
        |> Enum.filter(&(&1.title == "Deploy"))

      waits = Repo.all(from(w in Wait, where: w.card_id == ^card.id, order_by: w.id))

      assert [
               %Wait{
                 needs: "Which region?",
                 close_reason: "answered",
                 choice: 1,
                 choices: ["eu", "us"]
               },
               %Wait{needs: "Size?", closed_at: nil, kind: "agent", set_flag: true}
             ] = waits

      assert Enum.all?(waits, &is_nil(&1.job_id))
      # Only the importer can be named on an imported card: nobody else is.
      assert Enum.all?(waits, &(&1.on_user_id in [nil, receiver.id]))
      assert Boards.current_wait(card).needs == "Size?"
      assert "waiting" in card.flags
    end
  end
end
