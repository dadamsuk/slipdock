defmodule SlipdockWeb.API.ActivityActorTest do
  @moduledoc """
  Who did each thing (#3189): the REST board activity and the MCP `activity`
  tool name each entry's actor, `%{kind, name}`, as the Activity panel does
  (#1735): a person, an agent (a runner's loop), a rule, and a row from
  before actors were recorded as "Someone". The user's id is not given.
  """
  use SlipdockWeb.ConnCase, async: true

  import Ecto.Query, only: [from: 2]
  import Slipdock.Fixtures

  alias Slipdock.Boards.Activity
  alias Slipdock.Repo

  setup %{conn: conn, user: user} do
    board = board_fixture(%{"name" => "Who did it", "code" => "whodid1"}, owner: user)
    Repo.delete_all(from(a in Activity, where: a.board_id == ^board.id))

    rows = [
      {"before #1735", %{}},
      {"by a rule", %{actor_kind: "automation", actor_name: "Triage"}},
      {"by an agent", %{actor_kind: "agent", actor_name: "dedev loop", user_id: user.id}},
      {"by a person", %{actor_kind: "person", actor_name: "Ash Person", user_id: user.id}}
    ]

    base = DateTime.add(DateTime.utc_now(:second), -60, :second)

    rows
    |> Enum.with_index()
    |> Enum.each(fn {{message, attrs}, i} ->
      Repo.insert!(
        struct!(
          %Activity{
            board_id: board.id,
            kind: "card",
            message: "moved “X” #{message}",
            inserted_at: DateTime.add(base, i, :second)
          },
          attrs
        )
      )
    end)

    %{conn: put_req_header(conn, "accept", "application/json"), board: board}
  end

  @expected [
    {"by a person", %{"kind" => "person", "name" => "Ash Person"}},
    {"by an agent", %{"kind" => "agent", "name" => "dedev loop"}},
    {"by a rule", %{"kind" => "automation", "name" => "Triage"}},
    {"before #1735", %{"kind" => nil, "name" => "Someone"}}
  ]

  defp assert_actors(entries) do
    got =
      Enum.map(entries, &{String.replace_prefix(&1["message"], "moved “X” ", ""), &1["actor"]})

    assert got == @expected
    assert Enum.all?(entries, &(Map.keys(&1["actor"]) |> Enum.sort() == ["kind", "name"]))
    refute Enum.any?(entries, &Map.has_key?(&1, "user_id"))
  end

  test "the REST board activity names each entry's actor", %{conn: conn, board: board} do
    body = conn |> get(~p"/api/boards/#{board.id}/activity") |> json_response(200)
    assert_actors(body["activity"])
  end

  test "the MCP activity tool names each entry's actor", %{conn: conn} do
    result =
      conn
      |> put_req_header("content-type", "application/json")
      |> post(
        "/mcp",
        Jason.encode!(%{
          jsonrpc: "2.0",
          id: 1,
          method: "tools/call",
          params: %{name: "activity", arguments: %{board: "whodid1"}}
        })
      )
      |> json_response(200)
      |> Map.fetch!("result")

    assert result["isError"] == false, inspect(result["content"])
    assert_actors(mcp_data(result)["activity"])
  end

  test "a change made through the API is named for whoever made it", ctx do
    card_fixture(hd(ctx.board.columns), %{"title" => "Made now"})
    body = ctx.conn |> get(~p"/api/boards/#{ctx.board.id}/activity?limit=1") |> json_response(200)

    assert [%{"message" => message, "actor" => %{"kind" => kind, "name" => name}}] =
             body["activity"]

    assert message =~ "Made now"
    assert kind in Activity.actor_kinds()
    assert is_binary(name) and name != ""
  end

  describe "Activity.actor/1" do
    test "a blank name reads as its kind" do
      for {kind, name} <- [
            {"person", "A deleted user"},
            {"agent", "Agent"},
            {"automation", "Automation"},
            {"email", "Email"},
            {"system", "System"}
          ] do
        assert Activity.actor(%Activity{actor_kind: kind}) == %{kind: kind, name: name}
        assert Activity.actor(%Activity{actor_kind: kind, actor_name: ""}).name == name
      end
    end

    test "an unknown kind reads as Someone" do
      assert Activity.actor(%Activity{actor_kind: "martian", actor_name: "Zed"}) ==
               %{kind: nil, name: "Someone"}
    end
  end
end
