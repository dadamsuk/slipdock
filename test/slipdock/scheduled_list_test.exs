defmodule Slipdock.ScheduledListTest do
  @moduledoc """
  The Scheduled list (#2100): a list category, `scheduled`, for where
  recurring agent work lands. A recurring card's next instance is made there,
  the Sweep and Handbook Tools put their daily cards there, the stock
  templates with a To Do carry one, nothing that answers "what next" reads it
  as the ready list, feed rules work it, and a card left in it past its due
  day is on its owner's Waiting on you.
  """
  use Slipdock.DataCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures
  import Slipdock.GardenerHelpers

  alias Slipdock.{Automations, Boards, CardState, Handbook, Recurrence, Repo, Sweep, Work}
  alias Slipdock.Automations.ScheduledFeed
  alias Slipdock.Boards.{Card, CardMove, Column}
  alias Slipdock.Gardener.Checks.{AbandonedBacklog, StaleInProgress}
  alias Slipdock.Recurrence.Series
  alias Slipdock.Runners.Setup
  alias SlipdockWeb.APIGuide

  setup do
    owner = user_fixture()
    {:ok, owner} = Slipdock.Accounts.update_profile(owner, %{"timezone" => "Europe/London"})
    board = board_fixture(%{"name" => "Agents"}, owner: owner)
    [backlog, todo, doing, done] = board.columns

    %{owner: owner, board: board, backlog: backlog, todo: todo, doing: doing, done: done}
  end

  defp scheduled(board) do
    {:ok, col} =
      Boards.Columns.create_column(board, %{"name" => "Scheduled", "category" => "scheduled"})

    col
  end

  defp feed(board, column, pool, extra \\ %{}) do
    rule_fixture(board, %{
      "trigger" => %{"type" => "list_top", "column" => column, "unassigned" => true},
      "actions" => [Map.merge(%{"type" => "runner", "pool" => pool, "kind" => "claude"}, extra)]
    })
  end

  defp feeds_on(board, column) do
    board.id
    |> Automations.list_rules()
    |> Enum.filter(
      &(&1.spec["trigger"]["type"] == "list_top" and &1.spec["trigger"]["column"] == column)
    )
  end

  describe "the category" do
    test "is one of the list categories, beside triage" do
      assert "scheduled" in Column.category_keys()
      assert {"scheduled", "Scheduled"} in Column.categories()
      assert Column.scheduled?(%Column{category: "scheduled"})
      refute Column.scheduled?(%Column{category: "todo"})
      refute Column.scheduled?(nil)
    end

    test "a list takes it, made or changed, and gives it up", %{board: board, backlog: backlog} do
      col = scheduled(board)
      assert col.category == "scheduled"
      assert Boards.Columns.scheduled_column(board).id == col.id

      {:ok, col} = Boards.Columns.update_column(col, %{"category" => ""})
      assert col.category == nil
      assert Boards.Columns.scheduled_column(board) == nil

      {:ok, backlog} = Boards.Columns.update_column(backlog, %{"category" => "scheduled"})
      assert Boards.Columns.scheduled_column(board).id == backlog.id
    end

    test "a category that isn't one is refused", %{board: board} do
      assert {:error, cs} =
               Boards.Columns.create_column(board, %{"name" => "X", "category" => "sched"})

      assert %{category: [_]} = errors_on(cs)
    end
  end

  describe "the ready list never includes it" do
    test "the guide's roles skip it even placed first, and name it", %{board: board} do
      col = scheduled(board)
      Repo.update_all(from(c in Column, where: c.id == ^col.id), set: [position: -1])
      columns = Boards.get_board!(board.id).columns
      assert hd(columns).id == col.id

      roles = APIGuide.list_roles(columns)
      assert roles.ready.name == "To Do"
      assert roles.backlog.name == "Backlog"
      assert roles.scheduled.id == col.id
      assert APIGuide.role(columns, col) == nil
      assert Slipdock.Flow.ready_list(columns).name == "To Do"
    end

    test "a list named like a ready list is still Scheduled when its category says so" do
      columns = [
        %Column{id: 1, name: "To Do next", category: "scheduled"},
        %Column{id: 2, name: "Later", category: nil}
      ]

      assert APIGuide.role(columns, hd(columns)) == nil
      assert APIGuide.list_roles(columns).ready.id == 2
    end

    test "on a board with no other categories the other lists keep their reading" do
      columns = [
        %Column{id: 1, name: "Scheduled", category: "scheduled"},
        %Column{id: 2, name: "Ideas pile", category: nil}
      ]

      assert APIGuide.role(columns, Enum.at(columns, 1)) == "todo"
      assert APIGuide.list_roles(columns).ready.id == 2
    end

    test "a board without one has no scheduled role", %{board: board} do
      assert APIGuide.list_roles(Boards.get_board!(board.id).columns).scheduled == nil
    end

    test "the guide marks it and says who works it", %{owner: owner, board: board} do
      scheduled(board)
      guide = APIGuide.markdown(user: owner)
      assert guide =~ "Scheduled (scheduled: worked by feed rules, never take work from it"
      assert guide =~ "**Never take work from a Scheduled list.**"
      assert guide =~ "Feed rules work it"
      assert guide =~ ~s(take work from: “To Do”)
      refute guide =~ ~s(take work from: “Scheduled”)
      assert APIGuide.short(user: owner) =~ "Never take work from a Scheduled list"
    end

    test "the gardener's stale check sends a card back to To Do, not to Scheduled", ctx do
      col = scheduled(ctx.board)
      Repo.update_all(from(c in Column, where: c.id == ^col.id), set: [position: -1])
      card = card_fixture(ctx.doing, %{"title" => "Stuck"})
      age(card, 14)

      assert [finding] = find(StaleInProgress, ctx.board)
      assert finding.proposal == [%{"op" => "move", "card" => card.id, "column" => ctx.todo.id}]
    end
  end

  describe "a recurring card's next instance" do
    setup ctx do
      card = card_fixture(ctx.todo, %{"title" => "Sweep the code", "due_date" => "2027-01-11"})
      {:ok, series} = Recurrence.set(card, %{"rule" => "mon"}, ctx.owner)
      {:ok, _} = Boards.Cards.update_card(Repo.get!(Card, card.id), %{"completed" => true})
      %{card: card, series: series}
    end

    defp next_instance(series) do
      assert Recurrence.tick(~U[2027-01-18 07:00:00Z]) == 1
      Repo.get!(Card, Repo.get!(Series, series.id).card_id)
    end

    test "lands in the board's Scheduled list, on top", ctx do
      col = scheduled(ctx.board)
      card_fixture(col, %{"title" => "Already there"})

      new = next_instance(ctx.series)
      assert new.column_id == col.id
      assert [{:card, top} | _] = Boards.Columns.active_items(col.id)
      assert top == new.id
    end

    test "in the series' own list when it names one", ctx do
      scheduled(ctx.board)
      {:ok, _} = Recurrence.set(ctx.card, %{"column" => ctx.backlog.name}, ctx.owner)
      assert next_instance(ctx.series).column_id == ctx.backlog.id
    end

    test "in the ready list on a board without one", ctx do
      assert next_instance(ctx.series).column_id == ctx.todo.id
    end
  end

  describe "the Sweep and Handbook Tools" do
    test "put their recurring cards in Scheduled when the board has one", ctx do
      col = scheduled(ctx.board)
      {:ok, _} = Sweep.install(ctx.owner, ctx.board)
      {:ok, _} = Handbook.install(ctx.owner, ctx.board)

      in_list = fn title ->
        Repo.one(
          from(c in Card,
            where: c.board_id == ^ctx.board.id and c.title == ^title,
            select: c.column_id
          )
        )
      end

      assert in_list.(Sweep.card_title()) == col.id
      assert in_list.(Handbook.reconcile_title()) == col.id
      assert in_list.(Handbook.triage_title()) == col.id
      # A one-off card goes where it always did.
      assert in_list.(Handbook.seed_title()) == ctx.todo.id
    end

    test "use the ready list on a board without one", ctx do
      {:ok, _} = Sweep.install(ctx.owner, ctx.board)
      {:ok, _} = Handbook.install(ctx.owner, ctx.board)

      columns =
        from(c in Card,
          where:
            c.board_id == ^ctx.board.id and
              c.title in ^[Sweep.card_title(), Handbook.reconcile_title()],
          select: c.column_id
        )
        |> Repo.all()

      assert columns == [ctx.todo.id, ctx.todo.id]
    end

    test "scheduled_cards/2 leaves a card that names its list alone", ctx do
      scheduled(ctx.board)

      blueprint = %{
        "cards" => [
          %{"title" => "Daily", "repeat" => "every day"},
          %{"title" => "Daily, mine", "repeat" => "every day", "list" => "Backlog"},
          %{"title" => "Once"}
        ]
      }

      assert %{"cards" => [daily, mine, once]} = Handbook.scheduled_cards(blueprint, ctx.board)
      assert daily["list"] == "Scheduled"
      assert mine["list"] == "Backlog"
      refute Map.has_key?(once, "list")
    end
  end

  describe "the templates" do
    test "Simple and Slipdock carry Scheduled after To Do; the rest don't" do
      for name <- ["Simple", "Slipdock"] do
        {:ok, template} = Boards.Templates.find_template(nil, name)
        names = Enum.map(template.columns, & &1["name"])
        i = Enum.find_index(names, &(&1 == "To Do"))
        assert Enum.at(template.columns, i + 1)["name"] == "Scheduled"
        assert Enum.at(template.columns, i + 1)["category"] == "scheduled"
        assert Enum.count(template.columns, &(&1["category"] == "scheduled")) == 1
      end

      for name <- ["Checklist", "Bug triage", "Research", "Roadmap"] do
        {:ok, template} = Boards.Templates.find_template(nil, name)
        refute Enum.any?(template.columns, &(&1["category"] == "scheduled"))
      end
    end

    test "a board made from Simple has it; a sub-board made from Simple doesn't", ctx do
      {:ok, simple} = Boards.Templates.find_template(nil, "Simple")

      {:ok, board} =
        Boards.create_board(%{"name" => "Fresh"}, template: simple, owner_id: ctx.owner.id)

      names = board.id |> Boards.get_board!() |> Map.get(:columns) |> Enum.map(& &1.name)
      assert names == ["To Do", "Scheduled", "Doing", "Done"]

      epic = card_fixture(ctx.todo, %{"title" => "An epic"})
      {:ok, sub} = Boards.create_sub_board(epic, simple)
      sub_names = sub.id |> Boards.get_board!() |> Map.get(:columns) |> Enum.map(& &1.name)
      assert sub_names == ["To Do", "Doing", "Done"]
    end
  end

  describe "a Scheduled card not started by the end of its due day" do
    setup ctx do
      %{scheduled: scheduled(ctx.board)}
    end

    test "is on the owner's Waiting on you, with its day", ctx do
      yesterday = Date.add(Slipdock.Timezones.today("Europe/London"), -1)
      card = card_fixture(ctx.scheduled, %{"title" => "Nightly", "due_date" => yesterday})

      assert [item] = Work.waiting_on_me(ctx.owner)
      assert item.card.id == card.id
      assert item.reason == "scheduled_missed"

      assert item.text ==
               "Scheduled for #{Calendar.strftime(yesterday, "%a %-d %b")}, not started"

      assert item.since ==
               Slipdock.Timezones.to_utc(Date.add(yesterday, 1), ~T[00:00:00], "Europe/London")

      assert "scheduled_missed" in Work.reasons()
    end

    test "not while its day lasts, nor with no due date", ctx do
      today = Slipdock.Timezones.today("Europe/London")
      card_fixture(ctx.scheduled, %{"title" => "Today", "due_date" => today})
      card_fixture(ctx.scheduled, %{"title" => "Undated"})
      assert Work.waiting_on_me(ctx.owner) == []
    end

    test "not once started, done or archived, and not on someone else's list", ctx do
      yesterday = Date.add(Slipdock.Timezones.today("Europe/London"), -1)
      started = card_fixture(ctx.scheduled, %{"due_date" => yesterday})
      Boards.Cards.move_card(started.id, ctx.doing.id)
      card_fixture(ctx.scheduled, %{"due_date" => yesterday, "completed" => true})
      archived = card_fixture(ctx.scheduled, %{"due_date" => yesterday})
      {:ok, _} = Boards.Cards.archive_card(archived)
      # Due yesterday, but in an ordinary list: not this reason.
      card_fixture(ctx.todo, %{"due_date" => yesterday})

      assert Enum.map(Work.waiting_on_me(ctx.owner), & &1.reason) == []
      assert Work.waiting_on_me(user_fixture()) == []
    end
  end

  describe "the stale and age checks leave Scheduled alone" do
    setup ctx do
      %{scheduled: scheduled(ctx.board)}
    end

    test "abandoned_backlog and stale_in_progress find nothing there", ctx do
      card = card_fixture(ctx.scheduled, %{"title" => "Waiting its turn"})
      age(card, 400)

      assert find(AbandonedBacklog, ctx.board, settings: %{"enabled" => true}) == []
      assert find(StaleInProgress, ctx.board) == []
    end

    test "no 'over usual' for a card in it", ctx do
      card = card_fixture(ctx.scheduled)
      at = DateTime.add(DateTime.utc_now(), -10 * 86_400)
      Repo.update_all(from(m in CardMove, where: m.card_id == ^card.id), set: [inserted_at: at])

      [card] =
        CardState.put([Boards.Cards.get_card!(card.id)], ctx.board,
          usual: %{ctx.scheduled.id => 60}
        )

      assert card.state.age >= 10 * 86_400
      assert card.state.over_usual == nil
      refute card.state.stuck
    end
  end

  describe "feed rules on the Scheduled list" do
    test "a new Scheduled list gets a sibling of each ready-list feed, with its settings", ctx do
      loop = feed(ctx.board, "To Do", "loop", %{"wait_while_doing" => true, "requeue_stuck" => 2})
      feed(ctx.board, "To Do", "BigWhite")
      # Not on the ready list: no sibling.
      feed(ctx.board, "Backlog", "spare")

      scheduled(ctx.board)

      siblings = feeds_on(ctx.board, "Scheduled")

      assert Enum.map(siblings, & &1.name) |> Enum.sort() ==
               [
                 "Work Scheduled with the bigwhite runners",
                 "Work Scheduled with the loop runners"
               ]

      sibling = Enum.find(siblings, &(&1.name =~ "loop"))
      assert sibling.spec["actions"] == loop.spec["actions"]
      assert sibling.spec["trigger"]["unassigned"] == true
      assert sibling.enabled
    end

    test "a pool with a feed on Scheduled already gets no second, and again makes nothing",
         ctx do
      feed(ctx.board, "To Do", "loop")
      feed(ctx.board, "To Do", "macstudio")
      {:ok, col} = Boards.Columns.create_column(ctx.board, %{"name" => "Scheduled"})
      # As the owner added #47 by hand, before the list had its category.
      feed(ctx.board, "Scheduled", "loop")

      {:ok, _} = Boards.Columns.update_column(col, %{"category" => "scheduled"})

      assert Enum.map(feeds_on(ctx.board, "Scheduled"), &hd(&1.spec["actions"])["pool"])
             |> Enum.sort() ==
               ["loop", "macstudio"]

      assert {:ok, []} = ScheduledFeed.ensure(ctx.board)

      {:ok, col} =
        Boards.Columns.update_column(Repo.get!(Column, col.id), %{"name" => "Scheduled"})

      assert col.category == "scheduled"
      assert length(feeds_on(ctx.board, "Scheduled")) == 2
    end

    test "a board without a Scheduled list, or without ready-list feeds, gets none", ctx do
      feed(ctx.board, "To Do", "loop")
      assert {:ok, []} = ScheduledFeed.ensure(ctx.board)

      other = board_fixture(%{"name" => "Quiet"}, owner: ctx.owner)
      scheduled(other)
      assert Automations.list_rules(other.id) == []
    end

    test "the sibling sends the Scheduled list's top card to its pool", ctx do
      {:ok, _runner, _} =
        Slipdock.Runners.create_runner(ctx.board, %{"name" => "box", "pool" => "loop"})

      feed(ctx.board, "To Do", "loop")
      col = scheduled(ctx.board)
      card = card_fixture(col, %{"title" => "Nightly"})

      [sibling] = feeds_on(ctx.board, "Scheduled")
      Automations.feed(sibling)

      assert [job] = Repo.all(from(j in Slipdock.Runners.Job, where: j.card_id == ^card.id))
      assert job.pool == "loop"
      assert job.rule_id == sibling.id
    end

    test "setting up a runner on the ready list adds the Scheduled sibling", ctx do
      scheduled(ctx.board)
      params = %{"scenario" => "loop", "pool" => "loop", "column" => "To Do", "feed" => "top"}

      assert {:ok, %{rule: rule}} =
               Setup.connect(ctx.board, params, ctx.owner, "https://slipdock.test")

      assert rule.spec["trigger"]["column"] == "To Do"
      assert [sibling] = feeds_on(ctx.board, "Scheduled")
      assert sibling.created_by_id == ctx.owner.id
      assert hd(sibling.spec["actions"])["pool"] == "loop"
    end

    test "a board at its rule limit keeps the list and logs the sibling it couldn't make",
         ctx do
      feed(ctx.board, "To Do", "loop")

      for i <- 2..Automations.max_rules() do
        rule_fixture(ctx.board, %{
          "trigger" => %{"type" => "card_created"},
          "actions" => [%{"type" => "comment", "body" => "rule #{i}"}]
        })
      end

      assert {:ok, col} =
               Boards.Columns.create_column(ctx.board, %{
                 "name" => "Scheduled",
                 "category" => "scheduled"
               })

      assert col.category == "scheduled"
      assert feeds_on(ctx.board, "Scheduled") == []
      assert {:error, "the Scheduled feed for " <> _} = ScheduledFeed.ensure(ctx.board)
    end
  end
end
