defmodule SlipdockWeb.WorkDismissDocsTest do
  @moduledoc """
  Dismissing and muting on Waiting on you (#2069) as the docs describe it:
  the manual's section and its doors, docs/agents.md, the API guide's recipe and prose,
  the in-app guide, the CLI's help and the MCP tools' properties.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  @root Path.expand("../..", __DIR__)
  defp flat(path), do: @root |> Path.join(path) |> File.read!() |> String.replace(~r/\s+/, " ")

  test "the manual says how, and that it is mine alone" do
    manual = flat("docs/manual.md")
    assert manual =~ "**Taking things off your list.**"
    assert manual =~ "`slipdock work --dismiss <card>`"
    assert manual =~ "`slipdock work --mute <board>`"
    assert manual =~ "`POST /api/work/dismissed`"
    assert manual =~ "`POST /api/work/muted`"
    assert manual =~ ~s|`waiting_list: "dismiss"`|
    assert manual =~ ~s|`waiting_list: "mute"`|
    assert manual =~ "Muting is not archiving"
    assert manual =~ "a new one brings the card back"
    assert manual =~ "`3 waiting · 2 dismissed · 1 board muted`"
    assert manual =~ "slipdock work --dismissed"
  end

  test "docs/agents.md names the doors, and that an agent never does it on its own" do
    agents = flat("docs/agents.md")
    assert agents =~ "**Off a person's own list.**"
    assert agents =~ "`slipdock work --dismiss <card>`"
    assert agents =~ ~s|`update_card` with `waiting_list: "dismiss"`|
    assert agents =~ ~s|`update_board` with `waiting_list: "mute"`|
    assert agents =~ "Never dismiss or mute for a person on your own judgement"
  end

  test "the API guide gives the endpoints, the CLI and MCP" do
    guide = SlipdockWeb.APIGuide.markdown()
    assert guide =~ "B/api/work/dismissed -d '{\"card\": 57}'"
    assert guide =~ "curl -s -X DELETE -H \"$H\" B/api/work/dismissed/57"
    assert guide =~ "B/api/work/muted -d '{\"board\": \"ops\"}'"
    assert guide =~ "slipdock work --dismiss 57 / --dismissed / --undismiss 57"
    assert guide =~ "update_card waiting_list dismiss|undismiss"
    assert guide =~ "**Off your own list.**"
    assert guide =~ "`dismissed_count`"
    assert guide =~ "`waiting_hidden`"
  end

  test "the in-app guide has the part", %{conn: conn} do
    user = Slipdock.Fixtures.user_fixture()
    {:ok, view, _} = live(log_in_user(conn, user), ~p"/help/boards")
    part = view |> element("#boards-waiting") |> render()
    assert part =~ "Mute on my Waiting on you"
    assert part =~ "Muting is not archiving"
    assert part =~ "slipdock work --dismiss"
  end

  test "the CLI's help names the flags" do
    help = flat("cli/help.txt")
    assert help =~ "work --dismiss <card> | --undismiss <card> | --dismissed"
    assert help =~ "work --mute <board> | --unmute <board>"
  end

  test "the MCP tools take waiting_list" do
    assert SlipdockWeb.MCP.Tools.UpdateCard.input_schema().properties.waiting_list.enum ==
             ["dismiss", "undismiss"]

    assert SlipdockWeb.MCP.Tools.UpdateBoard.input_schema().properties.waiting_list.enum ==
             ["mute", "unmute"]
  end
end
