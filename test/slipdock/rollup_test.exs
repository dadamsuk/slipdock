defmodule Slipdock.RollupTest do
  use Slipdock.DataCase, async: false

  import Slipdock.Fixtures
  alias Slipdock.Boards
  alias Slipdock.Boards.Card
  alias Slipdock.Rollup

  @today ~D[2030-01-15]

  setup do
    tree_fixture()
  end

  test "leaves, parents, dates, slip and health roll up the tree", ctx do
    r = Rollup.build(ctx.board.id, @today)
    assert r.root_id == ctx.board.id
    assert Enum.sort(Rollup.board_ids(r)) == Enum.sort([ctx.board.id, ctx.sub.id, ctx.subsub.id])

    # A leaf counts once; its dates are its own.
    assert %{total: 1, done: 0, start: nil, due: ~D[2030-02-01], depth: 0, health: :ok} =
             Rollup.stats(r, ctx.e)

    assert %{total: 1, done: 1, health: :done} = Rollup.stats(r, ctx.d)
    assert %{total: 1, done: 0, health: :ok, start: nil, due: nil} = Rollup.stats(r, ctx.loose)

    # C keeps its own dates but its children run 12 days past its due date.
    assert %{
             total: 2,
             done: 1,
             start: ~D[2030-01-05],
             due: ~D[2030-01-20],
             start_derived?: false,
             due_derived?: false,
             derived_start: ~D[2030-02-01],
             derived_due: ~D[2030-02-01],
             slip: 12,
             health: :late,
             depth: 1,
             children: 2
           } = Rollup.stats(r, ctx.c)

    # The epic has no start of its own, so it starts when its first child does.
    assert %{
             total: 3,
             done: 2,
             start: ~D[2030-01-05],
             due: ~D[2030-01-15],
             start_derived?: true,
             due_derived?: false,
             derived_start: ~D[2030-01-05],
             derived_due: ~D[2030-01-20],
             slip: 5,
             overdue: false,
             blocked: false,
             health: :late,
             depth: 2,
             children: 2
           } = Rollup.stats(r, ctx.epic)

    # Overdue and blocked leaves.
    assert %{overdue: true, health: :late} = Rollup.stats(r, ctx.late)
    assert %{blocked: true, health: :blocked} = Rollup.stats(r, ctx.stuck)

    # Children in board order, decorated.
    assert [%Card{title: "B", rollup: %{done: 1}}, %Card{title: "C", rollup: %{total: 2}}] =
             Rollup.children(r, ctx.epic)

    assert Rollup.levels(r, ctx.board.id) == 3
    assert Rollup.levels(r, ctx.subsub.id) == 1
  end

  test "overdue, blocked and done bubble up; a completed parent is done", ctx do
    {:ok, _} = Boards.create_sub_board(ctx.loose, ctx.template)
    loose = Boards.get_card!(ctx.loose.id)

    kid =
      card_fixture(hd(loose.sub_board.columns), %{"title" => "Kid", "due_date" => "2029-12-01"})

    blocker = card_fixture(hd(loose.sub_board.columns), %{"title" => "Blocker"})
    {:ok, _} = Boards.add_dependency(kid, blocker)

    r = Rollup.build(ctx.board.id, @today)

    assert %{
             overdue: true,
             blocked: true,
             health: :blocked,
             due: ~D[2029-12-01],
             due_derived?: true
           } =
             Rollup.stats(r, loose)

    {:ok, _} = Boards.update_card(loose, %{"completed" => true})
    r = Rollup.build(ctx.board.id, @today)
    assert %{health: :done, total: 2, done: 0} = Rollup.stats(r, loose)

    # All leaves done makes the parent done without touching its flag.
    {:ok, _} = Boards.update_card(ctx.e, %{"completed" => true})
    r = Rollup.build(ctx.board.id, @today)
    assert %{health: :done, total: 2, done: 2, slip: 12} = Rollup.stats(r, ctx.c)
  end

  test "loaded boards and cards carry their rollup", ctx do
    board = Boards.get_board!(ctx.board.id)
    epic = board.columns |> Enum.flat_map(& &1.cards) |> Enum.find(&(&1.title == "Epic"))
    assert %{total: 3, done: 2} = epic.rollup
    assert Card.progress(epic) == {2, 3}
    assert Card.effective_start(epic) == ~D[2030-01-05]
    assert Card.effective_due(epic) == ~D[2030-01-15]
    assert Card.start_derived?(epic) and not Card.due_derived?(epic)

    c = Boards.get_card!(ctx.c.id)
    assert Card.slip(c) == 12 and Card.health(c) == :late
    assert Card.progress(ctx.loose) == nil

    # A sub-board's cards are rolled up against the same root.
    sub = Boards.get_board!(ctx.sub.id)

    assert Enum.flat_map(sub.columns, & &1.cards) |> Enum.find(&(&1.title == "C")) |> Card.slip() ==
             12

    # The tree view nests to a depth.
    r = Boards.rollup(board)
    [epic_node | _] = Rollup.tree(r, board.id, 2)
    assert epic_node.card.title == "Epic" and epic_node.level == 0
    assert Enum.map(epic_node.children, & &1.card.title) == ["B", "C"]
    assert [%{children: []}, %{children: []}] = epic_node.children
    [_, %{children: [d, _]}] = hd(Rollup.tree(r, board.id)).children
    assert d.card.title == "D" and d.level == 2
  end

  test "the timeline places a parent by its rolled-up dates and locks derived edges", ctx do
    board = Boards.get_board!(ctx.board.id)
    config = %{Slipdock.Swimlanes.Config.defaults("timeline") | date: "2030-01-15", unit: "week"}
    tl = Slipdock.Timeline.build(board, config, @today)
    [%{bars: bars}] = tl.groups
    by_title = Map.new(bars, &{&1.card.title, &1})

    # Epic: derived start (5 Jan), own due (15 Jan); window starts 24 Dec.
    assert %{from: 12, to: 23, kind: :span, derived_start: true, derived_end: false} =
             by_title["Epic"]

    assert %{kind: :due, derived_start: false, derived_end: false} = by_title["Late"]
    refute Map.has_key?(by_title, "Loose")
    assert Enum.map(tl.unscheduled, & &1.title) == ["Stuck", "Loose"]

    # Give Loose subcards with dates: it is placed entirely from them.
    {:ok, _} = Boards.create_sub_board(ctx.loose, ctx.template)
    loose = Boards.get_card!(ctx.loose.id)
    card_fixture(hd(loose.sub_board.columns), %{"title" => "Kid", "due_date" => "2030-01-30"})
    tl = Slipdock.Timeline.build(Boards.get_board!(ctx.board.id), config, @today)
    [%{bars: bars}] = tl.groups

    assert %{kind: :due, derived_start: true, derived_end: true} =
             Enum.find(bars, &(&1.card.title == "Loose"))
  end

  test "the timeline nests scheduled subcards beneath a bar to the chosen depth", ctx do
    board = Boards.get_board!(ctx.board.id)
    base = %{Slipdock.Swimlanes.Config.defaults("timeline") | date: "2030-01-15", unit: "week"}

    # The default depth is one level: no nesting, but the levels are reported.
    tl = Slipdock.Timeline.build(board, base, @today)
    assert tl.levels == 3
    [%{bars: bars}] = tl.groups
    assert Enum.all?(bars, &(&1.children == [] and &1.level == 0))

    tl = Slipdock.Timeline.build(board, %{base | depth: "all"}, @today)
    [%{bars: bars}] = tl.groups
    epic = Enum.find(bars, &(&1.card.title == "Epic"))
    assert Enum.map(epic.children, &{&1.card.title, &1.level}) == [{"B", 1}, {"C", 1}]
    [_, c] = epic.children
    # D has no dates, so only E hangs beneath C.
    assert Enum.map(c.children, &{&1.card.title, &1.level}) == [{"E", 2}]
    assert %{from: 39, to: 40, kind: :due} = hd(c.children)

    tl = Slipdock.Timeline.build(board, %{base | depth: "2"}, @today)
    [%{bars: bars}] = tl.groups
    [_, c] = Enum.find(bars, &(&1.card.title == "Epic")).children
    assert c.children == []
  end
end
