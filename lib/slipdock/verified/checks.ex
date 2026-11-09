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

  A defect review (#1953), asked of the verifier on a `schema` or `security`
  card, is a list of findings, each with its severity and where it is:

      defect:important=lib/foo.ex:42:the lock is never released
      defect:nit=lib/foo.ex:7:a stray debug line
      defect:pre-existing=lib/bar.ex:90:an unchecked cast the diff didn't add

  stored as `"defect_review" => [%{"severity" => "important" | "nit" |
  "pre-existing", "file" => …, "line" => 42, "note" => …}]`. An `important`
  finding is a failing part (a rejection, never an acceptance); a nit or a
  pre-existing one is reported only. A card the server accepted unverified
  (#1953, profile `docs`) carries `"not_verified" => "docs"`.

  A mutation review (#2354), asked of the verifier on a `fix`, `feature`,
  `schema` or `security` card, is a list of mutants: a line the diff added
  or changed, broken on purpose, and whether the card's tests caught it:

      mutant:killed=lib/foo.ex:42:flip > to >=
      mutant:survived=lib/foo.ex:51:drop the nil guard:a test giving nil
      mutant:pre-existing=lib/bar.ex:9:return :ok:in code the diff didn't change
      mutants=n/a:only a docstring changed

  The mutation is the text up to the next colon (the map form has no such
  limit); the note after it is optional. Stored as `"mutants" =>
  [%{"result" => "killed" | "survived" | "pre-existing" | "carried", "file"
  => …, "line" => 42, "mutation" => …, "note" => …}]`, or `"mutants" =>
  %{"n/a" => why}`. A `survived` mutant is a failing part; killed,
  pre-existing and n/a never fail. A pre-existing survivor is kept as a
  finding, as a pre-existing rule is. A killed mutant is carried to a
  resubmission's verdict (#1944) unless the verifier gives its place again.

  A rule broken in several places (#2046) is one part with its instances:
  each `broken` line for the same rule adds one, its note leading with the
  file and line, and they are stored as `"instances" => [%{"file" => …,
  "line" => 12, "note" => …}]` (`"file"` and `"line"` only when the note
  leads with them). A single `broken` line keeps the plain shape above.

      rule:SPEC-10=broken:README.md:40:the page list lacks Playbook
      rule:SPEC-10=broken:priv/skills/slipdock-docs/SKILL.md:12:the same list

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

  @defect_severities ~w(important nit pre-existing)

  @mutant_results ~w(killed survived pre-existing carried)

  @doc "A mutant's results (#2354): only `survived` fails."
  def mutant_results, do: @mutant_results

  @doc "A defect finding's severities (#1953): only `important` fails."
  def defect_severities, do: @defect_severities

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
      with {:ok, part} <- parse_line(line),
           :ok <- mutants_fit(acc, part) do
        {:cont, {:ok, put_part(acc, part)}}
      else
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
      # A defect's or a mutant's right-hand side is a place, kept as
      # written (#1953, #2354).
      {result, note} =
        if Enum.member?(~w(defect mutant), part),
          do: {String.trim(rhs), nil},
          else: split_note(String.trim(rhs))

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
      "mutation" -> "mutant"
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

  defp build("defect", key, result, note) do
    severity = key |> to_string() |> String.trim() |> String.downcase()
    place = result <> if(note, do: ":" <> note, else: "")

    cond do
      not Enum.member?(@defect_severities, severity) ->
        {:error,
         "check `defect` needs its severity: `defect:<#{Enum.join(@defect_severities, "|")}>=<file>:<line>[:why]`"}

      match = Regex.run(~r/^\s*([^\s:]+):(\d+)(?:\s*[:;,]?\s*(.*))?$/s, place) ->
        [_, file, line | rest] = match

        {:ok,
         {:defect,
          %{
            "severity" => severity,
            "file" => file,
            "line" => String.to_integer(line),
            "note" => rest |> List.first() |> to_string() |> String.trim() |> blank_nil()
          }}}

      true ->
        {:error,
         "check `defect:#{severity}` needs the file and line it is at, never a guess from a " <>
           "name: `defect:#{severity}=lib/foo.ex:42[:why]`"}
    end
  end

  defp build("mutant", key, result, nil), do: build_mutant(key, result)

  defp build("mutants", nil, "n/a", why) when is_binary(why), do: {:ok, {:mutants_na, why}}

  defp build("mutants", _key, _result, _note),
    do:
      {:error,
       "check `mutants` is only `mutants=n/a:<why>` (nothing in the diff worth mutating); " <>
         "give each mutant as `mutant:killed|survived|pre-existing=<file>:<line>:<mutation>`"}

  defp build(part, _key, _result, _note) when part in ~w(bar rule),
    do:
      {:error,
       "check `#{part}` needs which one: `#{part}:<#{if part == "bar", do: "n", else: "id"}>=…`"}

  defp build(part, _key, _result, _note),
    do:
      {:error,
       "unknown check `#{part}`: use ask, bar:<n>, suite, rule:<id>, handbook_line, " <>
         "defect:<severity>, mutant:<result> or mutants=n/a"}

  # A mutant (#2354): `<file>:<line>:<mutation>[:note]`, the place kept as
  # written; `carried` needs only the place.
  defp build_mutant(key, place) do
    result = key |> to_string() |> String.trim() |> String.downcase()
    usage = "`mutant:#{result}=lib/foo.ex:42:<the mutation>[:note]`"

    cond do
      not Enum.member?(@mutant_results, result) ->
        {:error,
         "check `mutant` needs its result: `mutant:<#{Enum.join(@mutant_results, "|")}>=<file>:<line>:<mutation>[:note]`"}

      match = Regex.run(~r/^\s*([^\s:]+):(\d+)\s*(?::([^:]*)(?::(.*))?)?$/s, place) ->
        mutant_item(result, match, usage)

      true ->
        {:error,
         "check `mutant:#{result}` needs the file and line it broke, never a guess from a name: " <>
           usage}
    end
  end

  defp mutant_item(result, [_, file, line | rest], usage) do
    mutation = rest |> Enum.at(0) |> to_string() |> String.trim() |> blank_nil()
    note = rest |> Enum.at(1) |> to_string() |> String.trim() |> blank_nil()

    if mutation == nil and result != @carried do
      {:error, "check `mutant:#{result}` needs the mutation it made after the line: " <> usage}
    else
      {:ok,
       {:mutant,
        %{
          "result" => result,
          "file" => file,
          "line" => String.to_integer(line),
          "mutation" => mutation,
          "note" => note
        }}}
    end
  end

  # `mutants=n/a` says nothing could be mutated, so it can't sit beside a
  # mutant in one verdict.
  defp mutants_fit(acc, {:mutant, _}) when is_map_key(acc, "mutants") do
    if is_list(acc["mutants"]), do: :ok, else: mutants_clash()
  end

  defp mutants_fit(acc, {:mutants_na, _}) when is_map_key(acc, "mutants"), do: mutants_clash()
  defp mutants_fit(_acc, _part), do: :ok

  defp mutants_clash,
    do:
      {:error,
       "check `mutants=n/a` says nothing could be mutated: give it or the mutants, not both"}

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

  defp from_map("rules", items) when is_list(items),
    do: list_items("rule", "id", Enum.flat_map(items, &rule_instances/1))

  defp from_map("defect_review", items) when is_list(items) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case defect_item(item) do
        {:ok, built} -> {:cont, {:ok, acc ++ [built]}}
        error -> {:halt, error}
      end
    end)
  end

  defp from_map("mutants", %{} = na) do
    case Map.new(na, fn {k, v} -> {to_string(k), v} end) do
      %{"n/a" => why} when is_binary(why) and why != "" -> {:ok, [{:mutants_na, why}]}
      _ -> {:error, "check `mutants` is a list of mutants, or `{\"n/a\": why}`"}
    end
  end

  defp from_map("mutants", items) when is_list(items) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case mutant_map(item) do
        {:ok, built} -> {:cont, {:ok, acc ++ [built]}}
        error -> {:halt, error}
      end
    end)
  end

  # Set by the server on a card it accepted unverified (#1953).
  defp from_map("not_verified", _), do: {:ok, []}

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

  # A defect finding given in the stored shape (#1953).
  defp defect_item(item) do
    item = if is_map(item), do: Map.new(item, fn {k, v} -> {to_string(k), v} end), else: %{}
    note = if is_binary(item["note"]), do: ":" <> item["note"], else: ""

    build(
      "defect",
      to_string(item["severity"] || ""),
      "#{item["file"]}:#{item["line"]}#{note}",
      nil
    )
  end

  # A mutant given in the stored shape (#2354): its fields kept apart, so a
  # mutation may hold a colon.
  defp mutant_map(item) do
    item = if is_map(item), do: Map.new(item, fn {k, v} -> {to_string(k), v} end), else: %{}
    result = item["result"] |> to_string() |> String.trim() |> String.downcase()
    file = text_or_nil(item["file"])
    line = whole_number(item["line"])
    mutation = text_or_nil(item["mutation"])

    cond do
      not Enum.member?(@mutant_results, result) or file == nil or line == nil ->
        build_mutant(result, "")

      result != @carried and mutation == nil ->
        {:error, "check `mutant:#{result}` needs its `mutation`: what was broken, and how"}

      true ->
        {:ok,
         {:mutant,
          %{
            "result" => result,
            "file" => file,
            "line" => line,
            "mutation" => mutation,
            "note" => text_or_nil(item["note"])
          }}}
    end
  end

  defp whole_number(n) when is_integer(n), do: n

  defp whole_number(s) when is_binary(s) do
    case Integer.parse(String.trim(s)) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp whole_number(_), do: nil

  defp text_or_nil(s) when is_binary(s), do: s |> String.trim() |> blank_nil()
  defp text_or_nil(_), do: nil

  # A broken rule given as a map with its instances (#2046): one item per
  # instance, which `put_part/2` adds up again.
  defp rule_instances(%{} = item) do
    item = Map.new(item, fn {k, v} -> {to_string(k), v} end)

    case item["instances"] do
      [_ | _] = instances ->
        Enum.map(instances, &instance_item(item, &1))

      _ ->
        [item]
    end
  end

  defp rule_instances(item), do: [item]

  defp instance_item(item, instance) do
    instance =
      if is_map(instance), do: Map.new(instance, fn {k, v} -> {to_string(k), v} end), else: %{}

    %{"id" => item["id"], "result" => item["result"], "note" => place_note(instance)}
  end

  defp place_note(%{"file" => file} = instance) when is_binary(file) and file != "" do
    "#{file}:#{instance["line"]}" <>
      if(is_binary(instance["note"]), do: ":" <> instance["note"], else: "")
  end

  defp place_note(instance), do: instance["note"]

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

  defp put_part(acc, {:rule, %{"result" => "broken"} = item}) do
    list = Map.get(acc, "rules", [])

    case Enum.find(list, &(&1["id"] == item["id"] and &1["result"] == "broken")) do
      nil -> put_item(acc, "rules", "id", item)
      earlier -> put_item(acc, "rules", "id", add_instance(earlier, item))
    end
  end

  defp put_part(acc, {:rule, item}), do: put_item(acc, "rules", "id", item)

  # Findings add up: two at one place are both kept.
  defp put_part(acc, {:defect, item}) do
    item = item |> Enum.reject(fn {_, v} -> is_nil(v) end) |> Map.new()
    Map.update(acc, "defect_review", [item], &(&1 ++ [item]))
  end

  # Mutants add up; a second at the same place and mutation replaces the
  # first.
  defp put_part(acc, {:mutant, item}) do
    item = item |> Enum.reject(fn {_, v} -> is_nil(v) end) |> Map.new()
    list = if is_list(acc["mutants"]), do: acc["mutants"], else: []

    list =
      if Enum.any?(list, &same_mutant?(&1, item)),
        do: Enum.map(list, &if(same_mutant?(&1, item), do: item, else: &1)),
        else: list ++ [item]

    Map.put(acc, "mutants", list)
  end

  defp put_part(acc, {:mutants_na, why}), do: Map.put(acc, "mutants", %{"n/a" => why})

  # A second `broken` line for a rule (#2046): the rule keeps every place
  # it was found broken, the first one's included.
  defp add_instance(earlier, item) do
    instances = Map.get_lazy(earlier, "instances", fn -> [instance(earlier["note"])] end)

    earlier
    |> Map.delete("note")
    |> Map.put("instances", instances ++ [instance(item["note"])])
  end

  defp instance(note) do
    case Regex.run(~r/^\s*([^\s:]+):(\d+)(?:\s*[:;,]?\s*(.*))?$/s, note || "") do
      [_, file, line | rest] ->
        %{"file" => file, "line" => String.to_integer(line)}
        |> put_present(
          "note",
          rest |> List.first() |> to_string() |> String.trim() |> blank_nil()
        )

      nil ->
        put_present(%{}, "note", note)
    end
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  @doc """
  A broken rule's instances (#2046), as `{place, note}` with `place` the
  `file:line` (nil when not given): one for a rule found broken once.
  """
  def instances(%{"instances" => [_ | _] = instances}),
    do: Enum.map(instances, &{instance_place(&1), &1["note"]})

  def instances(%{"result" => "broken"} = rule), do: [{nil, rule["note"]}]
  def instances(_rule), do: []

  defp instance_place(%{"file" => file, "line" => line}), do: "#{file}:#{line}"
  defp instance_place(_), do: nil

  @doc """
  The parts as Markdown for a decision's comment (#2046): one bullet each,
  as `lines/1` gives them, with a rule broken in several places followed by
  a sub-list of every instance.
  """
  def markdown(%{} = checks) do
    rules = for r <- checks["rules"] || [], into: %{}, do: {rule_label(r), r}

    checks
    |> lines()
    |> Enum.map_join("\n", fn {label, result, why} ->
      case rules[label] do
        %{"instances" => [_ | _] = instances} = r ->
          head = "- #{label}: #{result} — #{length(instances)} instances"
          Enum.join([head | Enum.map(instances(r), &instance_bullet/1)], "\n")

        _ ->
          bullet(label, result, why)
      end
    end)
  end

  def markdown(_), do: ""

  defp bullet(label, result, nil), do: "- #{label}: #{result}"
  defp bullet(label, result, why), do: "- #{label}: #{result} — #{why}"

  defp instance_bullet({nil, nil}), do: "  - (no place given)"
  defp instance_bullet({nil, note}), do: "  - #{note}"
  defp instance_bullet({place, nil}), do: "  - `#{place}`"
  defp instance_bullet({place, note}), do: "  - `#{place}` — #{note}"

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
      failing_line(checks) ++
      for(
        %{"severity" => "important"} = d <- checks["defect_review"] || [],
        do: "the defect at #{d["file"]}:#{d["line"]}"
      ) ++
      for(
        %{"result" => "survived"} = m <- mutants(checks),
        do: "the surviving mutant at #{m["file"]}:#{m["line"]}"
      )
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
      ) ++
      for(
        d <- checks["defect_review"] || [],
        do: {"defect", d["severity"], defect_note(d)}
      ) ++
      mutant_lines(checks["mutants"]) ++
      not_verified_line(checks["not_verified"])
  end

  def lines(_), do: []

  defp defect_note(d) do
    place = "#{d["file"]}:#{d["line"]}"
    if d["note"], do: "#{place}; #{d["note"]}", else: place
  end

  defp mutant_lines(%{"n/a" => why}), do: [{"mutants", "n/a", why}]

  defp mutant_lines(list) when is_list(list) do
    for m <- list do
      note =
        ["#{m["file"]}:#{m["line"]}", m["mutation"], m["note"]]
        |> Enum.reject(&is_nil/1)
        |> Enum.join("; ")

      {"mutant", m["result"], carried_note(note, m["carried_from"])}
    end
  end

  defp mutant_lines(_), do: []

  defp not_verified_line(profile) when is_binary(profile),
    do: [{"verification", "not verified", "profile #{profile}: no verify job runs for it"}]

  defp not_verified_line(_), do: []

  @doc "The defect findings of `checks` (#1953), in the order given."
  def defects(%{} = checks), do: checks["defect_review"] || []
  def defects(_), do: []

  @doc "The mutants of `checks` (#2354), in the order given: `[]` for none or `n/a`."
  def mutants(%{"mutants" => list}) when is_list(list), do: list
  def mutants(_), do: []

  @doc "The pre-existing survivors of `checks` (#2354): weak tests in code the change didn't touch."
  def pre_existing_mutants(checks),
    do: for(%{"result" => "pre-existing"} = m <- mutants(checks), do: m)

  defp same_mutant?(a, b),
    do: a["file"] == b["file"] and a["line"] == b["line"] and a["mutation"] == b["mutation"]

  defp same_place?(a, b), do: a["file"] == b["file"] and a["line"] == b["line"]

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

  defp rule_note(%{"instances" => [_ | _]} = r) do
    r
    |> instances()
    |> Enum.map_join("; ", fn
      {nil, note} -> note
      {place, nil} -> place
      {place, note} -> "#{place} #{note}"
    end)
  end

  defp rule_note(r), do: r["note"]

  @doc "The pre-existing rule parts of `checks` (#1945): broken only in code the change didn't touch."
  def pre_existing(%{} = checks),
    do: for(%{"result" => "pre-existing"} = r <- checks["rules"] || [], do: r)

  def pre_existing(_), do: []

  defp rule_label(r), do: [r["id"], r["severity"]] |> Enum.reject(&is_nil/1) |> Enum.join(" ")

  @doc "Whether `result` (as `lines/1` gives it) is a failing one."
  def failing_result?(result),
    do:
      Enum.member?(~w(misses fail broken disputed important survived), result) or
        result =~ ~r/[1-9]\d* failed$/

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
      if(prior["handbook_line"] == "ok", do: [{"handbook_line", nil}], else: []) ++
      for(%{"result" => "killed"} = m <- mutants(prior), do: {"mutant", mutant_place(m)})
  end

  def passed_parts(_), do: []

  @doc "A mutant's place as parts name it: `lib/foo.ex:42`."
  def mutant_place(m), do: "#{m["file"]}:#{m["line"]}"

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
  defp part_label({"mutant", place}), do: "the mutant at #{place}"

  @doc "A carried part's name, as the card and the prompt say it."
  def carried_label(part), do: part_label(part)

  @doc "The parts `checks` gives as `carried`, as `passed_parts/1` names them."
  def carried_asks(checks) do
    if(checks["ask"] == @carried, do: [{"ask", nil}], else: []) ++
      for(%{"result" => @carried, "item" => i} <- checks["bar"] || [], do: {"bar", i}) ++
      for(%{"result" => @carried, "id" => id} <- checks["rules"] || [], do: {"rules", id}) ++
      if(checks["handbook_line"] == @carried, do: [{"handbook_line", nil}], else: []) ++
      for(%{"result" => @carried} = m <- mutants(checks), do: {"mutant", mutant_place(m)})
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

  # A killed mutant (#2354) is carried unless this verdict judged a mutant
  # at its place again: the verifier gives it again when the commits since
  # touched its line. A verdict that found nothing to mutate (`n/a`) this
  # time carries nothing.
  defp carry_part(checks, {"mutant", place}, prior, sha) do
    earlier = Enum.find(mutants(prior), &(&1["result"] == "killed" and mutant_place(&1) == place))
    given = mutants(checks)
    judged = Enum.filter(given, &(same_place?(&1, earlier) and &1["result"] != @carried))

    cond do
      is_map(checks["mutants"]) ->
        checks

      judged != [] ->
        checks

      true ->
        item =
          earlier |> Map.take(~w(result file line mutation note)) |> Map.put("carried_from", sha)

        rest = Enum.reject(given, &same_place?(&1, earlier))
        Map.put(checks, "mutants", rest ++ [item])
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
