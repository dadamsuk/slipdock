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
        "from_reason" => true,  # read from a rejection's reason, given no parts
        "judged_at" => "abc1234", # the commit the verdict judged (#1944)
        "decision" => "reject" | "accept",
        "carried" => %{"ask" => "abc1234", "handbook_line" => …}
      }

  A part carried from an earlier verdict (#1944) passed at that verdict's
  commit and wasn't judged again: a bar item or rule has `"carried_from" =>
  sha`, the ask and the Handbook line are named in `"carried"`. A verifier
  gives one as `bar:1=carried`, or leaves it out (see `carry/3`).

  Every part is optional. A verifier gives them as a map in that shape, or
  as a list of lines, one part each (`slipdock verify --check`):

      ask=ok                 ask=misses:the footer
      bar:1=ok               bar:2=fail:no header row
      suite=412:0            (passed:failed)
      rule:UX-4=broken:hex colour in card.ex
      handbook_line=disputed:W-3 wasn't edited
      bar:1=carried          (passed at the last verdict's commit; #1944)
      rule:UX-4=pre-existing:lib/card.ex:42:hex colour
                             (broken only in lines the diff didn't change; #1945)

  A `pre-existing` rule part (#1945) carries the `file` and `line` where
  the rule is broken in code the change didn't touch. It isn't a failing
  part: it never makes a rejection, an acceptance may carry it, and the
  server records it as a `rule` finding on the card instead.
  """

  @results %{
    "ask" => ~w(ok misses carried),
    "bar" => ~w(ok fail carried),
    "rule" => ~w(ok broken n/a carried pre-existing),
    "handbook_line" => ~w(ok disputed carried)
  }

  @carried "carried"

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

  defp build("rule", key, "pre-existing", note) when is_binary(key) and key != "" do
    case Regex.run(~r/^\s*([^\s:]+):(\d+)(?:\s*[:;,]?\s*(.*))?$/s, note || "") do
      [_, file, line | rest] ->
        {:ok,
         {:rule,
          %{
            "id" => String.upcase(key),
            "result" => "pre-existing",
            "file" => file,
            "line" => String.to_integer(line),
            "note" => rest |> List.first() |> to_string() |> String.trim() |> blank_nil()
          }}}

      nil ->
        {:error,
         "check `rule:#{key}=pre-existing` needs the file and line where it is broken: " <>
           "`rule:#{key}=pre-existing:lib/foo.ex:42[:why]`"}
    end
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
  # Set by the server, never by the verifier: given back, they are ignored.
  defp from_map(key, _) when key in ~w(judged_at decision carried), do: {:ok, []}

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
    note = with_place(item, note)
    build(part, to_string(item[key_field] || ""), to_string(item["result"] || ""), note)
  end

  # A pre-existing rule given as a map has its place as fields (#1945).
  defp with_place(%{"result" => "pre-existing", "file" => file} = item, note)
       when is_binary(file) and file != "" do
    "#{file}:#{item["line"]}" <> if(note, do: ":" <> note, else: "")
  end

  defp with_place(_item, note), do: note

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
    carried = checks["carried"] || %{}

    one_line("the ask", checks["ask"], carried_note(notes["ask"], carried["ask"])) ++
      for(
        b <- checks["bar"] || [],
        do: {"bar #{b["item"]}", b["result"], carried_note(b["note"], b["carried_from"])}
      ) ++
      suite_line(checks["suite"]) ++
      for(
        r <- checks["rules"] || [],
        do: {rule_label(r), r["result"], r |> rule_note() |> carried_note(r["carried_from"])}
      ) ++
      one_line(
        "Handbook line",
        checks["handbook_line"],
        carried_note(notes["handbook_line"], carried["handbook_line"])
      )
  end

  def lines(_), do: []

  defp carried_note(note, nil), do: note
  defp carried_note(nil, sha), do: "carried from #{short(sha)}"
  defp carried_note(note, sha), do: "carried from #{short(sha)}; #{note}"

  @doc "A commit as the card shows it: its first seven characters."
  def short(sha) when is_binary(sha), do: String.slice(sha, 0, 7)
  def short(_), do: nil

  defp one_line(_label, nil, _note), do: []
  defp one_line(label, result, note), do: [{label, result, note}]

  defp suite_line(%{"passed" => p, "failed" => f}),
    do: [{"suite", "#{p} passed, #{f} failed", nil}]

  defp suite_line(_), do: []

  # A pre-existing rule's note leads with where it is broken (#1945).
  defp rule_note(%{"result" => "pre-existing", "file" => file} = r) do
    place = "#{file}:#{r["line"]}"
    if r["note"], do: "#{place}; #{r["note"]}", else: place
  end

  defp rule_note(r), do: r["note"]

  @doc "The pre-existing rule parts of `checks` (#1945): broken only in code the change didn't touch."
  def pre_existing(%{} = checks),
    do: for(%{"result" => "pre-existing"} = r <- checks["rules"] || [], do: r)

  def pre_existing(_), do: []

  defp rule_label(r), do: [r["id"], r["severity"]] |> Enum.reject(&is_nil/1) |> Enum.join(" ")

  @doc "Whether `result` (as `lines/1` gives it) is a failing one."
  def failing_result?(result),
    do: Enum.member?(~w(misses fail broken disputed), result) or result =~ ~r/[1-9]\d* failed$/

  ## Carried parts (#1944) ------------------------------------------------------

  @doc """
  The parts of `prior` (an earlier verdict, in the stored shape) that
  passed: `[{"ask", nil}, {"bar", "1"}, {"rules", "UX-4"}, {"handbook_line",
  nil}]`. A rule passed when it was `ok` or `n/a`. The suite is never among
  them: CI, or the verifier, runs it at every commit.
  """
  def passed_parts(%{} = prior) do
    if(prior["ask"] == "ok", do: [{"ask", nil}], else: []) ++
      for(%{"result" => "ok", "item" => i} <- prior["bar"] || [], do: {"bar", i}) ++
      for(
        %{"result" => r, "id" => id} <- prior["rules"] || [],
        Enum.member?(["ok", "n/a"], r),
        do: {"rules", id}
      ) ++
      if prior["handbook_line"] == "ok", do: [{"handbook_line", nil}], else: []
  end

  def passed_parts(_), do: []

  @doc """
  `checks` (this decision's parts) with what `prior`, the verdict before it
  at commit `sha`, passed and this one didn't judge carried over (#1944).

  A part given as `carried` takes the earlier result, marked as carried
  from `sha`; one this verdict leaves out is carried the same way. A part
  given a result of its own is judged, and stands as given. `carried` on a
  part that didn't pass earlier (or with no earlier verdict to carry from)
  is `{:error, message}`: a failed part is judged again, never carried.
  """
  def carry(%{} = checks, prior, sha) do
    asked = carried_asks(checks)
    passed = if is_binary(sha) and sha != "", do: passed_parts(prior), else: []

    case asked -- passed do
      [] ->
        {:ok, Enum.reduce(passed, checks, &carry_part(&2, &1, prior, sha))}

      [_ | _] = bad ->
        {:error, not_carried_message(bad, sha, prior)}
    end
  end

  defp not_carried_message(bad, sha, prior) do
    labels = Enum.map_join(bad, ", ", &part_label/1)

    if passed_parts(prior) == [] or not is_binary(sha),
      do:
        "nothing to carry #{labels} from: there is no earlier verdict with a commit, so judge it",
      else: "#{labels} didn't pass at #{short(sha)}, so it can't be carried: judge it"
  end

  defp part_label({"ask", _}), do: "the ask"
  defp part_label({"handbook_line", _}), do: "the Handbook line"
  defp part_label({"bar", i}), do: "bar #{i}"
  defp part_label({"rules", id}), do: id

  @doc "The parts `checks` gives as `carried`, as `passed_parts/1` names them."
  def carried_asks(checks) do
    if(checks["ask"] == @carried, do: [{"ask", nil}], else: []) ++
      for(%{"result" => @carried, "item" => i} <- checks["bar"] || [], do: {"bar", i}) ++
      for(%{"result" => @carried, "id" => id} <- checks["rules"] || [], do: {"rules", id}) ++
      if checks["handbook_line"] == @carried, do: [{"handbook_line", nil}], else: []
  end

  defp carry_part(checks, {part, nil}, prior, sha) when part in ~w(ask handbook_line) do
    if is_nil(checks[part]) or checks[part] == @carried do
      checks
      |> Map.put(part, prior[part])
      |> Map.update("carried", %{part => sha}, &Map.put(&1, part, sha))
    else
      checks
    end
  end

  defp carry_part(checks, {field, key}, prior, sha) do
    key_field = if field == "bar", do: "item", else: "id"
    list = checks[field] || []
    given = Enum.find(list, &(&1[key_field] == key))

    if given == nil or given["result"] == @carried do
      earlier = Enum.find(prior[field], &(&1[key_field] == key))

      item =
        earlier
        |> Map.take([key_field, "result", "severity", "note"])
        |> Map.put("carried_from", sha)

      put_item(checks, field, key_field, item)
    else
      checks
    end
  end
end
