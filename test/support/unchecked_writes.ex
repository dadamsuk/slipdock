defmodule Slipdock.UncheckedWrites do
  @moduledoc """
  SPIKE #3162, not for merging: which context functions write without asking
  who is writing, read from the source's AST (nothing is loaded or run).

  A function WRITES when it, or anything it calls (in any context module,
  followed through aliases), calls a `Repo` write. It is CHECKED when it, or
  a function of its own module that it calls, asks `Slipdock.Policy` or
  `Slipdock.Access` (or a `can_…?`, `…_permission`, `authorize…`, `may_…?`
  function). A check made in another module doesn't count: that is the
  caller trusting somebody else's door.
  """

  @repo_writes ~w(insert insert! update update! delete delete! insert_all update_all
                  delete_all insert_or_update insert_or_update!)a

  @check_modules ~w(Access Policy Authorize)
  @check_name ~r/^(can_.*\?|may_.*\?|.*_permission(_now)?|authorize.*|owner\?|.*writable\?|in_person\?|check_access|allowed\?)$/

  @doc """
  Every public context function under `root` that writes and asks nobody, as
  sorted `"Mod.fun/arity"` strings: what the repo check holds to its list.
  """
  def unchecked(root) do
    contexts =
      scan(
        Path.wildcard(Path.join(root, "lib/slipdock/**/*.ex")) ++
          Path.wildcard(Path.join(root, "lib/slipdock.ex"))
      )

    funs = Map.new(for m <- contexts, f <- m.funs, do: {{m.name, f.name, f.arity}, f})
    by_name = Enum.group_by(Map.keys(funs), fn {m, n, _a} -> {m, n} end)
    writes = fixpoint(funs, by_name, & &1.direct_write, fn _ -> true end)

    checks =
      fixpoint(funs, by_name, & &1.direct_check, fn {from, to} -> elem(from, 0) == elem(to, 0) end)

    for(
      {{m, n, a} = key, f} <- funs,
      f.public,
      MapSet.member?(writes, key),
      not MapSet.member?(checks, key),
      do: "#{m}.#{n}/#{a}"
    )
    |> Enum.sort()
  end

  def run(root, argv) do
    contexts =
      scan(
        Path.wildcard(Path.join(root, "lib/slipdock/**/*.ex")) ++
          [Path.join(root, "lib/slipdock.ex")]
      )

    doors = scan(Path.wildcard(Path.join(root, "lib/slipdock_web/**/*.ex")))

    funs =
      Map.new(
        for m <- contexts, f <- m.funs, do: {{m.name, f.name, f.arity}, Map.put(f, :file, m.file)}
      )

    by_name = Enum.group_by(Map.keys(funs), fn {m, n, _a} -> {m, n} end)

    writes = fixpoint(funs, by_name, & &1.direct_write, fn _ -> true end)
    # A check counts only inside the function's own module.
    checks =
      fixpoint(funs, by_name, & &1.direct_check, fn {from, to} -> elem(from, 0) == elem(to, 0) end)

    public_writes =
      for {key, f} <- funs, f.public, MapSet.member?(writes, key), do: {key, f}

    unchecked = for {key, f} <- public_writes, not MapSet.member?(checks, key), do: {key, f}
    unchecked_keys = MapSet.new(unchecked, &elem(&1, 0))
    unchecked_names = MapSet.new(unchecked, fn {{m, n, _}, _} -> {m, n} end)

    door_calls =
      for m <- doors,
          f <- m.funs,
          {mod, name, arity} <- f.calls,
          MapSet.member?(unchecked_names, {mod, name}),
          do: %{
            file: m.file,
            door: door(m.file),
            caller: "#{f.name}/#{f.arity}",
            callee: {mod, name, arity},
            caller_checks: f.direct_check or local_check?(m, f)
          }

    summary(root, contexts, public_writes, unchecked, unchecked_keys, door_calls)

    if "--list" in argv do
      IO.puts("\n== every unchecked public write ==")

      for {{m, n, a}, f} <- Enum.sort(unchecked),
          do: IO.puts("#{m}.#{n}/#{a}\t#{actor(f)}\t#{Path.relative_to(f.file, root)}")
    end

    if "--doors" in argv do
      IO.puts("\n== every door call to an unchecked write ==")

      for c <- Enum.sort_by(door_calls, &{&1.file, &1.caller}) do
        {m, n, a} = c.callee

        IO.puts(
          "#{Path.relative_to(c.file, root)}\t#{c.caller}\t#{m}.#{n}/#{a}\t#{if c.caller_checks, do: "checks", else: "NO CHECK IN SIGHT"}"
        )
      end
    end
  end

  defp summary(root, contexts, public_writes, unchecked, _keys, door_calls) do
    IO.puts("context modules: #{length(contexts)}")
    IO.puts("public functions that write: #{length(public_writes)}")
    IO.puts("  checked in their own module: #{length(public_writes) - length(unchecked)}")
    IO.puts("  unchecked: #{length(unchecked)}")
    with_actor = Enum.count(unchecked, fn {_, f} -> actor(f) == "takes a user" end)
    IO.puts("    of those, take a user or actor but never ask about it: #{with_actor}")
    IO.puts("    take nobody: #{length(unchecked) - with_actor}")

    called = MapSet.new(door_calls, fn c -> {elem(c.callee, 0), elem(c.callee, 1)} end)
    IO.puts("unchecked writes a door calls by name: #{MapSet.size(called)}")
    IO.puts("door call sites to an unchecked write: #{length(door_calls)}")
    blind = Enum.reject(door_calls, & &1.caller_checks)
    IO.puts("  where the calling function shows no check of its own: #{length(blind)}")

    IO.puts("\n== unchecked writes by context (door-called / all) ==")

    unchecked
    |> Enum.group_by(fn {{m, _, _}, _} -> context(m) end)
    |> Enum.map(fn {ctx, list} ->
      door = Enum.count(list, fn {{m, n, _}, _} -> MapSet.member?(called, {m, n}) end)
      {ctx, door, length(list)}
    end)
    |> Enum.sort_by(fn {_, door, all} -> {-door, -all} end)
    |> Enum.each(fn {ctx, door, all} ->
      IO.puts("#{String.pad_trailing(ctx, 28)} #{door} / #{all}")
    end)

    IO.puts("\n== door call sites by door (no check in sight / all) ==")

    door_calls
    |> Enum.group_by(& &1.door)
    |> Enum.sort_by(fn {_, l} -> -length(l) end)
    |> Enum.each(fn {door, l} ->
      IO.puts(
        "#{String.pad_trailing(door, 28)} #{Enum.count(l, &(not &1.caller_checks))} / #{length(l)}"
      )
    end)

    _ = root
  end

  # "Boards.Tags" -> "Boards.Tags"; "Wiki.Sharing" -> "Wiki"; top-level otherwise.
  defp context(mod) do
    case String.split(mod, ".") do
      ["Slipdock", "Boards", sub | _] -> "Boards." <> sub
      ["Slipdock", top | _] -> top
      other -> Enum.join(other, ".")
    end
  end

  defp door(file) do
    cond do
      file =~ "/mcp/" -> "MCP"
      file =~ "/controllers/api/" -> "REST API"
      file =~ "/controllers/" -> "controllers (browser)"
      file =~ ~r{/live/.*component} -> "LiveComponents"
      file =~ "/live/" -> "LiveViews"
      true -> "other web"
    end
  end

  defp actor(f), do: if(f.takes_actor, do: "takes a user", else: "takes nobody")

  defp local_check?(m, f) do
    locals = Map.new(m.funs, &{{&1.name, &1.arity}, &1})
    walk_local(f, locals, MapSet.new())
  end

  defp walk_local(f, locals, seen) do
    Enum.any?(f.calls, fn
      {:local, name, arity} ->
        key = {name, arity}

        case {MapSet.member?(seen, key), locals[key]} do
          {false, %{} = g} -> g.direct_check or walk_local(g, locals, MapSet.put(seen, key))
          _ -> false
        end

      _ ->
        false
    end)
  end

  # Least fixpoint: a function has the property if it has it directly or calls
  # (along an edge `follow?` allows) one that does.
  defp fixpoint(funs, by_name, direct?, follow?) do
    start = for {key, f} <- funs, direct?.(f), into: MapSet.new(), do: key
    grow(funs, by_name, start, follow?)
  end

  defp grow(funs, by_name, set, follow?) do
    next =
      for {key, f} <- funs,
          not MapSet.member?(set, key),
          Enum.any?(f.calls, fn call -> reaches?(key, call, by_name, set, follow?) end),
          into: set,
          do: key

    if MapSet.size(next) == MapSet.size(set), do: set, else: grow(funs, by_name, next, follow?)
  end

  defp reaches?({m, _, _} = from, {:local, name, arity}, _by_name, set, follow?) do
    to = {m, name, arity}
    MapSet.member?(set, to) and follow?.({from, to})
  end

  defp reaches?(from, {mod, name, _arity}, by_name, set, follow?) do
    # Arity is not matched across modules: defaults and pipes hide it.
    Enum.any?(Map.get(by_name, {mod, name}, []), fn to ->
      MapSet.member?(set, to) and follow?.({from, to})
    end)
  end

  ## Reading a file ----------------------------------------------------------

  defp scan(files) do
    Enum.flat_map(files, fn file ->
      case Code.string_to_quoted(File.read!(file), columns: false) do
        {:ok, ast} -> modules(ast, file, nil)
        _ -> []
      end
    end)
  end

  defp modules({:defmodule, _, [{:__aliases__, _, parts}, [do: body]]}, file, parent) do
    name = Enum.join(if(parent, do: [parent | parts], else: parts), ".")
    {nested, own} = body |> block() |> Enum.split_with(&match?({:defmodule, _, _}, &1))
    aliases = aliases(own, name)

    funs =
      own
      |> Enum.flat_map(&defs(&1, aliases, name))
      |> Enum.group_by(&{&1.name, &1.arity})
      |> Enum.map(fn {_, clauses} -> merge(clauses) end)

    [%{name: name, file: file, funs: funs} | Enum.flat_map(nested, &modules(&1, file, name))]
  end

  defp modules({:__block__, _, list}, file, parent),
    do: Enum.flat_map(list, &modules(&1, file, parent))

  defp modules(_, _file, _parent), do: []

  defp block({:__block__, _, list}), do: list
  defp block(other), do: [other]

  defp aliases(forms, self) do
    Enum.reduce(forms, %{"__MODULE__" => self}, fn
      {:alias, _, [{:__aliases__, _, parts}]}, acc ->
        Map.put(acc, to_string(List.last(parts)), Enum.join(parts, "."))

      {:alias, _, [{:__aliases__, _, parts}, [as: {:__aliases__, _, [as]}]]}, acc ->
        Map.put(acc, to_string(as), Enum.join(parts, "."))

      {:alias, _, [{{:., _, [{:__aliases__, _, parts}, :{}]}, _, subs}]}, acc ->
        Enum.reduce(subs, acc, fn {:__aliases__, _, sub}, acc ->
          Map.put(acc, to_string(List.last(sub)), Enum.join(parts ++ sub, "."))
        end)

      _, acc ->
        acc
    end)
  end

  defp defs({kind, _, [head, body]}, aliases, self) when kind in [:def, :defp] do
    {name, args} = head(head)
    {calls, write, check} = body(body, aliases, self)

    [
      %{
        name: name,
        arity: length(args),
        public: kind == :def,
        calls: calls,
        direct_write: write,
        direct_check: check,
        takes_actor: Enum.any?(args, &actor_arg?/1)
      }
    ]
  end

  defp defs(_, _aliases, _self), do: []

  defp head({:when, _, [head | _]}), do: head(head)
  defp head({name, _, args}) when is_atom(name), do: {name, args || []}

  defp merge([first | _] = clauses) do
    %{
      first
      | calls: clauses |> Enum.flat_map(& &1.calls) |> Enum.uniq(),
        direct_write: Enum.any?(clauses, & &1.direct_write),
        direct_check: Enum.any?(clauses, & &1.direct_check),
        takes_actor: Enum.any?(clauses, & &1.takes_actor)
    }
  end

  defp actor_arg?(arg) do
    {_, found} =
      Macro.prewalk(arg, false, fn
        {name, _, ctx} = node, acc when is_atom(name) and is_atom(ctx) ->
          {node,
           acc or
             to_string(name) =~
               ~r/^_?(user|actor|by|scope|current_user|owner|granted_by|admin|conn|context)$/}

        {:__aliases__, _, parts} = node, acc ->
          {node, acc or List.last(parts) == :User}

        node, acc ->
          {node, acc}
      end)

    found
  end

  defp body(body, aliases, self) do
    {_, {calls, write, check}} =
      Macro.prewalk(body, {[], false, false}, fn
        # Mod.fun(args)
        {{:., _, [{:__aliases__, _, parts}, fun]}, _, args} = node, {calls, w, c}
        when is_atom(fun) ->
          mod = resolve(parts, aliases)
          last = mod |> String.split(".") |> List.last()

          w = w or (last == "Repo" and fun in @repo_writes) or last == "Multi"
          c = c or last in @check_modules or to_string(fun) =~ @check_name
          {node, {[{mod, fun, length(args)} | calls], w, c}}

        # &Mod.fun/n
        {:&, _, [{:/, _, [{{:., _, [{:__aliases__, _, parts}, fun]}, _, _}, arity]}]} = node,
        {calls, w, c} ->
          {node, {[{resolve(parts, aliases), fun, arity} | calls], w, c}}

        # __MODULE__.fun(args)
        {{:., _, [{:__MODULE__, _, _}, fun]}, _, args} = node, {calls, w, c} ->
          {node, {[{self, fun, length(args)} | calls], w, c}}

        # x |> fun(args): one more argument than written
        {:|>, _, [_, {fun, _, args}]} = node, {calls, w, c} when is_atom(fun) and is_list(args) ->
          {node,
           {[{:local, fun, length(args) + 1} | calls], w, c or to_string(fun) =~ @check_name}}

        # &fun/n
        {:&, _, [{:/, _, [{fun, _, _}, arity]}]} = node, {calls, w, c}
        when is_atom(fun) and is_integer(arity) ->
          {node, {[{:local, fun, arity} | calls], w, c}}

        # fun(args)
        {fun, _, args} = node, {calls, w, c} when is_atom(fun) and is_list(args) ->
          {node, {[{:local, fun, length(args)} | calls], w, c or to_string(fun) =~ @check_name}}

        node, acc ->
          {node, acc}
      end)

    {Enum.uniq(calls), write, check}
  end

  defp resolve(parts, aliases) do
    [first | rest] =
      Enum.map(parts, fn
        {:__MODULE__, _, _} -> "__MODULE__"
        part when is_atom(part) -> to_string(part)
        _ -> "?"
      end)

    parts = [first | rest]

    case aliases[first] do
      nil -> Enum.join(parts, ".")
      full -> Enum.join([full | rest], ".")
    end
  end
end
