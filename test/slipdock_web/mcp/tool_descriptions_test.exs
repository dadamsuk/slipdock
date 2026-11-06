defmodule SlipdockWeb.MCP.ToolDescriptionsTest do
  @moduledoc """
  SPEC-4 (#1865): every MCP tool's description is under 250 characters. A
  description is sent to every client in every session, so the detail goes in
  the input schema's field descriptions. One check over `tools/list` with
  meeting mode and chat capture on, so every tool the server has is listed,
  and the tools that are only listed while those are on are covered too.
  """
  use SlipdockWeb.ConnCase, async: true

  alias Slipdock.Settings
  alias SlipdockWeb.MCP.Tools

  @cap 250

  setup do
    {:ok, _} = Settings.complete_setup(%{"admin_email" => "admin@example.com"})
    :ok
  end

  defp listed(conn) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/mcp", Jason.encode!(%{jsonrpc: "2.0", id: 1, method: "tools/list", params: %{}}))
    |> json_response(200)
    |> get_in(["result", "tools"])
  end

  # The tools whose description is at the cap or over it, with their lengths.
  defp too_long(tools) do
    for %{"name" => name, "description" => text} <- tools,
        String.length(text) >= @cap,
        do: {name, String.length(text)}
  end

  test "every tool tools/list gives has a description under 250 characters", %{conn: conn} do
    tools = listed(conn)

    assert Enum.sort(Enum.map(tools, & &1["name"])) ==
             Enum.sort(Enum.map(Tools.every(), & &1.name())),
           "tools/list should list every tool here, meeting and chat tools included"

    assert Enum.all?(tools, &(is_binary(&1["description"]) and &1["description"] != ""))
    assert too_long(tools) == [], "over #{@cap - 1} characters: #{inspect(too_long(tools))}"
  end

  test "the check catches a description at the cap, and passes one just under it" do
    at_cap = %{"name" => "at_cap", "description" => String.duplicate("a", @cap)}
    under = %{"name" => "under", "description" => String.duplicate("é", @cap - 1)}

    assert too_long([at_cap, under]) == [{"at_cap", @cap}]
  end
end
