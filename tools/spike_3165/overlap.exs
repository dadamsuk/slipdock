# Spike #3165: the overlap table. elixir tools/spike_3165/overlap.exs
Code.require_file("tools/spike_3165/inventory.exs")
routes = Inv.routes()
key = fn r -> "#{r.verb} #{r.path}" end
ctrl_file = fn mod ->
  base = mod |> String.split(".") |> List.last() |> Macro.underscore()
  Path.wildcard("lib/slipdock_web/controllers/**/#{base}.ex") |> List.first()
end
route_calls = for r <- routes, do: {r, Inv.Calls.closure(Inv.Calls.by_fun(ctrl_file.(r.ctrl)), r.action)}
freq = route_calls |> Enum.flat_map(fn {_, c} -> MapSet.to_list(c) end) |> Enum.frequencies()
generic? = fn f -> Map.get(freq, f, 0) > 8 or f =~ ~r/SlipdockWeb|Actor|Repo|Plan|\.(get|list|fetch|preload|visible|resolve|count|by_|for_|path|url|format|parse|to_)/ end

# MCP -> routes: the heuristic (shared domain call), plus three tools it can't see
manual = %{"get_guide" => ["GET /api/guide"], "update_card" => ["PATCH /api/cards/*"],
           "verify_card" => ["POST /api/cards/*/verify"]}
tools = for f <- Path.wildcard("lib/slipdock_web/mcp/tools/*.ex") do
  t = Path.basename(f, ".ex")
  sig = Inv.Calls.closure(Inv.Calls.by_fun(f), :call) |> Enum.reject(generic?) |> MapSet.new()
  hits = for {r, rc} <- route_calls, not MapSet.disjoint?(sig, rc), do: key.(r)
  {t, Enum.uniq(hits ++ Map.get(manual, t, []))}
end
mcp = tools |> Enum.flat_map(&elem(&1, 1)) |> MapSet.new()
cli = Inv.cli_calls() |> Enum.map(&"#{&1.verb} #{String.replace(&1.path, ~r/\*[^\/]*/, "*")}")
      |> MapSet.new() |> MapSet.intersection(MapSet.new(routes, key))
all = MapSet.new(routes, key)
group = fn k ->
  cond do
    k =~ ~r{/api/(runner|admin|deployments|oauth|machine|machines)(/|$)} -> "machine (runner daemon, admin, deploy)"
    k =~ ~r{/api/(wiki/sync|vaults/\*/sync|vault-sync)} -> "machine (wiki sync)"
    true -> "people and agents"
  end
end
IO.puts("| Routes | All | CLI | MCP | both | CLI only | MCP only | neither |\n|---|---|---|---|---|---|---|---|")
for {g, ks} <- Enum.group_by(all, group) |> Enum.sort() do
  s = MapSet.new(ks)
  c = MapSet.intersection(s, cli); m = MapSet.intersection(s, mcp)
  b = MapSet.intersection(c, m)
  IO.puts("| #{g} | #{MapSet.size(s)} | #{MapSet.size(c)} | #{MapSet.size(m)} | #{MapSet.size(b)} | #{MapSet.size(MapSet.difference(c, m))} | #{MapSet.size(MapSet.difference(m, c))} | #{MapSet.size(s) - MapSet.size(MapSet.union(c, m))} |")
end
IO.puts("\nMCP tools: #{length(tools)}; with a REST route: #{Enum.count(tools, fn {_, h} -> h != [] end)}")
IO.puts("MCP tools reaching >1 route (multiplexed): #{Enum.count(tools, fn {_, h} -> length(h) > 1 end)}")
if System.get_env("LIST"), do: for(k <- Enum.sort(MapSet.difference(all, MapSet.union(cli, mcp))), do: IO.puts("  neither: #{k}"))
