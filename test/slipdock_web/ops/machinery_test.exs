defmodule SlipdockWeb.Ops.MachineryTest do
  @moduledoc """
  The shared machinery every operation's surfaces are made with
  (`SlipdockWeb.Ops`, `Ops.MCPCall`, `Ops.REST`), on a made-up definition:
  MCP's `confirm`, an `:any` param, the REST status and the words a bad
  enum is refused in (#3187).
  """
  use ExUnit.Case, async: true

  alias SlipdockWeb.Ops

  defmodule Thing do
    @behaviour SlipdockWeb.Ops.Op

    @impl true
    def definition do
      %{
        name: "thing",
        title: "A thing",
        summary: "Does a thing.",
        verb: :post,
        path: "/api/things/:id",
        permission: {:board, :owner},
        writes?: true,
        destructive?: true,
        status: &if(&1.made, do: :created, else: :ok),
        params: [
          %{name: "thing", type: :integer, required: true, in_path: "id"},
          %{name: "kind", type: {:enum, ~w(a b c)}},
          %{name: "parts", type: :any, schema: %{type: "array", items: %{type: "string"}}},
          %{name: "limit", type: :integer, default: 10, max: 50}
        ],
        confirm: %{type: :string, doc: "The thing's name, again."}
      }
    end

    @impl true
    def confirm(%{"confirm" => "thing"}, _auth), do: :ok
    def confirm(_params, _auth), do: {:error, "not done: confirm must be \"thing\""}

    @impl true
    def run(params, _auth), do: {:ok, %{made: params["kind"] == "a", params: params}}
  end

  test "MCP's params have confirm, REST's don't, and only MCP's schema requires it" do
    assert {:ok, %{"thing" => 1}} = Ops.cast(Thing, %{"thing" => 1, "confirm" => "x"})
    assert {:ok, %{"confirm" => "x"}} = Ops.cast(Thing, %{"thing" => 1, "confirm" => "x"}, :mcp)
    # Not required by the cast: confirm/2 says what a missing one means.
    assert {:ok, params} = Ops.cast(Thing, %{"thing" => 1}, :mcp)
    refute Map.has_key?(params, "confirm")

    schema = Ops.input_schema(Thing)
    assert schema.required == ["thing", "confirm"]

    assert schema.properties.confirm == %{
             type: "string",
             description: "The thing's name, again."
           }
  end

  test "an :any param passes as sent, with the schema it gives" do
    assert {:ok, %{"parts" => %{"a" => 1}}} =
             Ops.cast(Thing, %{"thing" => 1, "parts" => %{"a" => 1}})

    assert Ops.input_schema(Thing).properties.parts == %{
             type: "array",
             items: %{type: "string"}
           }
  end

  test "an :integer with max is 1 or more, and more than max is max (#3188)" do
    cast = &Ops.cast(Thing, %{"thing" => 1, "limit" => &1})
    assert {:ok, %{"limit" => 10}} = Ops.cast(Thing, %{"thing" => 1})
    assert {:ok, %{"limit" => 7}} = cast.("7")
    assert {:ok, %{"limit" => 50}} = cast.(500)

    for bad <- [0, -3, "0"],
        do: assert(cast.(bad) == {:error, :bad_request, "limit must be a positive whole number"})

    assert cast.("lots") == {:error, :bad_request, "limit must be a number"}
  end

  test "a bad enum names every value, the last after `or`" do
    assert Ops.cast(Thing, %{"thing" => 1, "kind" => "d"}) ==
             {:error, :bad_request, "kind must be a, b or c"}
  end

  test "the MCP tool asks confirm/2 before it runs, and is destructive" do
    auth = %{assigns: %{}}

    assert Ops.MCPCall.call(Thing, %{"thing" => 1}, auth) ==
             {:error, "not done: confirm must be \"thing\""}

    assert {:ok, %{params: %{"confirm" => "thing"}}} =
             Ops.MCPCall.call(Thing, %{"thing" => 1, "confirm" => "thing"}, auth)

    assert Ops.MCPCall.destructive?(Thing)
    refute Ops.MCPCall.destructive?(Ops.MoveCard)
  end

  test "REST answers the definition's status, a function of the result here" do
    conn = Phoenix.ConnTest.build_conn()
    assert Ops.REST.run(conn, Thing, %{"id" => "1", "kind" => "a"}).status == 201
    assert Ops.REST.run(conn, Thing, %{"id" => "1", "kind" => "b"}).status == 200

    assert Ops.REST.run(conn, Ops.MoveCard, %{"id" => "x"}) ==
             {:error, :bad_request, "card must be a number"}
  end
end
