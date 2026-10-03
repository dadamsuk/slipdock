defmodule Slipdock.RoadmapTest do
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures
  alias Slipdock.{Boards, Dates, Rollup, Timeline}
  alias Slipdock.Boards.{Card, Column}
  alias Slipdock.Swimlanes.Config

  describe "list categories" do
    test "dropping a card into a done list completes it, and back into a to-do list reopens it" do
      board = board_fixture()
      [backlog, _todo, _doing, done] = board.columns
      assert done.category == "done"
      assert backlog.category == "todo"

      card = card_fixture(backlog, %{"title" => "Ship"})
      refute card.completed

      :ok = Boards.move_card(card.id, done.id)
      assert Boards.get_card!(card.id).completed

      :ok = Boards.move_card(card.id, backlog.id)
      refute Boards.get_card!(card.id).completed
    end

    test "a list without a category leaves completion alone" do
      board = board_fixture()
      [backlog | _] = board.columns
      {:ok, plain} = Boards.create_column(board, %{"name" => "Parked"})
      card = card_fixture(backlog, %{"title" => "Ship", "completed" => true})

      :ok = Boards.move_card(card.id, plain.id)
      assert Boards.get_card!(card.id).completed
    end

    test "cards in a dropped list count for nothing in the roll-up" do
      board = board_fixture()
      [backlog | _] = board.columns

      {:ok, dropped} =
        Boards.create_column(board, %{"name" => "Won't do", "category" => "dropped"})

      a = card_fixture(backlog, %{"title" => "A", "completed" => true})
      _b = card_fixture(backlog, %{"title" => "B"})
      c = card_fixture(dropped, %{"title" => "C"})

      rollup = Rollup.build(board.id)
      assert Rollup.stats(rollup, c).health == :dropped
      assert Rollup.stats(rollup, c).total == 0
      assert Rollup.stats(rollup, a).total == 1
    end

    test "only known categories are accepted" do
      board = board_fixture()
      assert {:error, cs} = Boards.create_column(board, %{"name" => "X", "category" => "maybe"})
      assert %{category: _} = errors_on(cs)
    end
  end

  describe "horizons" do
    test "a horizon list schedules a card dropped into it to the horizon's end" do
      board = board_fixture()
      [backlog | _] = board.columns

      {:ok, q1} =
        Boards.create_column(board, %{
          "name" => "Q1",
          "horizon_from" => "2027-01-01",
          "horizon_to" => "2027-03-31",
          "horizon_unit" => "quarter"
        })

      assert Column.horizon_label(q1) == "Q1 2027"

      card = card_fixture(backlog, %{"title" => "Undated"})
      :ok = Boards.move_card(card.id, q1.id)
      card = Boards.get_card!(card.id)
      assert card.due_date == ~D[2027-03-31]
      assert card.date_precision == "quarter"

      # A card already inside the range keeps its date.
      inside = card_fixture(backlog, %{"title" => "Inside", "due_date" => "2027-02-10"})
      :ok = Boards.move_card(inside.id, q1.id)
      assert Boards.get_card!(inside.id).due_date == ~D[2027-02-10]

      # A card outside the range is pulled in, and a start after the target is dropped.
      outside =
        card_fixture(backlog, %{
          "title" => "Outside",
          "start_date" => "2027-06-01",
          "due_date" => "2027-06-30"
        })

      :ok = Boards.move_card(outside.id, q1.id)
      outside = Boards.get_card!(outside.id)
      assert outside.due_date == ~D[2027-03-31]
      assert is_nil(outside.start_date)
    end

    test "drifted? says when a card's due date lies outside the horizon" do
      col = %Column{horizon_from: ~D[2027-01-01], horizon_to: ~D[2027-03-31]}
      assert Column.drifted?(col, ~D[2027-04-01])
      refute Column.drifted?(col, ~D[2027-02-01])
      refute Column.drifted?(col, nil)
      refute Column.drifted?(%Column{}, ~D[2027-04-01])
    end

    test "the horizon must run forwards" do
      board = board_fixture()

      assert {:error, cs} =
               Boards.create_column(board, %{
                 "name" => "X",
                 "horizon_from" => "2027-03-31",
                 "horizon_to" => "2027-01-01"
               })

      assert %{horizon_from: _} = errors_on(cs)
    end
  end

  describe "date precision" do
    test "dates snap to whole buckets at a coarse precision" do
      board = board_fixture()
      [col | _] = board.columns

      card =
        card_fixture(col, %{
          "title" => "Roughly Q2",
          "start_date" => "2027-04-10",
          "due_date" => "2027-05-03",
          "date_precision" => "quarter"
        })

      assert card.start_date == ~D[2027-04-01]
      assert card.due_date == ~D[2027-06-30]
      assert Card.fuzzy?(card)

      {:ok, card} = Boards.update_card(card, %{"date_precision" => "month"})
      # Snapping keeps the already-aligned quarter: April 1 and June 30 are month bounds.
      assert card.start_date == ~D[2027-04-01]
      assert card.due_date == ~D[2027-06-30]

      {:ok, card} = Boards.update_card(card, %{"date_precision" => "day"})
      assert card.start_date == ~D[2027-04-01]
    end

    test "bucket maths" do
      assert Dates.bucket_start(~D[2027-08-15], "half") == ~D[2027-07-01]
      assert Dates.bucket_end(~D[2027-08-15], "half") == ~D[2027-12-31]
      assert Dates.bucket_end(~D[2027-02-15], "month") == ~D[2027-02-28]
      assert Dates.label(~D[2027-08-15], "quarter") == "Q3 2027"
      assert Dates.label(~D[2027-08-15], "half") == "H2 2027"
      assert Dates.range_label(~D[2027-07-01], ~D[2027-09-30], "quarter") == "Q3 2027"

      assert Dates.range_label(~D[2027-07-01], ~D[2027-09-15], "quarter") ==
               "1 Jul 2027 – 15 Sep 2027"
    end

    test "dragging a fuzzy bar moves it by whole buckets" do
      card = %Card{
        start_date: ~D[2027-04-01],
        due_date: ~D[2027-06-30],
        date_precision: "quarter"
      }

      assert Timeline.shift_attrs(card, "both", 10) == %{}

      assert Timeline.shift_attrs(card, "both", 80) == %{
               "start_date" => ~D[2027-07-01],
               "due_date" => ~D[2027-09-30]
             }

      # Day-precision cards still move by days.
      assert Timeline.shift_attrs(%{card | date_precision: "day"}, "both", 3) == %{
               "start_date" => ~D[2027-04-04],
               "due_date" => ~D[2027-07-03]
             }
    end
  end

  describe "milestones" do
    test "milestones live on the root board and appear in the timeline window" do
      %{board: board, sub: sub} = tree_fixture()

      {:ok, m} =
        Boards.create_milestone(sub, %{
          "name" => "Launch",
          "date" => "2030-01-20",
          "color" => "rose"
        })

      assert m.board_id == board.id
      assert [%{name: "Launch"}] = Boards.list_milestones(board.id)
      assert [%{name: "Launch"}] = Boards.get_board!(sub.id).milestones

      timeline = Timeline.build(reload(board), Config.defaults("timeline"), ~D[2030-01-15])
      assert [%{name: "Launch", idx: idx}] = timeline.milestones
      assert idx == Date.diff(~D[2030-01-20], timeline.window.from)

      calendar =
        Slipdock.Calendar.build(reload(board), Config.defaults("calendar"), ~D[2030-01-15])

      assert [%{name: "Launch"}] = calendar.milestones["2030-01-20"]

      {:ok, _} = Boards.delete_milestone(m)
      assert Boards.list_milestones(board.id) == []
    end

    test "a milestone needs a name and a date" do
      board = board_fixture()
      assert {:error, cs} = Boards.create_milestone(board, %{"name" => "", "date" => ""})
      assert %{name: _, date: _} = errors_on(cs)
    end
  end
end
