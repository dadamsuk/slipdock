defmodule Slipdock.HousekeepingListTest do
  @moduledoc """
  The Housekeeping list (#2777): a list category, `housekeeping`, where the
  fixes and investigations generators file wait. Each ready-list feed gets a
  backfill sibling on it, made like the Scheduled list's, which sends a card
  only while its pool's ready-list and Scheduled feeds have nothing they
  could start: To Do, then Scheduled, then Housekeeping.
  """
  use Slipdock.DataCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.{Automations, Boards, Repo, Runners}
  alias Slipdock.Automations.{ScheduledFeed, Spec}
  alias Slipdock.Boards.{Card, Column}
  alias Slipdock.Runners.Job
  alias SlipdockWeb.APIGuide

  setup do
    owner = user_fixture()
    board = board_fixture(%{"name" => "Chores"}, owner: owner)
    [backlog, todo, doing, done] = board.columns
    {:ok, runner, _} = Runners.create_runner(board, %{"name" => "box", "pool" => "loop"})

    %{
      owner: owner,
      board: board,
      backlog: backlog,
      todo: todo,
      doing: doing,
      done: done,
      runner: runner
    }
  end

  defp housekeeping(board) do
    {:ok, col} = Boards.Columns.create_column(board, %{"name" => "Housekeeping"})
    col
  end

  defp scheduled(board) do
    {:ok, col} =
      Boards.Columns.create_column(board, %{"name" => "Scheduled", "category" => "scheduled"})

    col
  end

  defp feed(board, column, pool \\ "loop") do
    rule_fixture(board, %{
      "trigger" => %{"type" => "list_top", "column" => column, "unassigned" => true},
      "actions" => [%{"type" => "runner", "pool" => pool, "kind" => "claude"}]
    })
  end

  defp feeds_on(board, column) do
    board.id
    |> Automations.list_rules()
    |> Enum.filter(
      &(&1.spec["trigger"]["type"] == "list_top" and &1.spec["trigger"]["column"] == column)
    )
  end

  defp open_cards(rule) do
    from(j in Job,
      where: j.rule_id == ^rule.id and j.status in ^Job.open_statuses(),
      select: j.card_id
    )
    |> Repo.all()
  end

  # A To Do feed and a Housekeeping list with its backfill sibling.
  defp backfilled(ctx) do
    todo_feed = feed(ctx.board, "To Do")
    col = housekeeping(ctx.board)
    [sibling] = feeds_on(ctx.board, "Housekeeping")
    %{todo_feed: todo_feed, housekeeping: col, sibling: sibling}
  end

  describe "the category" do
    test "is one of the list categories, after scheduled" do
      assert "housekeeping" in Column.category_keys()
      assert List.last(Column.categories()) == {"housekeeping", "Housekeeping"}
      assert Column.housekeeping?(%Column{category: "housekeeping"})
      refute Column.housekeeping?(%Column{category: "triage"})
    end

    test "a new list called Housekeeping takes it; one given a category keeps that", ctx do
      assert housekeeping(ctx.board).category == "housekeeping"

      {:ok, col} = Boards.Columns.create_column(ctx.board, %{"name" => " housekeeping "})
      assert col.category == "housekeeping"

      {:ok, col} =
        Boards.Columns.create_column(ctx.board, %{
          "name" => "Housekeeping",
          "category" => "triage"
        })

      assert col.category == "triage"

      {:ok, col} = Boards.Columns.create_column(ctx.board, %{"name" => "Chores"})
      assert col.category == nil

      # A form sends a blank category for none.
      {:ok, col} =
        Boards.Columns.create_column(ctx.board, %{"name" => "Housekeeping", "category" => ""})

      assert col.category == "housekeeping"
    end

    test "the guide never reads it as the ready list, names it, and says who works it", ctx do
      col = housekeeping(ctx.board)
      columns = Repo.all(from(c in Column, where: c.board_id == ^ctx.board.id))

      assert APIGuide.role(columns, col) == nil
      roles = APIGuide.list_roles(columns)
      assert roles.housekeeping.id == col.id
      assert roles.ready.id == ctx.todo.id

      # On a board with no other categories it doesn't turn the rest off.
      bare = [%Column{name: "Ideas"}, %Column{name: "Housekeeping", category: "housekeeping"}]
      assert APIGuide.role(bare, hd(bare)) == "todo"

      guide = APIGuide.markdown(user: ctx.owner)

      assert guide =~
               "housekeeping: worked by runners after the ready list; pick from it only when " <>
                 "the ready list has nothing"

      assert guide =~ "**A Housekeeping list comes last.**"
      # The short guide is at its cap: its board lines mark the list.
      refute APIGuide.short(user: ctx.owner) =~ "A Housekeeping list comes last"
      assert APIGuide.short(user: ctx.owner) =~ "housekeeping: worked by runners"
    end
  end

  describe "its feeds" do
    test "a new Housekeeping list gets a backfill sibling of each ready-list feed", ctx do
      feed(ctx.board, "To Do", "loop")
      feed(ctx.board, "To Do", "BigWhite")
      feed(ctx.board, "Backlog", "spare")

      housekeeping(ctx.board)
      siblings = feeds_on(ctx.board, "Housekeeping")

      assert siblings |> Enum.map(& &1.name) |> Enum.sort() == [
               "Work Housekeeping with the bigwhite runners",
               "Work Housekeeping with the loop runners"
             ]

      assert Enum.all?(siblings, &(&1.spec["trigger"]["backfill"] == true))
      assert Enum.all?(siblings, &(&1.spec["trigger"]["unassigned"] == true))
      assert {:ok, []} = ScheduledFeed.ensure(ctx.board)
    end

    test "a list given the category later gets them; Scheduled's siblings don't backfill",
         ctx do
      feed(ctx.board, "To Do")
      scheduled(ctx.board)
      {:ok, col} = Boards.Columns.create_column(ctx.board, %{"name" => "Chores"})
      assert feeds_on(ctx.board, "Chores") == []

      {:ok, _} = Boards.Columns.update_column(col, %{"category" => "housekeeping"})

      assert [%{spec: %{"trigger" => %{"backfill" => true}}}] = feeds_on(ctx.board, "Chores")
      assert [scheduled] = feeds_on(ctx.board, "Scheduled")
      refute Map.has_key?(scheduled.spec["trigger"], "backfill")
    end

    test "a backfill flag on a ready-list feed isn't copied to its Scheduled sibling", ctx do
      rule_fixture(ctx.board, %{
        "trigger" => %{"type" => "list_top", "column" => "To Do", "backfill" => true},
        "actions" => [%{"type" => "runner", "pool" => "loop"}]
      })

      scheduled(ctx.board)
      housekeeping(ctx.board)

      assert [scheduled] = feeds_on(ctx.board, "Scheduled")
      refute Map.has_key?(scheduled.spec["trigger"], "backfill")

      assert [%{spec: %{"trigger" => %{"backfill" => true}}}] =
               feeds_on(ctx.board, "Housekeeping")
    end

    test "two backfill feeds on the ready list for one pool don't wait on each other", ctx do
      first = card_fixture(ctx.todo, %{"title" => "One"})
      second = card_fixture(ctx.todo, %{"title" => "Two"})

      spec = %{
        "trigger" => %{"type" => "list_top", "column" => "To Do", "backfill" => true},
        "actions" => [%{"type" => "runner", "pool" => "loop"}]
      }

      a = rule_fixture(ctx.board, spec)
      b = rule_fixture(ctx.board, spec)

      assert open_cards(a) == [first.id]
      assert open_cards(b) == [second.id]
    end

    test "setting up a runner on the ready list adds the Housekeeping sibling too", ctx do
      housekeeping(ctx.board)
      params = %{"scenario" => "loop", "pool" => "loop", "column" => "To Do", "feed" => "top"}

      assert {:ok, %{rule: _}} =
               Runners.Setup.connect(ctx.board, params, ctx.owner, "https://slipdock.test")

      assert [sibling] = feeds_on(ctx.board, "Housekeeping")
      assert sibling.spec["trigger"]["backfill"] == true
    end
  end

  describe "the backfill option" do
    test "is a list_top flag, from a form's string too, and reads back as yielding" do
      spec = %{
        "trigger" => %{"type" => "list_top", "column" => "Housekeeping", "backfill" => "true"},
        "actions" => [%{"type" => "runner", "pool" => "loop"}]
      }

      assert {:ok, valid} = Spec.validate(spec)
      assert valid["trigger"]["backfill"] == true

      assert Spec.summary(valid) =~
               "take the top card of Housekeeping only when To Do and Scheduled have nothing " <>
                 "this pool could start"

      refute Spec.summary(put_in(valid, ["trigger", "backfill"], false)) =~ "only when"

      assert {:error, "trigger “list_top” backfill must be true or false"} =
               Spec.validate(put_in(spec, ["trigger", "backfill"], "soon"))
    end
  end

  describe "yielding" do
    setup ctx, do: backfilled(ctx)

    test "a startable To Do card keeps Housekeeping waiting", ctx do
      first = card_fixture(ctx.todo, %{"title" => "Epic work"})
      second = card_fixture(ctx.todo, %{"title" => "More epic work"})
      chore = card_fixture(ctx.housekeeping, %{"title" => "Chore"})

      assert open_cards(ctx.todo_feed) == [first.id]
      assert Automations.yielding?(ctx.sibling)
      assert Automations.feed(ctx.sibling) == {:idle, :yielding}
      assert open_cards(ctx.sibling) == []

      # Once To Do has nothing more to send, Housekeeping goes.
      {:ok, _} = Boards.Cards.update_card(second, %{"flags" => ["blocked"]})
      refute Automations.yielding?(ctx.sibling)
      assert open_cards(ctx.sibling) == [chore.id]
    end

    test "with To Do empty the Housekeeping top card is sent", ctx do
      chore = card_fixture(ctx.housekeeping, %{"title" => "Chore"})
      assert open_cards(ctx.sibling) == [chore.id]
    end

    for flag <- ["blocked", "waiting"] do
      test "a To Do card flagged #{flag} doesn't count", ctx do
        card = card_fixture(ctx.todo, %{"title" => "Stuck"})
        {:ok, _} = Boards.Cards.update_card(card, %{"flags" => [unquote(flag)]})
        # The To Do feed had sent it before the flag; that job ends.
        Repo.update_all(from(j in Job, where: j.card_id == ^card.id), set: [status: "cancelled"])

        chore = card_fixture(ctx.housekeeping, %{"title" => "Chore"})
        refute Automations.yielding?(ctx.sibling)
        assert open_cards(ctx.sibling) == [chore.id]
      end
    end

    test "a To Do card waiting on an unfinished card doesn't count", ctx do
      blocker = card_fixture(ctx.backlog, %{"title" => "First"})
      waiting = card_fixture(ctx.backlog, %{"title" => "Then"})
      {:ok, _} = Boards.Dependencies.add_dependency(waiting, blocker)
      assert :ok = Boards.Cards.move_card_to_index(Repo.get!(Card, waiting.id), ctx.todo, :top)

      chore = card_fixture(ctx.housekeeping, %{"title" => "Chore"})
      assert open_cards(ctx.todo_feed) == []
      assert open_cards(ctx.sibling) == [chore.id]
    end

    test "a To Do card its lane holds doesn't count", ctx do
      {:ok, _} = Boards.update_board(ctx.board, %{"lanes" => true})
      running = card_fixture(ctx.doing, %{"title" => "Running"})
      {:ok, _} = Boards.Cards.update_card(running, %{"paths" => "lib/**"})
      working_job_fixture(running)

      held = card_fixture(ctx.backlog, %{"title" => "Held"})
      {:ok, held} = Boards.Cards.update_card(held, %{"paths" => "lib/a.ex"})
      assert :ok = Boards.Cards.move_card_to_index(held, ctx.todo, :top)

      chore = card_fixture(ctx.housekeeping, %{"title" => "Chore"})
      assert open_cards(ctx.todo_feed) == []
      assert open_cards(ctx.sibling) == [chore.id]
    end

    test "a startable Scheduled card keeps it waiting too", ctx do
      col = scheduled(ctx.board)
      [sched_feed] = feeds_on(ctx.board, "Scheduled")
      card_fixture(col, %{"title" => "Nightly"})
      card_fixture(col, %{"title" => "Nightly two"})
      card_fixture(ctx.housekeeping, %{"title" => "Chore"})

      assert length(open_cards(sched_feed)) == 1
      assert Automations.feed(ctx.sibling) == {:idle, :yielding}
    end

    test "another pool's To Do work doesn't hold it", ctx do
      feed(ctx.board, "To Do", "elsewhere")

      Repo.update_all(from(r in Automations.Rule, where: r.id == ^ctx.todo_feed.id),
        set: [enabled: false]
      )

      card_fixture(ctx.todo, %{"title" => "Theirs"})
      card_fixture(ctx.todo, %{"title" => "Theirs too"})
      chore = card_fixture(ctx.housekeeping, %{"title" => "Chore"})

      assert open_cards(ctx.sibling) == [chore.id]
    end

    test "a card moved into To Do goes ahead of the next Housekeeping card", ctx do
      first = card_fixture(ctx.housekeeping, %{"title" => "Chore one"})
      card_fixture(ctx.housekeeping, %{"title" => "Chore two"})
      assert open_cards(ctx.sibling) == [first.id]

      mine = card_fixture(ctx.backlog, %{"title" => "Mine"})
      later = card_fixture(ctx.backlog, %{"title" => "Mine too"})
      assert :ok = Boards.Cards.move_card_to_index(mine, ctx.todo, :top)
      assert :ok = Boards.Cards.move_card_to_index(later, ctx.todo, :bottom)
      # Sent at once, beside the chore already running, which is never stopped.
      assert open_cards(ctx.todo_feed) == [mine.id]
      assert open_cards(ctx.sibling) == [first.id]

      # When the chore ends, To Do still has a card it could send: the
      # second chore waits.
      Repo.update_all(from(j in Job, where: j.rule_id == ^ctx.sibling.id), set: [status: "done"])
      assert Automations.feed(ctx.sibling) == {:idle, :yielding}
      assert open_cards(ctx.sibling) == []
    end

    test "a job ending gives Housekeeping its turn", ctx do
      mine = card_fixture(ctx.todo, %{"title" => "Mine"})
      later = card_fixture(ctx.todo, %{"title" => "Mine too"})
      chore = card_fixture(ctx.housekeeping, %{"title" => "Chore"})
      assert open_cards(ctx.sibling) == []

      job = Runners.claim(ctx.runner)
      assert job.card_id == mine.id
      {:ok, _} = Runners.finish(ctx.runner, job.id, %{status: "done"})

      # The To Do feed sent the next card, and with nothing more To Do
      # could start, the Housekeeping feed sent its own.
      assert open_cards(ctx.todo_feed) == [later.id]
      assert open_cards(ctx.sibling) == [chore.id]
    end

    test "Run now on it doesn't count a To Do card cooling down after its job", ctx do
      rules = [ctx.todo_feed.id, ctx.sibling.id]

      switch =
        &Repo.update_all(from(r in Automations.Rule, where: r.id in ^rules), set: [enabled: &1])

      switch.(false)
      cooling = card_fixture(ctx.todo, %{"title" => "Just worked"})
      chore = card_fixture(ctx.housekeeping, %{"title" => "Chore"})

      working_job_fixture(cooling, %{
        status: "done",
        rule_id: ctx.todo_feed.id,
        pool: "loop",
        finished_at: DateTime.utc_now(:second)
      })

      switch.(true)

      # Run now on the To Do feed would send it; it doesn't make the
      # Housekeeping feed wait, forced or not.
      assert Automations.next_card(ctx.todo_feed, force: true).id == cooling.id
      refute Automations.yielding?(ctx.sibling, force: true)
      assert {:ok, %Card{id: id}} = Automations.feed(ctx.sibling, force: true)
      assert id == chore.id
    end

    test "a queued job its lane holds isn't swapped for the next chore while To Do has work",
         ctx do
      held = card_fixture(ctx.housekeeping, %{"title" => "Held"})
      {:ok, _} = Boards.Cards.update_card(held, %{"paths" => "lib/a.ex"})
      assert open_cards(ctx.sibling) == [held.id]

      # Now a card in progress holds its lane.
      {:ok, _} = Boards.update_board(ctx.board, %{"lanes" => true})
      running = card_fixture(ctx.doing, %{"title" => "Running"})
      {:ok, _} = Boards.Cards.update_card(running, %{"paths" => "lib/**"})
      working_job_fixture(running)

      first = card_fixture(ctx.todo, %{"title" => "Mine"})
      card_fixture(ctx.todo, %{"title" => "Mine too"})
      free = card_fixture(ctx.housekeeping, %{"title" => "Free"})
      {:ok, _} = Boards.Cards.update_card(free, %{"paths" => "docs/**"})

      assert open_cards(ctx.todo_feed) == [first.id]
      # To Do still has a card it could send: the held chore keeps its job.
      Automations.feed(ctx.sibling)
      assert open_cards(ctx.sibling) == [held.id]
    end

    test "a rule without backfill never yields", ctx do
      card_fixture(ctx.todo, %{"title" => "Mine"})
      card_fixture(ctx.todo, %{"title" => "Mine too"})
      refute Automations.yielding?(ctx.todo_feed)
    end
  end
end
