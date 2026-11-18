defmodule SlipdockWeb.Ops.ComposedToolsTest do
  @moduledoc """
  The hand-composed MCP tools (several operations each, coarse on purpose:
  SPEC-4) take each param they share with a defined operation from that
  operation's definition (`SlipdockWeb.Ops.params_from/2`, #3190): the same
  name, type and doc. A tool that declares one under another name, or with
  another type or doc, fails here.

  Since #3361 the routes the five largest drive are defined (`PATCH
  /api/cards/:id`, `POST /api/boards/:board/cards`, `PATCH
  /api/boards/:board`, `POST /api/boards`), so each takes every param it
  shares with its route, some under a name of its own (`complete_card`'s
  `commit` is `evidence_commit`). A property named like one of its
  definition's params that it declares itself fails too.
  """
  use ExUnit.Case, async: true

  alias SlipdockWeb.MCP.Tools
  alias SlipdockWeb.Ops

  # {tool, the definition of the route it drives}; the params it shares
  # are the tool's own `shared/0`.
  @shared [
    {Tools.UpdateCard, Ops.EditCard},
    {Tools.CompleteCard, Ops.EditCard},
    {Tools.CreateCard, Ops.AddCard},
    {Tools.UpdateBoard, Ops.SetBoard},
    {Tools.CreateBoard, Ops.NewBoard}
  ]

  @doc """
  Where `tool`'s schema parts from `op`'s definition for the params named:
  `[{param, what}]`, empty when each is the definition's.
  """
  def drift(tool, op, names) do
    properties = tool.input_schema().properties
    defined = Ops.params_from(op, names)

    for entry <- names,
        name = as(entry),
        key = String.to_existing_atom(name),
        problem = problem(properties[key], defined[key]),
        do: {name, problem}
  end

  @doc """
  The properties `tool` declares itself that are named like a param of
  `op`'s, when `names` doesn't take them from it: `[name]`.
  """
  def declared(tool, op, names) do
    params = for p <- op.definition().params, do: p.name
    taken = Enum.map(names, &as/1)

    for key <- Map.keys(tool.input_schema().properties),
        name = to_string(key),
        name in params and name not in taken,
        do: name
  end

  defp as({as, _name}), do: as
  defp as(name), do: name

  defp problem(same, same), do: nil
  defp problem(nil, _defined), do: "not declared: under another name?"

  defp problem(%{type: type}, %{type: defined}) when type != defined,
    do: "type #{inspect(type)}, the definition's is #{inspect(defined)}"

  defp problem(declared, defined),
    do: "#{inspect(declared)}, the definition's is #{inspect(defined)}"

  test "each composed tool takes the params it shares from the definition" do
    for {tool, op} <- @shared do
      assert drift(tool, op, tool.shared()) == [],
             "#{tool.name()} declares a param it shares with #{op.definition().name} " <>
               "other than the definition does: take it with Ops.params_from/2"
    end
  end

  test "no composed tool declares a param of its definition's itself" do
    for {tool, op} <- @shared do
      assert declared(tool, op, tool.shared()) == [],
             "#{tool.name()} declares #{op.definition().name}'s params itself: add them to " <>
               "its shared/0, so they come from the definition"
    end
  end

  test "complete_card takes the evidence's params under its own short names" do
    properties = Tools.CompleteCard.input_schema().properties
    edit = Ops.params_from(Ops.EditCard, ["evidence_commit", "evidence_suite"])

    assert properties.commit == edit.evidence_commit
    assert properties.suite == edit.evidence_suite
    refute Map.has_key?(properties, :evidence_commit)
  end

  test "each tool requires the card or board it acts on, or the new board's name" do
    required = fn tool -> tool.input_schema().required end

    assert "card" in required.(Tools.UpdateCard)
    assert "card" in required.(Tools.CompleteCard)
    assert "board" in required.(Tools.UpdateBoard)
    assert "name" in required.(Tools.CreateBoard)
    # create_card takes board or, for a subcard, parent instead.
    refute "board" in required.(Tools.CreateCard)
  end

  test "every composed tool's description stays under 250 characters (SPEC-4)" do
    for {tool, _op} <- @shared do
      assert String.length(tool.description()) < 250, tool.name()
    end
  end

  describe "the check itself" do
    defmodule Renamed do
      def name, do: "renamed"

      def input_schema,
        do: %{properties: %{card_id: %{type: "integer"}, title: %{type: "string"}}}
    end

    defmodule Retyped do
      def name, do: "retyped"
      def input_schema, do: %{properties: %{card: %{type: "string"}}}
    end

    defmodule Redocumented do
      def name, do: "redocumented"

      def input_schema,
        do: %{properties: %{board: %{type: "string", description: "Which board."}}}
    end

    defmodule Taken do
      def name, do: "taken"
      def input_schema, do: %{properties: Ops.params_from(Ops.DeleteBoard, ["board"])}
    end

    test "a shared param under another name fails" do
      assert drift(Renamed, Ops.DeleteCard, ["card"]) == [
               {"card", "not declared: under another name?"}
             ]
    end

    test "a shared param with another type fails" do
      assert drift(Retyped, Ops.DeleteCard, ["card"]) == [
               {"card", ~s(type "string", the definition's is "integer")}
             ]
    end

    test "a param taken under another name is checked under that name" do
      assert drift(Taken, Ops.DeleteBoard, [{"board", "board"}]) == []
      assert [{"place", _}] = drift(Taken, Ops.DeleteBoard, [{"place", "board"}])
    end

    test "a property named like a definition's param, declared by the tool, is found" do
      assert declared(Redocumented, Ops.DeleteBoard, []) == ["board"]
      assert declared(Redocumented, Ops.DeleteBoard, ["board"]) == []
    end

    test "a shared param with its own doc fails, and the definition's passes" do
      assert [{"board", _}] = drift(Redocumented, Ops.DeleteBoard, ["board"])
      assert drift(Taken, Ops.DeleteBoard, ["board"]) == []
    end
  end
end
