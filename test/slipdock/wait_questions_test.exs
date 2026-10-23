defmodule Slipdock.WaitQuestionsTest do
  @moduledoc """
  Follow-up questions as a series (#1220): a wait asks numbered
  `questions` (given, or split from a numbered `needs`), is answered one
  box per question, can be skipped (closing it and moving the card on as
  an answer would), and the card keeps every wait asked before.
  """
  use Slipdock.DataCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.{Actor, Boards, Repo, Runners}
  alias Slipdock.Boards.Wait
  alias Slipdock.Runners.Job

  setup do
    owner = user_fixture()

    dana =
      "dana@example.com"
      |> user_fixture()
      |> Ecto.Changeset.change(name: "Dana")
      |> Repo.update!()

    board = board_fixture(%{"name" => "Questions"}, owner: owner)
    [_backlog, todo, doing, _done] = board.columns
    {:ok, _} = Slipdock.Access.grant(board, dana, "write", owner)
    card = card_fixture(todo, %{"title" => "Deploy"})
    %{owner: owner, dana: dana, board: board, todo: todo, doing: doing, card: card}
  end

  defp agent(user),
    do: %{Actor.unknown() | kind: "agent", via: "mcp", user_id: user.id, agent: "claude"}

  defp open!(ctx, attrs) do
    {:ok, wait} = Boards.open_wait(ctx.card, agent(ctx.owner), attrs)
    wait
  end

  defp series!(ctx),
    do: open!(ctx, %{"questions" => ["Which region?", " How many seats? ", ""]})

  defp bodies(ctx), do: Boards.get_card!(ctx.card.id).comments |> Enum.map(& &1.body)

  describe "split_questions/1" do
    test "splits a numbered list, keeping the words before it and lines under an item" do
      text = "Before I go on:\n1. Which region?\n   eu or us\n2) How many seats?\n3. Who pays?"

      assert Wait.split_questions(text) ==
               {"Before I go on:", ["Which region?\n   eu or us", "How many seats?", "Who pays?"]}
    end

    test "with nothing before the list there is no intro" do
      assert Wait.split_questions("1. A?\n2. B?") == {nil, ["A?", "B?"]}
    end

    test "leaves alone one item, a list not counting from 1, and plain text" do
      assert Wait.split_questions("1. Only this?") == {nil, []}
      assert Wait.split_questions("2. B?\n3. C?") == {nil, []}
      assert Wait.split_questions("Which region? We said 1. eu before") == {nil, []}
      assert Wait.split_questions(nil) == {nil, []}
    end

    test "a number out of order stays inside the item before it" do
      assert Wait.split_questions("1. A?\n3. not a question\n2. B?") ==
               {nil, ["A?\n3. not a question", "B?"]}
    end
  end

  describe "opening a series" do
    test "questions given are trimmed, blanks dropped, and needs made from them", ctx do
      wait = series!(ctx)

      assert wait.questions == ["Which region?", "How many seats?"]
      assert wait.needs == "2 questions: Which region?"
      assert Wait.series?(wait)
      assert Wait.questions(wait) == ["Which region?", "How many seats?"]
    end

    test "needs given with questions stays as the line in front of them", ctx do
      wait = open!(ctx, %{"needs" => "Before deploying", "questions" => ["A?", "B?"]})
      assert wait.needs == "Before deploying"
      assert wait.questions == ["A?", "B?"]
    end

    test "a numbered needs is asked as a series", ctx do
      wait = open!(ctx, %{"needs" => "Two things:\n1. Which region?\n2. How many seats?"})
      assert wait.needs == "Two things:"
      assert wait.questions == ["Which region?", "How many seats?"]
    end

    test "a plain needs is one question, as before", ctx do
      wait = open!(ctx, %{"needs" => "Which region?"})
      refute Wait.series?(wait)
      assert wait.questions == []
      assert Wait.questions(wait) == ["Which region?"]
    end

    test "the comment on the card numbers the questions", ctx do
      series!(ctx)

      assert "Waiting on anyone: 2 questions: Which region?\n\n1. Which region?\n2. How many seats?" in bodies(
               ctx
             )
    end

    test "too many questions, or one too long, is refused and nothing opens", ctx do
      many = for n <- 1..21, do: "Q#{n}?"

      assert {:error, cs} = Boards.open_wait(ctx.card, agent(ctx.owner), %{"questions" => many})
      assert {"at most %{count}", _} = cs.errors[:questions]

      long = String.duplicate("x", 1001)

      assert {:error, cs} =
               Boards.open_wait(ctx.card, agent(ctx.owner), %{"questions" => ["A?", long]})

      assert {"must each be at most 1000 characters", _} = cs.errors[:questions]
      assert Boards.current_wait(ctx.card) == nil
    end

    test "only blank questions and no needs is refused", ctx do
      assert {:error, cs} =
               Boards.open_wait(ctx.card, agent(ctx.owner), %{"questions" => [" ", ""]})

      assert {"can't be blank: say what you need", _} = cs.errors[:needs]
    end
  end

  describe "answering a series" do
    test "one answer per question, in order, kept and commented as numbered pairs", ctx do
      series!(ctx)

      {:ok, wait} =
        Boards.answer_wait(ctx.card, Actor.web(ctx.dana), %{"answers" => [" eu ", "12"]})

      assert wait.close_reason == "answered"
      assert wait.answers == ["eu", "12"]
      assert wait.answer == nil
      refute "waiting" in Boards.get_card!(ctx.card.id).flags

      assert ("Answered “2 questions: Which region?”:\n\n" <>
                "1. Which region?\n   → eu\n2. How many seats?\n   → 12") in bodies(ctx)
    end

    test "by question number, partly: the rest are left blank and say so", ctx do
      series!(ctx)

      {:ok, wait} =
        Boards.answer_wait(ctx.card, Actor.web(ctx.dana), %{"answers" => %{"2" => "12"}})

      assert wait.answers == ["", "12"]
      assert Wait.answered_text(wait) =~ "1. Which region?\n   → (not answered)"
    end

    test "fewer answers than questions are padded; words for the whole come after", ctx do
      series!(ctx)

      {:ok, wait} =
        Boards.answer_wait(ctx.card, Actor.web(ctx.dana), %{
          "answers" => ["eu"],
          "answer" => "ask me again next week"
        })

      assert wait.answers == ["eu", ""]
      assert String.ends_with?(Wait.answered_text(wait), "\n\nask me again next week")
    end

    test "all blank, too many, a number out of range or a bad shape is refused", ctx do
      series!(ctx)
      dana = Actor.web(ctx.dana)

      assert {:error, "an answer needs text or a choice"} =
               Boards.answer_wait(ctx.card, dana, %{"answers" => ["", " "]})

      assert {:error, "3 answers for 2 questions"} =
               Boards.answer_wait(ctx.card, dana, %{"answers" => ["a", "b", "c"]})

      assert {:error, "answers are numbered 1 to 2, one per question"} =
               Boards.answer_wait(ctx.card, dana, %{"answers" => %{"3" => "x"}})

      assert {:error, "answers is a list of strings, one per question"} =
               Boards.answer_wait(ctx.card, dana, %{"answers" => "eu"})

      assert {:error, "an answer is too long: at most 8000 characters each"} =
               Boards.answer_wait(ctx.card, dana, %{"answers" => [String.duplicate("x", 8001)]})

      assert Wait.open?(Boards.current_wait(ctx.card))
    end

    test "a single question answered through answers is its answer", ctx do
      open!(ctx, %{"needs" => "Which region?"})

      {:ok, wait} = Boards.answer_wait(ctx.card, Actor.web(ctx.dana), %{"answers" => ["eu"]})

      assert wait.answer == "eu"
      assert wait.answers == []
      assert "Answered “Which region?”: eu" in bodies(ctx)
    end
  end

  describe "skipping" do
    test "closes it as skipped, says who, takes the flag off, and keeps no answer", ctx do
      series!(ctx)

      {:ok, wait} = Boards.answer_wait(ctx.card, Actor.web(ctx.dana), %{"skip" => true})

      assert wait.close_reason == "skipped"
      assert wait.closed_by_id == ctx.dana.id
      assert wait.answers == []
      refute "waiting" in Boards.get_card!(ctx.card.id).flags

      assert "Dana skipped the questions “2 questions: Which region?”: carry on without the answers." in bodies(
               ctx
             )
    end

    test "skip as a string from a form or the API works too", ctx do
      open!(ctx, %{"needs" => "Which region?"})

      assert {:ok, %{close_reason: "skipped"}} =
               Boards.answer_wait(ctx.card, Actor.web(ctx.dana), %{"skip" => "true"})
    end

    test "a second skip or answer is told it was skipped, and by whom", ctx do
      series!(ctx)
      {:ok, _} = Boards.answer_wait(ctx.card, Actor.web(ctx.dana), %{"skip" => true})

      assert {:error, message} =
               Boards.answer_wait(ctx.card, Actor.web(ctx.owner), %{"answers" => ["eu"]})

      assert message =~ "was already skipped by Dana"
    end

    test "the agent that asked can't skip its own questions", ctx do
      series!(ctx)

      assert {:error,
              "an agent can't answer the wait it opened itself: a person has to answer it"} =
               Boards.answer_wait(ctx.card, agent(ctx.owner), %{"skip" => true})
    end

    test "a skipped runner job's card goes to its rule again, told to carry on", ctx do
      {:ok, runner, _} = Runners.create_runner(ctx.board, %{"name" => "box", "pool" => "loop"})

      rule =
        rule_fixture(ctx.board, %{
          "trigger" => %{"type" => "list_top", "column" => "To Do"},
          "actions" => [%{"type" => "runner", "pool" => "loop"}]
        })

      job = Runners.claim(runner)
      card = Repo.get!(Boards.Card, job.card_id)
      :ok = Boards.move_card_to_index(card, ctx.doing, :top)

      {:ok, _} =
        Boards.open_wait(card, Actor.runner(ctx.owner, job.id), %{
          "questions" => ["Which region?", "How many seats?"],
          "job_id" => job.id
        })

      {:ok, %Job{status: "parked"}} = Runners.finish(runner, job.id, %{exit: "0", output: "x"})

      {:ok, wait} =
        Boards.answer_wait(Boards.get_card!(card.id), Actor.web(ctx.dana), %{"skip" => true})

      assert wait.requeue_state == "queued"
      fresh = Repo.get!(Job, wait.requeue_job_id)
      assert fresh.rule_id == rule.id
      assert fresh.prompt =~ "Question on card ##{card.id}: 2 questions: Which region?"
      assert fresh.prompt =~ "Answer: (skipped: Dana chose not to answer; use your own judgement)"
    end

    test "an answered series reaches the runner as numbered pairs", ctx do
      {:ok, runner, _} = Runners.create_runner(ctx.board, %{"name" => "box", "pool" => "loop"})

      rule_fixture(ctx.board, %{
        "trigger" => %{"type" => "list_top", "column" => "To Do"},
        "actions" => [%{"type" => "runner", "pool" => "loop"}]
      })

      job = Runners.claim(runner)
      card = Repo.get!(Boards.Card, job.card_id)

      {:ok, _} =
        Boards.open_wait(card, Actor.runner(ctx.owner, job.id), %{
          "questions" => ["Which region?", "How many seats?"],
          "job_id" => job.id
        })

      {:ok, _} = Runners.finish(runner, job.id, %{exit: "0", output: "x"})

      {:ok, wait} =
        Boards.answer_wait(Boards.get_card!(card.id), Actor.web(ctx.dana), %{
          "answers" => ["eu", "12"]
        })

      prompt = Repo.get!(Job, wait.requeue_job_id).prompt

      assert prompt =~
               "Questions on card ##{card.id}: 2 questions: Which region?\nAnswers:\n" <>
                 "1. Which region?\n   → eu\n2. How many seats?\n   → 12\nAnswered by: Dana"
    end
  end

  describe "list_waits/1" do
    test "every wait the card has had, newest first, with who closed it", ctx do
      first = open!(ctx, %{"needs" => "Which region?"})
      {:ok, _} = Boards.answer_wait(ctx.card, Actor.web(ctx.dana), %{"answer" => "eu"})
      second = series!(ctx)

      # Same second: the id breaks the tie.
      Repo.update_all(from(w in Wait, where: w.card_id == ^ctx.card.id),
        set: [inserted_at: ~U[2026-10-01 10:00:00Z]]
      )

      assert [%Wait{id: id2} = open, %Wait{id: id1} = closed] = Boards.list_waits(ctx.card)
      assert {id1, id2} == {first.id, second.id}
      assert Wait.open?(open)
      assert closed.closed_by.id == ctx.dana.id
    end

    test "a card that never asked has none", ctx do
      assert Boards.list_waits(ctx.card) == []
    end
  end
end
