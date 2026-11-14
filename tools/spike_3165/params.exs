# Spike #3165: do an MCP tool and the REST action it wraps take the same params?
# MIX_ENV=test mix run --no-start tools/spike_3165/params.exs
Code.require_file("tools/spike_3165/inventory.exs")

# The string keys a controller action reads: params["x"], %{"x" => _}, Map.get(params, "x")
defmodule Inv.Params do
  def of(file, action) do
    {:ok, ast} = file |> File.read!() |> Code.string_to_quoted()
    funs = Inv.collect(ast, fn {d, _, [h, b]} when d in [:def, :defp] -> {name(h), {h, b}}; _ -> nil end)
           |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    reach = reach(funs, [action], MapSet.new())
    funs |> Enum.filter(fn {n, _} -> n in reach end) |> Enum.flat_map(fn {_, hb} -> Enum.flat_map(hb, &keys/1) end)
    |> MapSet.new() |> MapSet.difference(MapSet.new(~w(id board_id card_id)))
  end
  defp reach(_, [], seen), do: seen
  defp reach(funs, [f | r], seen) do
    if f in seen or not Map.has_key?(funs, f), do: reach(funs, r, seen), else:
      reach(funs, Enum.flat_map(funs[f], fn hb -> Inv.collect(hb, fn {n, _, a} when is_atom(n) and is_list(a) -> n; _ -> nil end) end) ++ r, MapSet.put(seen, f))
  end
  defp name({:when, _, [h | _]}), do: name(h)
  defp name({n, _, _}), do: n
  defp keys(ast) do
    Inv.collect(ast, fn
      {{:., _, [Access, :get]}, _, [_, k]} when is_binary(k) -> k
      {k, _} when is_binary(k) -> k
      {{:., _, [{:__aliases__, _, [:Map]}, f]}, _, [_, k | _]} when f in [:get, :fetch, :has_key?] and is_binary(k) -> k
      _ -> nil
    end)
  end
end

pairs = [
  {"move_card", "card_controller", :move}, {"archive_card", "card_controller", :archive},
  {"delete_card", "card_controller", :delete}, {"update_card", "card_controller", :update},
  {"create_card", "card_controller", :create}, {"comment", "card_controller", :add_comment},
  {"create_tag", "board_controller", :create_tag}, {"delete_board", "board_controller", :delete},
  {"list_cards", "card_controller", :index}, {"search", "search_controller", :search},
  {"quick_note", "note_controller", :create}, {"keep_job_log", "job_controller", :keep},
  {"revert_page", "page_controller", :revert}, {"update_board", "board_controller", :update},
  {"create_board", "board_controller", :create}, {"create_list", "board_controller", :create_column},
  {"leave_handoff", "card_controller", :leave_handoff}, {"status_update", "card_controller", :add_status_update},
  {"verify_card", "card_controller", :verify}, {"claim_job", "job_controller", :claim}
]
IO.puts("| MCP tool | REST action | same | MCP only | REST only |\n|---|---|---|---|---|")
tot = for {tool, ctrl, action} <- pairs do
  mod = Module.concat(SlipdockWeb.MCP.Tools, Macro.camelize(tool))
  mcp = mod.input_schema()[:properties] |> Map.keys() |> Enum.map(&to_string/1) |> MapSet.new()
        |> MapSet.difference(MapSet.new(~w(card board_id)))
  file = Path.wildcard("lib/slipdock_web/controllers/api/#{ctrl}.ex") |> hd()
  rest = Inv.Params.of(file, action)
  if MapSet.size(rest) == 0, do: IO.puts(:stderr, "no params found for #{ctrl}.#{action}")
  same = MapSet.intersection(mcp, rest); mo = MapSet.difference(mcp, rest); ro = MapSet.difference(rest, mcp)
  f = fn s -> s |> Enum.sort() |> Enum.map_join(", ", &"`#{&1}`") end
  IO.puts("| `#{tool}` | `#{ctrl}.#{action}` | #{MapSet.size(same)} | #{f.(mo)} | #{f.(ro)} |")
  {MapSet.size(same), MapSet.size(mo), MapSet.size(ro), MapSet.size(mo) > 0}
end
{s, m, r, d} = Enum.reduce(tot, {0, 0, 0, 0}, fn {a, b, c, x}, {p, q, w, z} -> {p + a, q + b, w + c, z + if(x, do: 1, else: 0)} end)
IO.puts("\nTotals over #{length(pairs)} pairs: #{s} params named the same, #{m} only in MCP, #{r} only read by REST; #{d} tools have an MCP-only name")
