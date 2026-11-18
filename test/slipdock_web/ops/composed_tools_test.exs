defmodule SlipdockWeb.Ops.ComposedToolsTest do
  @moduledoc """
  The hand-composed MCP tools (several operations each, coarse on purpose:
  SPEC-4) take each param they share with a defined operation from that
  operation's definition (`SlipdockWeb.Ops.params_from/2`, #3190): the same
  name, type and doc. A tool that declares one under another name, or with
  another type or doc, fails here.

  The params shared are the card or board the tool acts on. The rest have
  no definition to come from: the operations behind them (`PATCH
  /api/cards/:id`, `POST /api/boards/:board/cards`, `PATCH
  /api/boards/:board`, `POST /api/boards`) are still hand-written, as
  `test/support/hand_written_tools.txt` lists their tools.
  """
  use ExUnit.Case, async: true

  alias SlipdockWeb.MCP.Tools
  alias SlipdockWeb.Ops

  # {tool, the definition it shares params with, the params it shares}
  @shared [
    {Tools.UpdateCard, Ops.DeleteCard, ["card"]},
    {Tools.CompleteCard, Ops.DeleteCard, ["card"]},
    {Tools.CreateCard, Ops.DeleteBoard, ["board"]},
    {Tools.UpdateBoard, Ops.DeleteBoard, ["board"]},
    # Shares none: POST /api/boards has no definition yet, so its `lists`
    # (REST's `columns`) stays MCP's own.
    {Tools.CreateBoard, nil, []}
  ]

  @doc """
  Where `tool`'s schema parts from `op`'s definition for the params named:
  `[{param, what}]`, empty when each is the definition's.
  """
  def drift(tool, op, names) do
    properties = tool.input_schema().properties
    defined = Ops.params_from(op, names)

    for name <- names,
        key = String.to_existing_atom(name),
        problem = problem(properties[key], defined[key]),
        do: {name, problem}
  end

  defp problem(same, same), do: nil
  defp problem(nil, _defined), do: "not declared: under another name?"

  defp problem(%{type: type}, %{type: defined}) when type != defined,
    do: "type #{inspect(type)}, the definition's is #{inspect(defined)}"

  defp problem(declared, defined),
    do: "#{inspect(declared)}, the definition's is #{inspect(defined)}"

  test "each composed tool takes the params it shares from the definition" do
    for {tool, op, names} <- @shared, op do
      assert drift(tool, op, names) == [],
             "#{tool.name()} declares a param it shares with #{op.definition().name} " <>
               "other than the definition does: take it with Ops.params_from/2"
    end
  end

  test "a shared param is required where the tool needs it" do
    for {tool, _op, names} <- @shared, tool != Tools.CreateCard do
      assert names -- tool.input_schema().required == [], tool.name()
    end

    # create_card takes board or, for a subcard, parent instead.
    refute "board" in Tools.CreateCard.input_schema().required
  end

  test "every composed tool's description stays under 250 characters (SPEC-4)" do
    for {tool, _op, _names} <- @shared do
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

    test "a shared param with its own doc fails, and the definition's passes" do
      assert [{"board", _}] = drift(Redocumented, Ops.DeleteBoard, ["board"])
      assert drift(Taken, Ops.DeleteBoard, ["board"]) == []
    end
  end
end
