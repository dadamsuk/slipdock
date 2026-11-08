defmodule SlipdockWeb.WaitingOnMeDocsTest do
  @moduledoc """
  What in an epic's tree waits on you (#2095) as the docs describe it: the
  manual, docs/agents.md, the API guide and the in-app guide.
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

  test "docs/agents.md names the field and the CLI line" do
    agents = flat("docs/agents.md")
    assert agents =~ "**What in an epic's tree waits on you.**"
    assert agents =~ "`waiting_on_me`"
    assert agents =~ "`on_others`"
    assert agents =~ "print a `Waiting on you:` line"
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
