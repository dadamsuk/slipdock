defmodule Slipdock.UncheckedWrites do
  @moduledoc """
  Which context functions write without asking who is writing, read from
  the source's AST: nothing is loaded or run (#3162, #3168; W-1945
  §Permissions, *Where authorisation lives*).

  A public function under `lib/slipdock/` WRITES when it, or anything it
  calls in any context module (followed through aliases), calls a `Repo`
  write or builds an `Ecto.Multi`. It ASKS when it, or a function of its own
  module that it calls, calls `Slipdock.Policy.authorize` or
  `Slipdock.Policy.can?`. A check made in another module doesn't count: that
  is the caller trusting somebody else's door. `Policy.as_system/2` is not
  asking: it says nobody is behind the write.

  `test/slipdock/unchecked_writes_test.exs` holds the result to
  `test/support/unchecked_writes.txt`.
  """

  @repo_writes ~w(insert insert! update update! delete delete! insert_all update_all
                  delete_all insert_or_update insert_or_update!)a

  # The calls that ask: `Slipdock.Policy.authorize/2,3` and `can?/2,3`.
  @policy "Slipdock.Policy"
  @asks [:authorize, :can?]

  @doc """
  Every public context function under `root` that writes and asks nobody, as
  sorted `"Mod.fun/arity"` strings: what the repo check holds to its list.
  """
  def unchecked(root) do
    funs = functions(root)
    by_name = Enum.group_by(Map.keys(funs), fn {m, n, _a} -> {m, n} end)
    writes = fixpoint(funs, by_name, & &1.direct_write, fn _ -> true end)
    checks = fixpoint(funs, by_name, & &1.direct_check, &same_module?/1)

    funs
    |> Enum.filter(fn {key, f} ->
      f.public and MapSet.member?(writes, key) and not MapSet.member?(checks, key)
    end)
    |> Enum.map(fn {{m, n, a}, _} -> "#{m}.#{n}/#{a}" end)
    |> Enum.sort()
  end

  # Every function of every context module, by `{module, name, arity}`.
  defp functions(root) do
    files =
      Path.wildcard(Path.join(root, "lib/slipdock/**/*.ex")) ++
        Path.wildcard(Path.join(root, "lib/slipdock.ex"))

    Map.new(for m <- scan(files), f <- m.funs, do: {{m.name, f.name, f.arity}, f})
  end

  # A check counts only inside the function's own module.
  defp same_module?({from, to}), do: elem(from, 0) == elem(to, 0)

  @doc """
  The difference between what `unchecked/1` finds under `root` and the
  `listed` lines: `{unlisted, stale}`. `unlisted` write and ask nobody but
  aren't on the list; `stale` are on the list but now ask, or are gone.
  The check passes when both are empty.
  """
  def compare(root, listed) do
    found = unchecked(root)
    {found -- listed, listed -- found}
  end

  @doc "The lines of a list file: one `Mod.fun/arity` each; blanks and `#` comments skipped."
  def read_list(path) do
    path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
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
        direct_check: check
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
        direct_check: Enum.any?(clauses, & &1.direct_check)
    }
  end

  defp body(body, aliases, self) do
    {_, {calls, write, check}} =
      Macro.prewalk(body, {[], false, false}, fn node, {calls, w, c} ->
        case call(node, aliases, self) do
          nil ->
            {node, {calls, w, c}}

          {mod, fun, _arity} = found ->
            {node, {[found | calls], w or writes?(mod, fun), c or asks?(mod, fun)}}
        end
      end)

    {Enum.uniq(calls), write, check}
  end

  defp writes?(:local, _fun), do: false

  defp writes?(mod, fun) do
    last = mod |> String.split(".") |> List.last()
    (last == "Repo" and fun in @repo_writes) or last == "Multi"
  end

  defp asks?(mod, fun), do: mod == @policy and fun in @asks

  # The call a node makes, as `{module | :local, fun, arity}`, or nil.
  # Mod.fun(args)
  defp call({{:., _, [{:__aliases__, _, parts}, fun]}, _, args}, aliases, _self)
       when is_atom(fun),
       do: {resolve(parts, aliases), fun, length(args)}

  # &Mod.fun/n
  defp call(
         {:&, _, [{:/, _, [{{:., _, [{:__aliases__, _, parts}, fun]}, _, _}, arity]}]},
         aliases,
         _
       ),
       do: {resolve(parts, aliases), fun, arity}

  # __MODULE__.fun(args)
  defp call({{:., _, [{:__MODULE__, _, _}, fun]}, _, args}, _aliases, self),
    do: {self, fun, length(args)}

  # x |> fun(args): one more argument than written
  defp call({:|>, _, [_, {fun, _, args}]}, _aliases, _self) when is_atom(fun) and is_list(args),
    do: {:local, fun, length(args) + 1}

  # &fun/n
  defp call({:&, _, [{:/, _, [{fun, _, _}, arity]}]}, _aliases, _self)
       when is_atom(fun) and is_integer(arity),
       do: {:local, fun, arity}

  # fun(args)
  defp call({fun, _, args}, _aliases, _self) when is_atom(fun) and is_list(args),
    do: {:local, fun, length(args)}

  defp call(_node, _aliases, _self), do: nil

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
