defmodule Slipdock.OpsCheckTest do
  @moduledoc """
  An operation with a definition (`SlipdockWeb.Ops.all/0`, #3183) is written
  once: its MCP tool is made with `use SlipdockWeb.Ops.MCPTool`, its CLI
  request goes through `SlipdockCLI.Op`, and its route is the router's. A
  second hand-written copy on either surface fails here (#3186).

  The MCP tools still written by hand are listed in
  `test/support/hand_written_tools.txt`; a hand-written tool not on it fails,
  and so does a line whose tool is now made from a definition or is gone.

  A repo check (`test/repo_checks.txt`): it reads `lib/` and `cli/lib/` and
  runs in `mix pre_push`.
  """
  use ExUnit.Case, async: true

  alias SlipdockWeb.MCP.Tools
  alias SlipdockWeb.Ops

  @root Path.expand("../..", __DIR__)
  @list Path.join(@root, "test/support/hand_written_tools.txt")

  defp defined, do: Map.new(Ops.all(), &{&1.definition().name, &1})

  defp made?(tool), do: made_from(tool) != nil

  defp listed do
    @list
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
  end

  @doc "MCP tool modules named like a defined operation but not made from it."
  def hand_written_duplicates(tools, defined) do
    for tool <- tools,
        Map.has_key?(defined, tool.name()),
        made_from(tool) != defined[tool.name()],
        do: tool.name()
  end

  # The definition a tool is made from (`Ops.MCPTool`'s `__op__/0`), or nil.
  defp made_from(tool) do
    Code.ensure_loaded!(tool)
    if function_exported?(tool, :__op__, 0), do: tool.__op__()
  end

  @doc """
  The `HTTP.<verb>("<path>"` literals in `sources` (`{file, text}`) that
  make a defined operation's request by hand: `[{file, op name}]`.
  """
  def cli_duplicates(sources, ops) do
    patterns = Enum.map(ops, &{&1.definition().name, request_pattern(&1.definition())})

    for {file, text} <- sources,
        [_, verb, path] <- Regex.scan(~r/HTTP\.(get|post|patch|put|delete)\(\s*"([^"]*)"/, text),
        {name, {op_verb, regex}} <- patterns,
        verb == op_verb and Regex.match?(regex, path),
        do: {file, name}
  end

  # "/api/cards/:id/move" matches "/cards/#{id}/move" and "/cards/#{enc(c)}/move?x=1".
  defp request_pattern(%{verb: verb, path: path}) do
    segments =
      path
      |> String.replace_prefix("/api", "")
      |> String.split("/", trim: true)
      |> Enum.map(fn
        ":" <> _ -> "(?:\#\\{[^}]*\\}|[^/?#]+)"
        literal -> Regex.escape(literal)
      end)

    {to_string(verb), Regex.compile!("\\A/" <> Enum.join(segments, "/") <> "(?:\\?.*)?\\z")}
  end

  defp cli_sources do
    for file <- Path.wildcard(Path.join(@root, "cli/lib/**/*.ex")),
        Path.basename(file) != "op.ex",
        do: {Path.relative_to(file, @root), File.read!(file)}
  end

  test "an MCP tool named like a defined operation is made from its definition" do
    assert hand_written_duplicates(Tools.every(), defined()) == [],
           "These MCP tools are written by hand, but their operation has a definition " <>
             "in SlipdockWeb.Ops.all/0: make each `use SlipdockWeb.Ops.MCPTool, op: …` " <>
             "and drop its own input_schema/0 and call/2"
  end

  test "a tool made from a definition declares nothing of its own" do
    for tool <- Tools.every(), made?(tool) do
      source = File.read!(to_string(tool.module_info(:compile)[:source]))

      refute source =~ ~r/def (input_schema|call|description|name)\b/,
             "#{inspect(tool)} is made from #{inspect(tool.__op__())}: its schema, call and " <>
               "description come from there, not from the tool"

      assert tool.__op__() in Ops.all(),
             "#{inspect(tool)} is made from #{inspect(tool.__op__())}, which isn't in Ops.all/0"
    end
  end

  test "every hand-written MCP tool is listed, and every line is still needed" do
    hand_written = for tool <- Tools.every(), not made?(tool), do: tool.name()
    names = Enum.map(Tools.every(), & &1.name())

    assert hand_written -- listed() == [],
           "These MCP tools are written by hand: make each from an operation's definition " <>
             "(SlipdockWeb.Ops, `use SlipdockWeb.Ops.MCPTool`), or, if it combines several " <>
             "operations, add it to test/support/hand_written_tools.txt: " <>
             Enum.join(hand_written -- listed(), ", ")

    stale = Enum.reject(listed(), &(&1 in hand_written))

    assert stale == [],
           "These are made from a definition now (or are gone" <>
             if(stale -- names == [], do: "", else: ": #{Enum.join(stale -- names, ", ")}") <>
             "): take them off test/support/hand_written_tools.txt: " <> Enum.join(stale, ", ")

    assert listed() -- Enum.uniq(listed()) == [], "a tool is listed twice"
  end

  test "no CLI command builds a defined operation's request by hand" do
    assert cli_duplicates(cli_sources(), Ops.all()) == [],
           "These CLI files make a defined operation's request by hand: call " <>
             "SlipdockCLI.Op.run(<command>, words, opts) instead (its route and params " <>
             "come from cli/priv/ops.json)"
  end

  test "every defined operation's CLI command goes through SlipdockCLI.Op" do
    text = Enum.map_join(cli_sources(), "\n", &elem(&1, 1))

    for op <- Ops.all(), command = op.definition()[:cli][:command] do
      assert text =~ ~s{SlipdockCLI.Op.run("#{command}"},
             "#{op.definition().name}: no CLI command calls SlipdockCLI.Op.run(\"#{command}\", …)"
    end
  end

  test "the route each definition names is the router's" do
    routes = for r <- Phoenix.Router.routes(SlipdockWeb.Router), do: {r.verb, r.path}

    for op <- Ops.all(), d = op.definition() do
      assert {d.verb, d.path} in routes, "#{d.name}: no #{d.verb} #{d.path} in the router"
    end
  end

  describe "the checks themselves" do
    defmodule HandMove do
      def name, do: "move_card"
    end

    defmodule MadeMove do
      def name, do: "move_card"
      def __op__, do: SlipdockWeb.Ops.MoveCard
    end

    test "a hand-written tool for a defined operation is found, a made one isn't" do
      assert hand_written_duplicates([HandMove, MadeMove], defined()) == ["move_card"]
    end

    test "a hand-built CLI request for a defined operation is found, in any of its forms" do
      found =
        cli_duplicates(
          [
            {"a.ex", ~S|HTTP.post("/cards/#{id}/move", %{column: c})|},
            {"b.ex", ~S|then(&HTTP.post("/cards/#{enc(String.trim(id))}/move?x=1", &1))|},
            {"c.ex", ~S|HTTP.post( "/cards/42/move", %{})|}
          ],
          Ops.all()
        )

      assert found == [{"a.ex", "move_card"}, {"b.ex", "move_card"}, {"c.ex", "move_card"}]
    end

    test "another route, or another verb, isn't a duplicate" do
      assert cli_duplicates(
               [
                 {"a.ex", ~S|HTTP.get("/cards/#{id}/move")|},
                 {"b.ex", ~S|HTTP.post("/cards/#{id}/moves")|},
                 {"c.ex", ~S|HTTP.post("/cards/#{id}/move/undo")|},
                 {"d.ex", ~S|HTTP.post("/boards/#{id}/move")|}
               ],
               Ops.all()
             ) == []
    end
  end
end
