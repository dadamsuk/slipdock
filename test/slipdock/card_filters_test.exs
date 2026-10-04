defmodule Slipdock.CardFiltersTest do
  @moduledoc """
  The filters `Slipdock.Boards.list_cards/2` takes, which are the board views'
  own (`Slipdock.Swimlanes`) and reach the API, the CLI and the assistant
  through the same function.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Boards}

  setup do
    owner = user_fixture("owner@example.com")
    jess = user_fixture("jess@example.com")
    {:ok, jess} = Accounts.update_profile(jess, %{"name" => "Jess Smith"})

    board = board_fixture(%{"name" => "Filters"}, owner: owner) |> share_fixture(jess)
    [backlog | _] = board.columns
    today = Date.utc_today()

    late = card_fixture(backlog, %{"title" => "Late", "due_date" => Date.add(today, -3)})
    soon = card_fixture(backlog, %{"title" => "Soon", "due_date" => Date.add(today, 3)})
    far = card_fixture(backlog, %{"title" => "Far", "due_date" => Date.add(today, 90)})
    undated = card_fixture(backlog, %{"title" => "Undated"})

    finished =
      card_fixture(backlog, %{
        "title" => "Finished",
        "completed" => true,
        "due_date" => Date.add(today, -10)
      })

    waiting = card_fixture(backlog, %{"title" => "Waiting"})
    {:ok, _} = Boards.add_dependency(waiting, late)
    {:ok, _} = Boards.update_card(late, %{"assignee_id" => jess.id})

    %{
      board: board,
      titles: fn filters -> board |> Boards.list_cards(filters) |> Enum.map(& &1.title) end,
      cards: %{
        late: late,
        soon: soon,
        far: far,
        undated: undated,
        finished: finished,
        waiting: waiting
      }
    }
  end

  test "due buckets, and a completed card in none of them", ctx do
    assert ctx.titles.(%{"due" => "overdue"}) == ["Late"]
    assert ctx.titles.(%{"due" => "week"}) == ["Soon"]
    refute "Far" in ctx.titles.(%{"due" => "month"})
    assert ctx.titles.(%{"due" => "none"}) == ["Undated", "Waiting"]
    refute "Finished" in ctx.titles.(%{"due" => "overdue"})
    assert "Finished" in ctx.titles.(%{"due" => "has"})
  end

  test "dependency buckets", ctx do
    assert ctx.titles.(%{"deps" => "blocked"}) == ["Waiting"]
    assert ctx.titles.(%{"deps" => "blocking"}) == ["Late"]
    refute "Waiting" in ctx.titles.(%{"deps" => "ready"})
    assert "Undated" in ctx.titles.(%{"deps" => "free"})
  end

  test "assignee by email, by name, and by nobody", ctx do
    assert ctx.titles.(%{"assignee" => "jess@example.com"}) == ["Late"]
    assert ctx.titles.(%{"assignee" => "jess"}) == ["Late"]
    assert ctx.titles.(%{"assignee" => "Jess Smith"}) == ["Late"]
    refute "Late" in ctx.titles.(%{"assignee" => "none"})
    assert "Undated" in ctx.titles.(%{"assignee" => "unassigned"})
  end

  test "filters combine, and a value that is not a bucket is ignored rather than raising", ctx do
    assert ctx.titles.(%{"due" => "overdue", "assignee" => "jess"}) == ["Late"]
    assert ctx.titles.(%{"due" => "overdue", "assignee" => "none"}) == []

    # Query strings arrive as anything at all; this must not blow up.
    assert length(ctx.titles.(%{"due" => "yesterday"})) == 6
    assert length(ctx.titles.(%{"deps" => "tangled"})) == 6
    assert length(ctx.titles.(%{"due" => ""})) == 6
  end
end
