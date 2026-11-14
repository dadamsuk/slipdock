defmodule Slipdock.E2ESeedCallsTest do
  @moduledoc """
  The end-to-end scripts in `tools/e2e` seed their database with
  `mix run -e '…'`, and CI never runs them (#3126). When a function moved out
  of `Slipdock.Boards`, 45 of them went on calling it and died with
  `UndefinedFunctionError` before the browser started, and nothing noticed.

  So this reads every `mix run -e` in `tools/e2e/*.sh`, parses its Elixir,
  resolves its aliases, and checks that each module it names is loaded and
  each remote call (`Mod.fun(args)`, piped into or captured as `&Mod.fun/n`)
  is a function or macro of that arity, and that each `%Mod{}` is a struct.
  A call on a variable (`board.id`, `mod.fun()`) isn't checked: nothing can
  be known about it without running the script.

  The CLI (`SlipdockCLI…`) is a Mix project of its own in `cli/`, not loaded
  here, so a call on it is checked against `cli/lib`'s source instead: the
  module is defined there, with a `def` of that name (any arity).
  """
  use ExUnit.Case, async: true

  @dir "tools/e2e"

  describe "the scripts in tools/e2e" do
    test "every mix run -e names modules and functions that exist" do
      problems =
        for path <- Path.wildcard(Path.join(@dir, "*.sh")),
            {line, code} <- seeds(File.read!(path)),
            problem <- check(code) do
          "#{path}:#{line}: #{problem}"
        end

      assert problems == [], Enum.join(problems, "\n")
    end

    test "every mix run in them is one this test reads" do
      for path <- Path.wildcard(Path.join(@dir, "*.sh")) do
        source = File.read!(path)
        runs = length(Regex.scan(~r/\bmix run\b/, source))

        assert runs == length(seeds(source)),
               "#{path}: a `mix run` this test can't read; give it `-e '…'` in single quotes"
      end
    end

    test "there are seeds to read" do
      assert Path.join(@dir, "*.sh")
             |> Path.wildcard()
             |> Enum.flat_map(&seeds(File.read!(&1)))
             |> length() > 50
    end
  end

  describe "seeds/1" do
    test "reads a single-quoted -e, with the shell's interpolations as placeholders" do
      script = ~S"""
      echo hi
      IDS=$(mix run -e '
        board = Slipdock.Boards.get_board!('"$KB"')
        IO.puts("#{board.id} '"$BASE"'/x")
      ' | grep IDS)
      mix run --no-start -e 'Slipdock.Accounts.x('"$A"', $B)' > /dev/null
      """

      assert [{2, first}, {6, second}] = seeds(script)
      assert first =~ "get_board!(1)"
      assert first =~ ~S|"#{board.id} 1/x"|
      assert second == "Slipdock.Accounts.x(1, $B)"
    end

    test "reads the shell's escaped quote as a quote" do
      assert [{1, ~S|IO.puts('a')|}] = seeds(~S|mix run -e 'IO.puts('\''a'\'')'|)
    end
  end

  describe "check/1" do
    test "passes calls that exist, aliased, piped, captured and as structs" do
      assert check("""
             import Ecto.Query
             alias Slipdock.{Boards, Repo}
             alias Slipdock.Boards.Card, as: C
             board = Boards.get_board!(1) |> Repo.preload(:columns)
             Enum.map([1], &Boards.get_board!/1)
             q = from c in C, where: c.id == ^board.id
             %C{title: "x"}
             :crypto.strong_rand_bytes(4)
             board.id
             """) == []
    end

    test "names a function that moved out of its module" do
      assert check("""
             alias Slipdock.Boards
             Boards.create_card(nil, %{})
             """) == ["Slipdock.Boards.create_card/2 is undefined"]
    end

    test "names a call with the wrong arity, counting the pipe's argument" do
      assert check("alias Slipdock.Boards\n1 |> Boards.get_board!(2)") ==
               ["Slipdock.Boards.get_board!/2 is undefined"]

      assert check("&Slipdock.Boards.get_board!/3") ==
               ["Slipdock.Boards.get_board!/3 is undefined"]
    end

    test "names a module that doesn't exist, once" do
      assert check("""
             alias Slipdock.Gone
             Gone.a()
             Gone.b(1)
             """) == ["Slipdock.Gone is not a module"]
    end

    test "names a struct that isn't one" do
      assert check("%Slipdock.Boards{}") == ["Slipdock.Boards is not a struct"]
    end

    test "reads the CLI's modules from cli/lib's source" do
      assert check(~S|SlipdockCLI.main(["help"])|) == []
      assert check("SlipdockCLI.gone(1)") == ["SlipdockCLI.gone/1 is undefined in cli/lib"]
      assert check("SlipdockCLI.Gone.main(1)") == ["SlipdockCLI.Gone is not a module in cli/lib"]
    end

    test "names code that doesn't parse" do
      assert ["does not parse: " <> _] = check("Boards.x(")
    end
  end

  # The `mix run … -e '…'` seeds in a script, as {line, code}. The shell ends
  # a single-quoted string at the next quote, so `'"$KB"'` (out of the
  # quotes for a variable and back in) becomes the placeholder `1`, and
  # `'\''` a quote.
  defp seeds(source) do
    ~r/\bmix run\b[^\n']*?-e '/
    |> Regex.scan(source, return: :index)
    |> Enum.map(fn [{start, len}] ->
      line = source |> binary_part(0, start) |> String.split("\n") |> length()
      rest = binary_part(source, start + len, byte_size(source) - start - len)
      {line, quoted(rest, "")}
    end)
  end

  defp quoted("'\\''" <> rest, acc), do: quoted(rest, acc <> "'")

  defp quoted("'" <> rest, acc) do
    case Regex.run(~r/\A"[^"]*"'/, rest) do
      [gap] ->
        quoted(binary_part(rest, byte_size(gap), byte_size(rest) - byte_size(gap)), acc <> "1")

      nil ->
        acc
    end
  end

  defp quoted(<<c::utf8, rest::binary>>, acc), do: quoted(rest, <<acc::binary, c::utf8>>)
  defp quoted("", acc), do: acc

  # What's wrong with the calls in some code, as messages.
  defp check(code) do
    case Code.string_to_quoted(code) do
      {:ok, ast} ->
        aliases = aliases(ast)

        ast
        |> refs(aliases)
        |> Enum.uniq()
        |> Enum.flat_map(&problem/1)
        |> Enum.uniq()

      {:error, error} ->
        ["does not parse: #{inspect(error)}"]
    end
  end

  defp problem({:struct, mod}) do
    cond do
      not loaded?(mod) -> ["#{inspect(mod)} is not a module"]
      function_exported?(mod, :__struct__, 0) -> []
      true -> ["#{inspect(mod)} is not a struct"]
    end
  end

  defp problem({:call, mod, fun, arity}) do
    cond do
      cli?(mod) -> cli_problem(mod, fun, arity)
      not loaded?(mod) -> ["#{inspect(mod)} is not a module"]
      function_exported?(mod, fun, arity) or macro_exported?(mod, fun, arity) -> []
      true -> ["#{Exception.format_mfa(mod, fun, arity)} is undefined"]
    end
  end

  defp cli?(mod),
    do: mod == SlipdockCLI or String.starts_with?(Atom.to_string(mod), "Elixir.SlipdockCLI.")

  defp cli_problem(mod, fun, arity) do
    name = inspect(mod)

    source =
      "cli/lib/**/*.ex"
      |> Path.wildcard()
      |> Enum.map(&File.read!/1)
      |> Enum.find(&(&1 =~ ~r/^\s*defmodule #{Regex.escape(name)} do$/m))

    cond do
      is_nil(source) -> ["#{name} is not a module in cli/lib"]
      source =~ ~r/^\s*def #{Regex.escape(to_string(fun))}[( ]/m -> []
      true -> ["#{Exception.format_mfa(mod, fun, arity)} is undefined in cli/lib"]
    end
  end

  defp loaded?(mod), do: match?({:module, _}, Code.ensure_loaded(mod))

  # Every alias in the code, as %{Short => Full}: `alias A.B`, `alias A.{B, C}`
  # and `alias A.B, as: D`. Scripts are short, so scope is ignored.
  defp aliases(ast) do
    {_, acc} =
      Macro.prewalk(ast, %{}, fn
        {:alias, _, [{{:., _, [{:__aliases__, _, base}, :{}]}, _, children} | _]} = node, acc ->
          {node,
           Enum.reduce(children, acc, fn {:__aliases__, _, parts}, acc ->
             Map.put(acc, hd(parts), Module.concat(base ++ parts))
           end)}

        {:alias, _, [{:__aliases__, _, parts}, [as: {:__aliases__, _, [as]}]]} = node, acc ->
          {node, Map.put(acc, as, Module.concat(parts))}

        {:alias, _, [{:__aliases__, _, parts}]} = node, acc ->
          {node, Map.put(acc, List.last(parts), Module.concat(parts))}

        node, acc ->
          {node, acc}
      end)

    acc
  end

  defp resolve({:__aliases__, _, [first | rest]}, aliases),
    do: Module.concat([Map.get(aliases, first, first) | rest])

  defp resolve(atom, _aliases) when is_atom(atom), do: atom
  defp resolve(_receiver, _aliases), do: nil

  # The remote calls and structs in the code. A pipe's right side gets one
  # more argument; `&M.f/n` is a call of arity n.
  defp refs(ast, aliases) do
    {_, acc} = Macro.prewalk(ast, [], &ref/2)

    acc
    |> Enum.reverse()
    |> Enum.flat_map(fn ref ->
      case resolve(elem(ref, 1), aliases) do
        nil -> []
        mod -> [put_elem(ref, 1, mod)]
      end
    end)
  end

  defp ref({:alias, _, _}, acc), do: {nil, acc}

  defp ref({:|>, _, [left, {{:., _, [mod, fun]}, _, args} = right]}, acc) when is_atom(fun),
    do: {[left, {:__piped__, right}], [{:call, mod, fun, length(args) + 1} | acc]}

  defp ref({:__piped__, {{:., _, [_mod, _fun]}, _, args}}, acc), do: {args, acc}

  defp ref({:&, _, [{:/, _, [{{:., _, [mod, fun]}, _, []}, arity]}]}, acc) when is_integer(arity),
    do: {nil, [{:call, mod, fun, arity} | acc]}

  defp ref({:%, _, [mod, fields]}, acc), do: {fields, [{:struct, mod} | acc]}

  defp ref({{:., _, [mod, fun]}, _, args} = node, acc) when is_atom(fun) and is_list(args),
    do: {node, [{:call, mod, fun, length(args)} | acc]}

  defp ref(node, acc), do: {node, acc}
end
