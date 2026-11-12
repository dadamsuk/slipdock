defmodule SlipdockWeb.VisualiseDoingListTest do
  @moduledoc """
  The Visualise page reads a doing list by its category, else by its name
  (#2676, as `Slipdock.Flow.doing_list?/1` does): on a sub-board made from
  the Simple template, whose "Doing" has no category, that list is in the
  flow as the doing list (its WIP limit, its tint), not set apart as
  outside it, and its cards are aged and counted in progress.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.Boards

  setup %{user: user} do
    board = board_fixture(%{"name" => "Seen", "code" => unique_code()}, owner: user)
    [_backlog, _todo, doing, _done] = board.columns
    epic = card_fixture(doing, %{"title" => "Epic"})
    {:ok, t} = Boards.Templates.find_template(nil, "Simple")
    {:ok, sub} = sub_board(epic, t)
    sub = Boards.get_board!(sub.id)
    sub_todo = Enum.find(sub.columns, &(&1.name == "To Do"))
    sub_doing = Enum.find(sub.columns, &(&1.name == "Doing"))
    assert sub_doing.category in [nil, ""]

    %{sub: sub, sub_todo: sub_todo, sub_doing: sub_doing}
  end

  test "an uncategorised Doing is the flow's doing list, with its WIP limit",
       %{conn: conn} = ctx do
    {:ok, _} = Boards.Columns.update_column(ctx.sub_doing, %{"wip_limit" => 2})
    card = card_fixture(ctx.sub_doing, %{"title" => "Busy"})

    {:ok, view, _} = live(conn, ~p"/boards/#{ctx.sub}/visualise")

    # In progress, against the list's limit.
    assert has_element?(view, "#tile-wip [data-value]", "1 / 2")
    assert has_element?(view, "#flow-count-#{ctx.sub_doing.id}", "1 / 2")
    assert has_element?(view, "#flow-list-#{ctx.sub_doing.id}.bg-primary\\/10")
    refute has_element?(view, "#flow-list-#{ctx.sub_doing.id}", "Outside the flow")

    # Drawn as a doing list throughout: the block's tint (and not the plain
    # list's as well), the count's tone and the fill bar.
    refute has_element?(view, "#flow-list-#{ctx.sub_doing.id}.bg-base-300\\/60")
    assert has_element?(view, "#flow-count-#{ctx.sub_doing.id}.text-primary", "1 / 2")
    assert has_element?(view, "#flow-list-#{ctx.sub_doing.id} .bg-primary")
    refute has_element?(view, "#flow-list-#{ctx.sub_doing.id} .bg-base-content\\/40")

    # A list beside it that isn't one keeps the plain look.
    refute has_element?(view, "#flow-count-#{ctx.sub_todo.id}.text-primary")
    refute has_element?(view, "#flow-list-#{ctx.sub_todo.id} .bg-primary")

    # Aged as work in progress, not left out as outside the flow.
    assert has_element?(view, "#aging-#{card.id}")
    refute has_element?(view, "#aging-outside")
  end

  test "an uncategorised list not named as a doing list is still outside the flow",
       %{conn: conn} = ctx do
    {:ok, other} = Boards.Columns.create_column(ctx.sub, %{"name" => "Parked"})
    parked = card_fixture(other, %{"title" => "Parked"})

    {:ok, view, _} = live(conn, ~p"/boards/#{ctx.sub}/visualise")

    assert has_element?(view, "#flow-list-#{other.id}", "Outside the flow")
    refute has_element?(view, "#aging-#{parked.id}")
    assert has_element?(view, "#aging-outside", "Parked")
  end
end
