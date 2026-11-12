defmodule Slipdock.HousekeepingEscalationTest do
  @moduledoc """
  A Housekeeping card that grows goes back to Triage (#2780, W-2588 §4): the
  job prompt of a card a Housekeeping feed sent tells the builder to stop,
  move it to Triage with a `product` wait and finish without code; a card
  moved there that way isn't sent again until a person moves it out.
  """
  use Slipdock.DataCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.{Actor, Automations, Boards, Repo, Runners}
  alias Slipdock.Boards.Card
  alias Slipdock.Runners.Job

  setup do
    owner = user_fixture()
    board = board_fixture(%{"name" => "Chores"}, owner: owner)
    [backlog, todo, doing, _done] = board.columns
    {:ok, runner, _} = Runners.create_runner(board, %{"name" => "box", "pool" => "loop"})

    todo_feed =
      rule_fixture(board, %{
        "trigger" => %{"type" => "list_top", "column" => "To Do", "unassigned" => true},
        "actions" => [%{"type" => "runner", "pool" => "loop", "kind" => "claude"}]
      })

    {:ok, housekeeping} = Boards.create_column(board, %{"name" => "Housekeeping"})
    {:ok, triage} = Boards.create_column(board, %{"name" => "Triage", "category" => "triage"})

    [sibling] =
      board.id
      |> Automations.list_rules()
      |> Enum.filter(&(&1.spec["trigger"]["column"] == "Housekeeping"))

    %{
      owner: owner,
      board: board,
      backlog: backlog,
      todo: todo,
      doing: doing,
      housekeeping: housekeeping,
      triage: triage,
      runner: runner,
      todo_feed: todo_feed,
      sibling: sibling
    }
  end

  defp open_cards(rule) do
    from(j in Job,
      where: j.rule_id == ^rule.id and j.status in ^Job.open_statuses(),
      select: j.card_id
    )
    |> Repo.all()
  end

  # A Housekeeping card on a sub-board of an epic on the root board: its
  # own board's id differs from its root's, so `triage_name/1` has to choose.
  defp sub_board_chore(ctx) do
    epic = card_fixture(ctx.backlog, %{"title" => "Epic"})
    {:ok, template} = Boards.find_template(nil, "Simple")
    {:ok, sub} = sub_board(epic, template)
    {:ok, housekeeping} = Boards.create_column(sub, %{"name" => "Housekeeping"})
    card_fixture(housekeeping, %{"title" => "Sub chore"})
  end

  describe "the job prompt" do
    test "a card the Housekeeping feed sent is told to stop and escalate when it grows", ctx do
      chore = card_fixture(ctx.housekeeping, %{"title" => "Chore"})
      job = Runners.claim(ctx.runner)
      assert job.card_id == chore.id
      # The claim moved it into progress; the prompt still knows where it came from.
      assert Repo.get!(Card, chore.id).column_id == ctx.doing.id

      prompt = Runners.claimed_prompt(job)
      assert prompt =~ "This is a Housekeeping card"
      assert prompt =~ "`slipdock move #{chore.id} Triage`"
      assert prompt =~ ~s(`slipdock wait #{chore.id} "…" --kind product`)
      assert prompt =~ "finish without code"
    end

    test "a card queued by hand from a Housekeeping list is told too", ctx do
      Repo.update_all(from(r in Automations.Rule), set: [enabled: false])
      chore = card_fixture(ctx.housekeeping, %{"title" => "Chore"})
      {:ok, job} = Runners.queue(chore, %{pool: "loop", kind: "claude", prompt: "Do it"})
      assert Runners.claimed_prompt(job) =~ "This is a Housekeeping card"
    end

    test "the move names the board's own Triage list", ctx do
      {:ok, _} = Boards.update_column(ctx.triage, %{"name" => "Needs a person"})
      chore = card_fixture(ctx.housekeeping, %{"title" => "Chore"})
      prompt = Runners.claimed_prompt(Runners.claim(ctx.runner))

      assert prompt =~
               ~s[move it to the Needs a person list (`slipdock move #{chore.id} "Needs a person"`)]

      assert prompt =~ "A person moves it out of Needs a person"

      # With no Triage list at all, it says Triage.
      {:ok, _} = Boards.update_column(ctx.triage, %{"category" => ""})
      assert Runners.housekeeping_note(chore.id) =~ "`slipdock move #{chore.id} Triage`"
    end

    test "on a sub-board with no Triage list, the move names its root board's", ctx do
      {:ok, _} = Boards.update_column(ctx.triage, %{"name" => "Root triage"})
      chore = sub_board_chore(ctx)

      assert Runners.housekeeping_note(chore.id) =~
               ~s[move it to the Root triage list (`slipdock move #{chore.id} "Root triage"`)]
    end

    test "on a sub-board with its own Triage list, the move names that one, not its root's",
         ctx do
      {:ok, _} = Boards.update_column(ctx.triage, %{"name" => "Root triage"})
      chore = sub_board_chore(ctx)

      {:ok, _} =
        Boards.create_column(Boards.get_board!(chore.board_id), %{
          "name" => "Epic triage",
          "category" => "triage"
        })

      note = Runners.housekeeping_note(chore.id)

      assert note =~
               ~s[move it to the Epic triage list (`slipdock move #{chore.id} "Epic triage"`)]

      refute note =~ "Root triage"
    end

    test "a To Do card isn't", ctx do
      mine = card_fixture(ctx.todo, %{"title" => "Mine"})
      job = Runners.claim(ctx.runner)
      assert job.card_id == mine.id
      refute Runners.claimed_prompt(job) =~ "Housekeeping card"
    end
  end

  describe "an escalated card" do
    test "isn't sent again until a person moves it out and answers", ctx do
      grown = card_fixture(ctx.housekeeping, %{"title" => "Grew"})
      assert open_cards(ctx.sibling) == [grown.id]
      job = Runners.claim(ctx.runner)
      agent = Actor.runner(ctx.owner, job.id)

      # The builder escalates: into Triage, a product wait, no code.
      :ok = Boards.move_card_to_index(Repo.get!(Card, grown.id), ctx.triage, :top)

      {:ok, _} =
        Boards.open_wait(Repo.get!(Card, grown.id), agent, %{
          "needs" => "It needs a new setting: which default?",
          "kind" => "product"
        })

      {:ok, _} = Runners.finish(ctx.runner, job.id, %{status: "done"})
      other = card_fixture(ctx.housekeeping, %{"title" => "Other chore"})

      # Its feed moves on; Triage is never fed.
      assert open_cards(ctx.sibling) == [other.id]
      Repo.update_all(from(j in Job, where: j.card_id == ^other.id), set: [status: "done"])
      Repo.update_all(from(c in Card, where: c.id == ^other.id), set: [completed: true])
      assert Automations.feed(ctx.sibling) == {:idle, :empty}

      # Moved back while the question is open, it still waits.
      :ok = Boards.move_card_to_index(Repo.get!(Card, grown.id), ctx.housekeeping, :top)
      assert Automations.feed(ctx.sibling) == {:idle, :empty}

      # Answered, it goes.
      {:ok, _} =
        Boards.answer_wait(Repo.get!(Card, grown.id), Actor.web(ctx.owner), %{
          "answer" => "Off by default"
        })

      Repo.update_all(from(j in Job, where: j.card_id == ^grown.id),
        set: [finished_at: DateTime.add(DateTime.utc_now(), -3600)]
      )

      Automations.feed(ctx.sibling)
      assert grown.id in open_cards(ctx.sibling)
    end
  end
end
