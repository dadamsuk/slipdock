# Spike #3165: how much of REST, MCP and the CLI is the same operation?
# Run from the repo root: elixir tools/spike_3165/inventory.exs
# Needs no deps: it reads the source as AST.

defmodule Inv do
  # --- REST: walk the router's scopes ------------------------------------
  def routes do
    {:ok, ast} = File.read!("lib/slipdock_web/router.ex") |> Code.string_to_quoted()
    walk(ast, "", nil) |> List.flatten() |> Enum.filter(&String.starts_with?(&1.path, "/api"))
  end

  @verbs ~w(get post put patch delete)a
  defp walk({:scope, _, args}, prefix, mod) do
    {path, alias_, body} =
      case args do
        [p, a, [do: b]] when is_binary(p) -> {p, a, b}
        [p, a, _opts, [do: b]] when is_binary(p) -> {p, a, b}
        [p, [do: b]] when is_binary(p) -> {p, nil, b}
        [a, [do: b]] -> {"", a, b}
        _ -> {"", nil, nil}
      end
    walk(body, join(prefix, path), alias_name(alias_) || mod)
  end

  defp walk({verb, _, [path, ctrl, action | _]}, prefix, mod) when verb in @verbs and is_binary(path) do
    %{verb: verb |> to_string() |> String.upcase(), path: join(prefix, path) |> norm(),
      ctrl: "#{mod}.#{alias_name(ctrl)}", action: action}
  end

  defp walk({:__block__, _, list}, p, m), do: Enum.map(list, &walk(&1, p, m))
  defp walk({:defmodule, _, [_, [do: b]]}, p, m), do: walk(b, p, m)
  defp walk(_, _, _), do: []

  defp alias_name({:__aliases__, _, parts}), do: Enum.join(parts, ".")
  defp alias_name(_), do: nil
  defp join(a, ""), do: a
  defp join(a, b), do: String.trim_trailing(a, "/") <> b

  # /api/cards/:id/move -> /api/cards/*/move
  def norm(path), do: path |> String.replace(~r/:[a-z_]+|\*[a-z_]+/, "*") |> String.trim_trailing("/")

  # --- CLI: every HTTP.<verb>("path") call, by command ---------------------
  def cli_calls do
    for file <- Path.wildcard("cli/lib/**/*.ex"),
        {:ok, ast} = file |> File.read!() |> Code.string_to_quoted(),
        call <- List.flatten(collect(ast, &http_call/1)) do
      Map.put(call, :file, file)
    end
  end

  # HTTP.post(item_path(id, "/checklist"), ...): a card's or a page's
  defp http_call({{:., _, [{:__aliases__, _, [:HTTP]}, verb]}, _, [{:item_path, _, [_, suffix]} | _]})
       when is_binary(suffix) do
    v = verb |> to_string() |> String.replace("_multipart", "") |> String.upcase()
    [%{verb: v, path: norm("/api/cards/:x" <> suffix)}, %{verb: v, path: norm("/api/pages/:x" <> suffix)}]
  end

  defp http_call({{:., _, [{:__aliases__, _, [:HTTP]}, verb]}, _, [path | _]})
       when verb in [:get, :post, :put, :patch, :delete, :post_multipart] do
    case path_string(path) do
      nil -> nil
      p -> %{verb: verb |> to_string() |> String.replace("_multipart", "") |> String.upcase(),
              path: norm("/api" <> String.replace(p, ~r/\?.*/, ""))}
    end
  end
  # The plan form (machines.ex, card_views.ex, registry.ex): {:ok, :get, "/path", ...}
  defp http_call({:{}, _, [:ok, verb, path | _]}) when verb in [:get, :post, :put, :patch, :delete] do
    case path_string(path) do
      nil -> nil
      p -> %{verb: verb |> to_string() |> String.upcase(), path: norm("/api" <> String.replace(p, ~r/\?.*/, ""))}
    end
  end

  defp http_call(_), do: nil

  # "/cards/#{enc(id)}/move" -> "/cards/:x/move"
  defp path_string(s) when is_binary(s), do: s
  defp path_string({:<<>>, _, parts}) do
    parts |> Enum.map(fn s when is_binary(s) -> s; _ -> ":x" end) |> Enum.join()
  end
  defp path_string(_), do: nil

  def collect(ast, f) do
    {_, acc} = Macro.prewalk(ast, [], fn n, acc -> {n, (case f.(n) do nil -> acc; x -> [x | acc] end)} end)
    acc
  end

  # --- MCP: which domain functions each tool calls -------------------------
  def remote_calls(file) do
    {:ok, ast} = file |> File.read!() |> Code.string_to_quoted()
    aliases = aliases(ast)
    collect(ast, fn
      {{:., _, [{:__aliases__, _, parts}, fun]}, _, args} when is_list(args) ->
        mod = expand(parts, aliases)
        if String.starts_with?(mod, "Slipdock.") and fun not in [:get_board!, :get_card!, :get, :get!],
          do: "#{mod}.#{fun}"
      _ -> nil
    end)
    |> Enum.uniq()
  end

  defp aliases(ast) do
    collect(ast, fn
      {:alias, _, [{{:., _, [{:__aliases__, _, base}, :{}]}, _, subs} | _]} ->
        for {:__aliases__, _, s} <- subs, do: {List.last(s), base ++ s}
      {:alias, _, [{:__aliases__, _, parts}]} -> [{List.last(parts), parts}]
      {:alias, _, [{:__aliases__, _, parts}, [as: {:__aliases__, _, [as]}]]} -> [{as, parts}]
      _ -> nil
    end)
    |> List.flatten() |> Map.new()
  end

  defp expand([h | t], aliases), do: Enum.join(Map.get(aliases, h, [h]) ++ t, ".")
  defp expand(other, _), do: inspect(other)
end

defmodule Inv.Calls do
  # fun name -> {remote Slipdock.* calls, local calls}, for every def/defp in a file
  def by_fun(file) do
    {:ok, ast} = file |> File.read!() |> Code.string_to_quoted()
    aliases = Inv.Aliases.of(ast)
    Inv.collect(ast, fn
      {d, _, [head, body]} when d in [:def, :defp] -> {fname(head), body}
      _ -> nil
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {name, bodies} ->
      remote = Enum.flat_map(bodies, &remotes(&1, aliases)) |> MapSet.new()
      local = Enum.flat_map(bodies, &locals/1) |> MapSet.new()
      {name, {remote, local}}
    end)
  end

  def closure(funs, start) do
    go([start], MapSet.new(), MapSet.new(), funs)
  end

  defp go([], _seen, acc, _), do: acc
  defp go([f | rest], seen, acc, funs) do
    if MapSet.member?(seen, f) or not Map.has_key?(funs, f) do
      go(rest, seen, acc, funs)
    else
      {r, l} = funs[f]
      go(MapSet.to_list(l) ++ rest, MapSet.put(seen, f), MapSet.union(acc, r), funs)
    end
  end

  defp fname({:when, _, [h | _]}), do: fname(h)
  defp fname({n, _, _}) when is_atom(n), do: n
  defp fname(_), do: :unknown

  defp remotes(body, aliases) do
    Inv.collect(body, fn
      {{:., _, [{:__aliases__, _, parts}, fun]}, _, args} when is_list(args) ->
        mod = Inv.Aliases.expand(parts, aliases)
        if String.starts_with?(mod, "Slipdock.") or String.starts_with?(mod, "SlipdockWeb.API."),
          do: "#{mod}.#{fun}"
      _ -> nil
    end)
  end

  defp locals(body) do
    Inv.collect(body, fn
      {n, _, args} when is_atom(n) and is_list(args) and n not in [:__aliases__, :., :{}, :%{}, :=, :|>, :<-, :->, :__block__, :fn, :with, :case, :if, :cond, :&] -> n
      _ -> nil
    end)
  end
end

defmodule Inv.Aliases do
  def of(ast) do
    Inv.collect(ast, fn
      {:alias, _, [{{:., _, [{:__aliases__, _, base}, :{}]}, _, subs} | _]} ->
        for {:__aliases__, _, s} <- subs, do: {List.last(s), base ++ s}
      {:alias, _, [{:__aliases__, _, parts}]} -> [{List.last(parts), parts}]
      {:alias, _, [{:__aliases__, _, parts}, [as: {:__aliases__, _, [as]}]]} -> [{as, parts}]
      _ -> nil
    end)
    |> List.flatten() |> Map.new()
  end

  def expand([h | t], aliases) when is_atom(h), do: Enum.join(Map.get(aliases, h, [h]) ++ t, ".")
  def expand(other, _), do: inspect(other)
end
