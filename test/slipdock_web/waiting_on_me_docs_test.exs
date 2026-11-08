defmodule SlipdockWeb.WaitingOnMeDocsTest do
  @moduledoc """
  What in an epic's tree waits on you (#2095) as the docs describe it: the
  manual, docs/agents.md, the API guide, the in-app guide and agents page,
  the README and the packaged skill.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  @root Path.expand("../..", __DIR__)
  defp flat(path), do: @root |> Path.join(path) |> File.read!() |> String.replace(~r/\s+/, " ")

  test "the manual gives the chip, the line, the header, the doors and the alert" do
    manual = flat("docs/manual.md")
    assert manual =~ "`⏸ 2 waiting on you`"
    assert manual =~ "`Waiting on you: #2063 (a question), #2075 (3 rejections)`"
    assert manual =~ "`and 1 on someone else`"
    assert manual =~ "`?waiting=me`"
    assert manual =~ "`/work?board=<id>`"
    assert manual =~ "carry `waiting_on_me`"
    assert manual =~ "*When something waits on you*"
    assert manual =~ "*Past the rejection limit*"
  end

  test "the manual says an epic's subcard list marks the rows waiting on you (#2128)" do
    manual = flat("docs/manual.md")

    assert manual =~
             "Open the epic and its subcard list marks the same rows: each one waiting on you carries a badge with its reason (*to verify*, *a question*)"

    assert manual =~ "one waiting on someone else a quieter mark naming who it waits on"
    assert manual =~ "the line's #ids above the list jump to their rows"
  end

  test "docs/agents.md names the field and the CLI line" do
    agents = flat("docs/agents.md")
    assert agents =~ "**What in an epic's tree waits on you.**"
    assert agents =~ "`waiting_on_me`"
    assert agents =~ "`on_others`"
    assert agents =~ "print a `Waiting on you:` line"
  end

  test "the README gives the chip, the header, the doors and the alert's switches" do
    readme = flat("README.md")
    assert readme =~ "`⏸ 2 waiting on you`"
    assert readme =~ "`and 1 on someone else`"
    assert readme =~ "`Waiting on you: N`"
    assert readme =~ "`waiting_on_me`"
    assert readme =~ "*When something waits on you*: *Alert me in the header*, *Email me*"
  end

  test "the packaged skill teaches the CLI line and the field" do
    skill = flat("priv/skills/slipdock/SKILL.md")
    assert skill =~ ~s(on an epic, a "Waiting on you:" line)
    assert skill =~ "waiting_on_me: count, cards, on_others, line"
    assert skill =~ ~s("Waiting on you: N" for the tree)
  end

  test "the agents page has the doors, and its CLI topic the line", %{conn: conn} do
    conn = log_in_user(conn, Slipdock.Fixtures.user_fixture())
    {:ok, _view, html} = live(conn, ~p"/help/agents")
    assert html =~ "See what in an epic&#39;s tree is waiting on you"
    assert html =~ "get_card, get_board: waiting_on_me"
    {:ok, _view, cli} = live(conn, ~p"/help/agents/cli")
    assert cli =~ "<code>on_others</code>"
    assert cli =~ "an epic whose tree is all waiting on a person has nothing workable"
  end

  test "the API guide gives the shape" do
    guide = String.replace(SlipdockWeb.APIGuide.markdown(), ~r/\s+/, " ")
    assert guide =~ "**What in an epic's tree waits on you.**"
    assert guide =~ "`{count, cards, on_others, line}`"
    assert guide =~ "plus `short`"
  end

  test "the in-app guide has it", %{conn: conn} do
    user = Slipdock.Fixtures.user_fixture()
    {:ok, view, _} = live(log_in_user(conn, user), ~p"/help/boards")
    part = view |> element("#boards-waiting") |> render()
    assert part =~ "⏸ 2 waiting on you"
    assert part =~ "When something waits on you"
    assert part =~ "slipdock card"
  end
end
