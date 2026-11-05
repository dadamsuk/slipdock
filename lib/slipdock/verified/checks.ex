defmodule Slipdock.Verified.Checks do
  @moduledoc """
  A verdict in parts (#1778): what a verifier found for each check, stored
  on the card as `verify_checks` by `Slipdock.Verified.decide/5` and never
  cast from a card update.

      %{
        "ask" => "ok" | "misses",
        "bar" => [%{"item" => "1", "result" => "ok" | "fail", "note" => …}],
        "suite" => %{"passed" => 412, "failed" => 0},
        "rules" => [%{"id" => "UX-4", "result" => "ok" | "broken" | "n/a",
                      "severity" => "must" | "should" | nil, "note" => …}],
        "handbook_line" => "ok" | "disputed",
        "notes" => %{"ask" => …, "handbook_line" => …},
        "from_reason" => true   # read from a rejection's reason, given no parts
      }

  Every part is optional. A verifier gives them as a map in that shape, or
  as a list of lines, one part each (`slipdock verify --check`):

      ask=ok                 ask=misses:the footer
      bar:1=ok               bar:2=fail:no header row
      suite=412:0            (passed:failed)
      rule:UX-4=broken:hex colour in card.ex
      handbook_line=disputed:W-3 wasn't edited
  """

  @results %{
    "ask" => ~w(ok misses),
    "bar" => ~w(ok fail),
    "rule" => ~w(ok broken n/a),
    "handbook_line" => ~w(ok disputed)
  }

  @doc """
  The parts in `given` (nil, a list of lines or a map in the stored shape),
  checked and in the stored shape: `{:ok, map}` (`%{}` when none were
  given), or `{:error, message}` naming the part that doesn't parse.
  """
  def parse(nil), do: {:ok, %{}}
  def parse(""), do: {:ok, %{}}
  def parse([]), do: {:ok, %{}}
  def parse(line) when is_binary(line), do: parse(String.split(line, "\n"))

  def parse(lines) when is_list(lines) do
    lines
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.reduce_while({:ok, %{}}, fn line, {:ok, acc} ->
      case parse_line(line) do
        {:ok, part} -> {:cont, {:ok, put_part(acc, part)}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  def parse(%{} = map) do
    map
    |> Map.new(fn {k, v} -> {to_string(k), v} end)
    |> Enum.reduce_while({:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case from_map(key, value) do
        {:ok, parts} -> {:cont, {:ok, Enum.reduce(parts, acc, &put_part(&2, &1))}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  def parse(_), do: {:error, "checks must be a list of `part=result` lines or a map of parts"}

  # One line: `part[:key]=result[:note]`.
  defp parse_line(line) do
    with [lhs, rhs] <- String.split(line, "=", parts: 2),
         {part, key} <- split_key(String.trim(lhs)) do
      {result, note} = split_note(String.trim(rhs))
      build(part, key, result, note)
    else
      _ -> {:error, "check `#{line}` should read `part=result`, e.g. `bar:2=fail:why`"}
    end
  end

  defp split_key(lhs) do
    case String.split(lhs, ":", parts: 2) do
      [part] -> {normal_part(part), nil}
      [part, key] -> {normal_part(part), String.trim(key)}
    end
  end

  defp normal_part(part) do
    case part |> String.trim() |> String.downcase() do
      "handbook" -> "handbook_line"
      "rules" -> "rule"
      p -> p
    end
  end

  defp split_note(rhs) do
    case String.split(rhs, ":", parts: 2) do
      [result] ->
        {String.downcase(result), nil}

      [result, note] ->
        {String.downcase(String.trim(result)), note |> String.trim() |> unquote_note()}
    end
  end

  defp unquote_note(note), do: note |> String.trim("\"") |> blank_nil()

  defp blank_nil(""), do: nil
  defp blank_nil(s), do: s

  defp build("suite", nil, result, note) do
    with [p, f] <- String.split(result <> if(note, do: ":" <> note, else: ""), ":", parts: 2),
         {passed, ""} <- Integer.parse(String.trim(p)),
         {failed, ""} <- Integer.parse(String.trim(f)) do
      {:ok, {:suite, %{"passed" => passed, "failed" => failed}}}
    else
      _ -> {:error, "check `suite` should read `suite=<passed>:<failed>`, e.g. `suite=412:0`"}
    end
  end

  defp build("ask", nil, result, note) do
    with :ok <- result_ok("ask", result), do: {:ok, {:ask, result, note}}
  end

  defp build("handbook_line", nil, result, note) do
    with :ok <- result_ok("handbook_line", result), do: {:ok, {:handbook_line, result, note}}
  end

  defp build("bar", key, result, note) when is_binary(key) and key != "" do
    with :ok <- result_ok("bar", result),
         do: {:ok, {:bar, %{"item" => key, "result" => result, "note" => note}}}
  end

  defp build("rule", key, result, note) when is_binary(key) and key != "" do
    with :ok <- result_ok("rule", result),
         do: {:ok, {:rule, %{"id" => String.upcase(key), "result" => result, "note" => note}}}
  end

  defp build(part, _key, _result, _note) when part in ~w(bar rule),
    do:
      {:error,
       "check `#{part}` needs which one: `#{part}:<#{if part == "bar", do: "n", else: "id"}>=…`"}

  defp build(part, _key, _result, _note),
    do: {:error, "unknown check `#{part}`: use ask, bar:<n>, suite, rule:<id> or handbook_line"}

  defp result_ok(part, result) do
    allowed = Map.fetch!(@results, part)

    if Enum.member?(allowed, result),
      do: :ok,
      else: {:error, "check `#{part}` is #{Enum.join(allowed, ", ")}, not `#{result}`"}
  end

  # The stored shape, given back (MCP and REST may send the map).
  defp from_map("ask", v) when is_binary(v), do: one(build("ask", nil, v, nil))

  defp from_map("handbook_line", v) when is_binary(v),
    do: one(build("handbook_line", nil, v, nil))

  defp from_map("suite", %{} = v) do
    v = Map.new(v, fn {k, x} -> {to_string(k), x} end)

    case {v["passed"], v["failed"]} do
      {p, f} when is_integer(p) and is_integer(f) and p >= 0 and f >= 0 ->
        {:ok, [{:suite, %{"passed" => p, "failed" => f}}]}

      _ ->
        {:error, "check `suite` needs whole numbers `passed` and `failed`"}
    end
  end

  defp from_map("bar", items) when is_list(items), do: list_items("bar", "item", items)
  defp from_map("rules", items) when is_list(items), do: list_items("rule", "id", items)

  defp from_map("from_reason", _), do: {:ok, []}

  defp from_map("notes", %{} = notes) do
    {:ok,
     for {k, v} <- notes, Enum.member?(~w(ask handbook_line), to_string(k)), is_binary(v) do
       {:note, to_string(k), v}
     end}
  end

  defp from_map(key, _), do: {:error, "unknown check `#{key}`, or not in its shape"}

  defp list_items(part, key_field, items) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case list_item(part, key_field, item) do
        {:ok, built} -> {:cont, {:ok, acc ++ [built]}}
        error -> {:halt, error}
      end
    end)
  end

  defp list_item(part, key_field, item) do
    item = if is_map(item), do: Map.new(item, fn {k, v} -> {to_string(k), v} end), else: %{}
    note = if is_binary(item["note"]), do: blank_nil(String.trim(item["note"]))
    build(part, to_string(item[key_field] || ""), to_string(item["result"] || ""), note)
  end

  defp one({:ok, part}), do: {:ok, [part]}
  defp one(error), do: error

  defp put_part(acc, {:suite, suite}), do: Map.put(acc, "suite", suite)

  defp put_part(acc, {part, result, note}) when part in [:ask, :handbook_line] do
    acc = Map.put(acc, to_string(part), result)
    if note, do: put_note(acc, to_string(part), note), else: acc
  end

  defp put_part(acc, {:note, part, note}), do: put_note(acc, part, note)

  defp put_part(acc, {:bar, item}), do: put_item(acc, "bar", "item", item)
  defp put_part(acc, {:rule, item}), do: put_item(acc, "rules", "id", item)

  defp put_note(acc, part, note),
    do: Map.update(acc, "notes", %{part => note}, &Map.put(&1, part, note))

  # A later line for the same item replaces the earlier one, in place.
  defp put_item(acc, field, key, item) do
    item = item |> Enum.reject(fn {_, v} -> is_nil(v) end) |> Map.new()
    list = Map.get(acc, field, [])

    list =
      if Enum.any?(list, &(&1[key] == item[key])),
        do: Enum.map(list, &if(&1[key] == item[key], do: item, else: &1)),
        else: list ++ [item]

    Map.put(acc, field, list)
  end

  @doc """
  The parts a rejection's reason cites when no checks were given (#1777's
  citations): `bar 2:`, `the ask:`, `Handbook line:` or a rule id such as
  `UX-4:`, at the start of a line. `%{}` when it cites none.
  """
  def from_reason(reason) when is_binary(reason) do
    lines =
      Regex.scan(
        ~r/^[ \t>*_-]*(bar\s+(\d+)|the ask|handbook line|([A-Z][A-Z0-9]*-\d+))\s*:/im,
        reason
      )

    Enum.reduce(lines, %{}, fn
      [_, _, item | _], acc when item != "" ->
        put_item(acc, "bar", "item", %{"item" => item, "result" => "fail"})

      [_, _, _, id], acc when id != "" ->
        put_item(acc, "rules", "id", %{"id" => String.upcase(id), "result" => "broken"})

      [_, cited | _], acc ->
        case String.downcase(cited) do
          "the ask" -> Map.put(acc, "ask", "misses")
          _ -> Map.put(acc, "handbook_line", "disputed")
        end
    end)
  end

  def from_reason(_), do: %{}

  @doc """
  `checks` with each rule's severity filled in from `rules` (the handbook's,
  as `Slipdock.Handbook.Rules.rules/1` gives them): a rule the handbook
  doesn't have keeps none.
  """
  def with_severity(%{"rules" => list} = checks, rules) when is_list(list) do
    by_id = Map.new(rules, &{String.upcase(&1.id), &1.severity})

    Map.put(
      checks,
      "rules",
      Enum.map(list, fn r ->
        case by_id[r["id"]] do
          nil -> r
          sev -> Map.put(r, "severity", sev)
        end
      end)
    )
  end

  def with_severity(checks, _rules), do: checks

  @doc "The failing parts of `checks`, as short labels (`bar 2`, `UX-4`, `the ask`)."
  def failing(%{} = checks) do
    failing_ask(checks) ++
      for(%{"result" => "fail", "item" => i} <- checks["bar"] || [], do: "bar #{i}") ++
      failing_suite(checks["suite"]) ++
      for(%{"result" => "broken", "id" => id} <- checks["rules"] || [], do: id) ++
      failing_line(checks)
  end

  def failing(_), do: []

  defp failing_ask(%{"ask" => "misses"}), do: ["the ask"]
  defp failing_ask(_), do: []

  defp failing_suite(%{"failed" => f}) when is_integer(f) and f > 0,
    do: ["the suite (#{f} failed)"]

  defp failing_suite(_), do: []

  defp failing_line(%{"handbook_line" => "disputed"}), do: ["the Handbook line"]
  defp failing_line(_), do: []

  @doc """
  The failing parts an acceptance can't carry: every one but a broken
  `should` rule (a rule the handbook doesn't know counts as a `must`).
  """
  def blocking(%{} = checks) do
    should =
      for %{"result" => "broken", "severity" => "should", "id" => id} <- checks["rules"] || [],
          do: id

    failing(checks) -- should
  end

  @doc """
  The parts as lines for the card and the CLI, in check order: `[{label,
  result, note}]`, e.g. `{"bar 2", "fail", "no header row"}`.
  """
  def lines(%{} = checks) when map_size(checks) > 0 do
    notes = checks["notes"] || %{}

    one_line("the ask", checks["ask"], notes["ask"]) ++
      for(b <- checks["bar"] || [], do: {"bar #{b["item"]}", b["result"], b["note"]}) ++
      suite_line(checks["suite"]) ++
      for(r <- checks["rules"] || [], do: {rule_label(r), r["result"], r["note"]}) ++
      one_line("Handbook line", checks["handbook_line"], notes["handbook_line"])
  end

  def lines(_), do: []

  defp one_line(_label, nil, _note), do: []
  defp one_line(label, result, note), do: [{label, result, note}]

  defp suite_line(%{"passed" => p, "failed" => f}),
    do: [{"suite", "#{p} passed, #{f} failed", nil}]

  defp suite_line(_), do: []

  defp rule_label(r), do: [r["id"], r["severity"]] |> Enum.reject(&is_nil/1) |> Enum.join(" ")

  @doc "Whether `result` (as `lines/1` gives it) is a failing one."
  def failing_result?(result),
    do: Enum.member?(~w(misses fail broken disputed), result) or result =~ ~r/[1-9]\d* failed$/
end
